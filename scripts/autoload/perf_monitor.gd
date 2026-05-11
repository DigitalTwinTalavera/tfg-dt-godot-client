## PerfMonitor autoload singleton
## Recolector central de métricas de rendimiento del cliente.
##
## Lee del Performance singleton de Godot lo que viene gratis (FPS,
## _process, _physics_process, draw calls, primitivas, memoria, nodos) y
## acumula timings push-based desde otros sistemas:
##   • SimulationClient → record_ws_packet, record_us(&"parse"),
##                        record_tick_latency
##   • VehicleManager   → record_us(&"tick_apply")
##   • VehicleRenderer  → record_us(&"render_wait"),
##                        record_us(&"gpu_upload"),
##                        record_us(&"worker_wall")
##
## Emite `sample_ready(snapshot: Dictionary)` a OVERLAY_REFRESH_HZ para que
## el overlay y otros consumers se refresquen sin necesidad de su propio
## _process.
##
## Volcados:
##   • print() humano cada STDOUT_INTERVAL_S (si LOG_TO_STDOUT)
##   • fila CSV en user://perf_YYYYMMDD_HHMMSS.csv cada CSV_INTERVAL_S
##     (si LOG_TO_CSV)
##
## Diseño anti-GC: buffers circulares pre-alocados (PackedInt64Array) para
## las ventanas rolling. record_us() es O(1) y no asigna.
extends Node


signal sample_ready(snapshot: Dictionary)


## Canales de timing (StringName para evitar comparaciones de String).
const CHANNEL_TICK_APPLY: StringName = &"tick_apply"
const CHANNEL_PARSE: StringName = &"parse"
const CHANNEL_RENDER_WAIT: StringName = &"render_wait"
const CHANNEL_GPU_UPLOAD: StringName = &"gpu_upload"
## Tiempo de pared end-to-end de la group_task de workers del renderer
## (dispatch → wait_completion). A 4k vehículos típicamente ~10-12 ms.
## Si supera el frame budget (~13.88 ms con N=3 a 144 FPS), el ring buffer se
## desborda y `render_wait` empieza a subir.
const CHANNEL_WORKER_WALL: StringName = &"worker_wall"
const _CHANNELS: Array[StringName] = [
	CHANNEL_TICK_APPLY,
	CHANNEL_PARSE,
	CHANNEL_RENDER_WAIT,
	CHANNEL_GPU_UPLOAD,
	CHANNEL_WORKER_WALL,
]


## Buffer circular por canal: μs de cada sample. Tamaño fijo, sin GC.
var _timing_bufs: Dictionary = {}        # StringName → PackedInt64Array
var _timing_idx: Dictionary = {}         # StringName → int (cursor)
var _timing_filled: Dictionary = {}      # StringName → int (≤ window)

## Mutex que protege los buffers de timing y los contadores WS. Necesario
## porque algunos hooks (e.g. _parse_packet de SimulationClient) corren en un
## worker thread, no en main.
var _mutex: Mutex = Mutex.new()


## Contadores WS (rotan a 1 Hz).
var _ws_msgs_window: int = 0
var _ws_bytes_window: int = 0
var _ws_msgs_per_s: float = 0.0
var _ws_bytes_per_s: float = 0.0
var _ws_window_t0_us: int = 0


## Latencia end-to-end (sim_time del backend → reloj local del cliente).
## Calibramos un offset al primer tick (sim_time₀, wall₀) y a partir de ahí
## latency_ms = (wall_now - wall₀) - (sim_time - sim_time₀) · 1000.
var _latency_calibrated: bool = false
var _latency_sim_t0: float = 0.0
var _latency_wall_t0_ms: int = 0
var _latency_buf: PackedFloat64Array = PackedFloat64Array()
var _latency_idx: int = 0
var _latency_filled: int = 0


## Output sinks
var _csv_file: FileAccess = null
var _csv_path: String = ""
var _last_csv_emit_us: int = 0
var _last_stdout_emit_us: int = 0
var _last_overlay_emit_us: int = 0


func _ready() -> void:
	process_priority = -100  # tick antes que el resto para tener buffers frescos
	_init_buffers()
	_open_csv_if_enabled()
	_log_info(
		"Initialized — overlay@%.1f Hz, csv=%s, stdout=%s" % [
			Config.Perf.OVERLAY_REFRESH_HZ,
			str(Config.Perf.LOG_TO_CSV),
			str(Config.Perf.LOG_TO_STDOUT),
		]
	)


func _exit_tree() -> void:
	if _csv_file != null:
		_csv_file.close()
		_csv_file = null


func _init_buffers() -> void:
	var window: int = Config.Perf.TIMING_WINDOW_SIZE
	for ch in _CHANNELS:
		var buf := PackedInt64Array()
		buf.resize(window)
		_timing_bufs[ch] = buf
		_timing_idx[ch] = 0
		_timing_filled[ch] = 0
	_latency_buf.resize(window)
	_latency_idx = 0
	_latency_filled = 0
	_ws_window_t0_us = Time.get_ticks_usec()


# ── Push API ────────────────────────────────────────────────────────────────

## Registra una duración (μs) en el canal indicado. O(1), no asigna.
## Thread-safe (parser thread de SimulationClient lo llama).
func record_us(channel: StringName, dt_us: int) -> void:
	if not _timing_bufs.has(channel):
		return
	_mutex.lock()
	var buf: PackedInt64Array = _timing_bufs[channel]
	var i: int = _timing_idx[channel]
	buf[i] = dt_us
	_timing_idx[channel] = (i + 1) % buf.size()
	var filled: int = _timing_filled[channel]
	if filled < buf.size():
		_timing_filled[channel] = filled + 1
	_mutex.unlock()


## Registra un paquete WS recibido (incrementa msg count + byte count).
## Thread-safe.
func record_ws_packet(byte_count: int) -> void:
	_mutex.lock()
	_ws_msgs_window += 1
	_ws_bytes_window += byte_count
	_mutex.unlock()


## Registra la diferencia entre sim_time del backend y wall-clock al recibir.
## Calibra un offset en el primer tick para evitar mostrar la diferencia
## absoluta entre el reloj del backend (segundos desde inicio de sim) y el del
## cliente (epoch). Lo que reporta es jitter / acumulación de retraso.
func record_tick_latency(sim_time: float, wall_now_ms: int) -> void:
	if not _latency_calibrated:
		_latency_sim_t0 = sim_time
		_latency_wall_t0_ms = wall_now_ms
		_latency_calibrated = true
		return
	var elapsed_wall_ms: float = float(wall_now_ms - _latency_wall_t0_ms)
	var elapsed_sim_ms: float = (sim_time - _latency_sim_t0) * 1000.0
	var latency_ms: float = elapsed_wall_ms - elapsed_sim_ms
	_latency_buf[_latency_idx] = latency_ms
	_latency_idx = (_latency_idx + 1) % _latency_buf.size()
	if _latency_filled < _latency_buf.size():
		_latency_filled += 1


# ── Snapshot ────────────────────────────────────────────────────────────────

## Devuelve un dict con el estado actual de todas las métricas. Pensado para
## consumo del overlay y del CSV writer.
func snapshot() -> Dictionary:
	var snap: Dictionary = {}
	snap["fps"] = Performance.get_monitor(Performance.TIME_FPS)
	snap["process_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	snap["physics_ms"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	snap["draw_calls"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	snap["primitives"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	snap["objects"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	snap["mem_static_mb"] = Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
	snap["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	snap["orphans"] = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	snap["vehicles"] = VehicleManager.get_vehicle_count()

	snap["ws_msgs_per_s"] = _ws_msgs_per_s
	snap["ws_kb_per_s"] = _ws_bytes_per_s / 1024.0

	for ch in _CHANNELS:
		var stats := _channel_stats(ch)
		snap[String(ch) + "_avg_ms"] = stats.avg_ms
		snap[String(ch) + "_max_ms"] = stats.max_ms

	var lat := _latency_stats()
	snap["latency_avg_ms"] = lat.avg_ms
	snap["latency_max_ms"] = lat.max_ms

	snap["csv_path"] = _csv_path
	return snap


func _channel_stats(channel: StringName) -> Dictionary:
	_mutex.lock()
	var buf_src: PackedInt64Array = _timing_bufs[channel]
	var n: int = _timing_filled[channel]
	if n == 0:
		_mutex.unlock()
		return {"avg_ms": 0.0, "max_ms": 0.0}
	var sum: int = 0
	var maxv: int = 0
	for i in range(n):
		var v: int = buf_src[i]
		sum += v
		if v > maxv:
			maxv = v
	_mutex.unlock()
	return {
		"avg_ms": (float(sum) / float(n)) / 1000.0,
		"max_ms": float(maxv) / 1000.0,
	}


func _latency_stats() -> Dictionary:
	if _latency_filled == 0:
		return {"avg_ms": 0.0, "max_ms": 0.0}
	var sum: float = 0.0
	var maxv: float = -INF
	for i in range(_latency_filled):
		var v: float = _latency_buf[i]
		sum += v
		if v > maxv:
			maxv = v
	return {
		"avg_ms": sum / float(_latency_filled),
		"max_ms": maxv,
	}


# ── Tick interno (rotación + emisión de signals + sinks) ────────────────────

func _process(_delta: float) -> void:
	var now_us: int = Time.get_ticks_usec()

	# 1) Ventana WS de 1 s: rotar y publicar tasas
	var elapsed_ws_s: float = float(now_us - _ws_window_t0_us) / 1_000_000.0
	if elapsed_ws_s >= 1.0:
		_mutex.lock()
		_ws_msgs_per_s = float(_ws_msgs_window) / elapsed_ws_s
		_ws_bytes_per_s = float(_ws_bytes_window) / elapsed_ws_s
		_ws_msgs_window = 0
		_ws_bytes_window = 0
		_ws_window_t0_us = now_us
		_mutex.unlock()

	# 2) Emitir snapshot al overlay a OVERLAY_REFRESH_HZ
	var overlay_period_us: int = int(1_000_000.0 / Config.Perf.OVERLAY_REFRESH_HZ)
	if now_us - _last_overlay_emit_us >= overlay_period_us:
		_last_overlay_emit_us = now_us
		sample_ready.emit(snapshot())

	# 3) CSV cada CSV_INTERVAL_S
	if Config.Perf.LOG_TO_CSV and _csv_file != null:
		var csv_period_us: int = int(Config.Perf.CSV_INTERVAL_S * 1_000_000.0)
		if now_us - _last_csv_emit_us >= csv_period_us:
			_last_csv_emit_us = now_us
			_write_csv_row(snapshot())

	# 4) stdout cada STDOUT_INTERVAL_S
	if Config.Perf.LOG_TO_STDOUT:
		var stdout_period_us: int = int(Config.Perf.STDOUT_INTERVAL_S * 1_000_000.0)
		if now_us - _last_stdout_emit_us >= stdout_period_us:
			_last_stdout_emit_us = now_us
			_print_summary(snapshot())


# ── Sinks ───────────────────────────────────────────────────────────────────

func _open_csv_if_enabled() -> void:
	if not Config.Perf.LOG_TO_CSV:
		return
	var ts := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	_csv_path = "user://perf_%s.csv" % ts
	_csv_file = FileAccess.open(_csv_path, FileAccess.WRITE)
	if _csv_file == null:
		_log_warning("Cannot open CSV at %s (err=%d)" % [_csv_path, FileAccess.get_open_error()])
		_csv_path = ""
		return
	_csv_file.store_line(
		"ts_iso,fps,process_ms,physics_ms,draw_calls,primitives,vehicles," +
		"ws_msgs_s,ws_kb_s,tick_apply_avg_ms,tick_apply_max_ms," +
		"parse_avg_ms,parse_max_ms,latency_avg_ms,latency_max_ms," +
		"mem_static_mb,nodes,orphans,render_wait_avg_ms,gpu_upload_avg_ms," +
		"worker_wall_avg_ms,worker_wall_max_ms"
	)
	_csv_file.flush()
	_log_info("CSV log: %s" % _csv_path)


func _write_csv_row(s: Dictionary) -> void:
	if _csv_file == null:
		return
	var ts := Time.get_datetime_string_from_system()
	var row := "%s,%.1f,%.3f,%.3f,%d,%d,%d,%.1f,%.1f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%.1f,%d,%d,%.3f,%.3f,%.3f,%.3f" % [
		ts,
		s["fps"], s["process_ms"], s["physics_ms"],
		s["draw_calls"], s["primitives"], s["vehicles"],
		s["ws_msgs_per_s"], s["ws_kb_per_s"],
		s["tick_apply_avg_ms"], s["tick_apply_max_ms"],
		s["parse_avg_ms"], s["parse_max_ms"],
		s["latency_avg_ms"], s["latency_max_ms"],
		s["mem_static_mb"], s["nodes"], s["orphans"],
		s["render_wait_avg_ms"], s["gpu_upload_avg_ms"],
		s["worker_wall_avg_ms"], s["worker_wall_max_ms"],
	]
	_csv_file.store_line(row)
	_csv_file.flush()


func _print_summary(s: Dictionary) -> void:
	print(
		"[PerfMonitor] FPS=%.1f proc=%.2fms phys=%.2fms dc=%d prim=%dk veh=%d | WS=%.0f msg/s %.1f KB/s | tick=%.2f/%.2f ms | lat=%.1f ms | mem=%.0f MB nodes=%d (orph=%d) | rwait=%.2f gpu=%.2f wwall=%.2f ms" % [
			s["fps"], s["process_ms"], s["physics_ms"],
			s["draw_calls"], int(s["primitives"] / 1000), s["vehicles"],
			s["ws_msgs_per_s"], s["ws_kb_per_s"],
			s["tick_apply_avg_ms"], s["tick_apply_max_ms"],
			s["latency_avg_ms"],
			s["mem_static_mb"], s["nodes"], s["orphans"],
			s["render_wait_avg_ms"], s["gpu_upload_avg_ms"], s["worker_wall_avg_ms"],
		]
	)


# ── Logging ─────────────────────────────────────────────────────────────────

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[PerfMonitor] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[PerfMonitor] %s" % message)
