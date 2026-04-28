## SimulationClient autoload singleton
## WebSocket client for real-time simulation data from the backend.
##
## Responsibilities:
##   - Connect to ws://localhost:8000/ws/simulation on startup
##   - Auto-reconnect with exponential backoff on disconnect
##   - Buffer incoming messages in a bounded queue
##   - Route each message to the correct signal by "type" field
##   - Track and log connection stats periodically
extends Node


## Emitted when the WebSocket connection is established
signal connected()

## Emitted when the connection is lost or closed
signal disconnected()

## Emitted when a connection attempt fails before ever connecting
signal connection_failed(reason: String)

## Routed message signals -------------------------------------------------

## Fired every simulation tick: tick index, sim_time (s), list of vehicle state dicts
signal tick_received(tick: int, sim_time: float, vehicles: Array)

## Fired when the backend sim changes state ("idle", "running", "paused", "stopped")
signal sim_state_received(state: String)

## Fired when a new vehicle is spawned (vehicle_id + full data dict)
signal vehicle_spawned(vehicle_id: String, data: Dictionary)

## Fired when a vehicle completes its route and is removed
signal vehicle_finished(vehicle_id: String)

## Fired when two vehicles collide. Payload includes both ids and the blocked edge.
## The collision persists until the operator clears it via
## POST /simulation/vehicles/{id}/clear-collision.
signal vehicle_collision(vehicle_id_1: String, vehicle_id_2: String, blocked_edge: Array)

## Fired when a batch of vehicles is spawned at once (vehicles_batch_spawned WS message).
## Contains the raw array of vehicle dicts from the backend.
signal vehicles_batch_spawned(vehicles: Array)

## Fired for traffic light state updates
signal traffic_light_received(data: Dictionary)

## Incidente de tráfico (alta/actualización/baja).
## payload: { action: "created"|"updated"|"cleared", incident: {...} }
signal incident_received(data: Dictionary)

## Zona de control (ZBE/restringida/peatonal) cambiada.
## payload: { action: "created"|"updated"|"cleared", zone: {...} }
signal zone_received(data: Dictionary)


## Connection state machine -----------------------------------------------

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
	RECONNECTING,
}


## Internal state ----------------------------------------------------------

var _ws: WebSocketPeer = WebSocketPeer.new()
var _state: ConnectionState = ConnectionState.DISCONNECTED
var _reconnect_attempts: int = 0
var _reconnect_timer: Timer

## Cola de paquetes raw entrantes (main thread escribe, parser thread lee).
## Se acumula en `_read_available_packets` y se vacía en `_parser_loop`.
var _raw_queue: Array[PackedByteArray] = []
## Cola de mensajes ya parseados (parser thread escribe, main thread lee).
## El main thread la consume en `_drain_queue`.
var _parsed_queue: Array[Dictionary] = []
## Mutex que protege ambas colas. El parse en thread es el cuello que antes
## bloqueaba el main thread con tick messages de cientos de KB; ahora corre
## en paralelo al rendering y el main thread sólo paga el coste de extraer
## los Dictionaries listos.
var _queue_mutex: Mutex = Mutex.new()
## Semaphore para despertar al parser cuando hay paquetes nuevos. El thread
## espera bloqueado y consume CPU sólo cuando hay trabajo.
var _parser_semaphore: Semaphore = Semaphore.new()
## Thread persistente que parsea paquetes en background. Se arranca en
## `_ready` y se finaliza en `_exit_tree` con `_parser_running = false` +
## post() para desbloquear el wait().
var _parser_thread: Thread = Thread.new()
var _parser_running: bool = false

## Re-ensamblaje de ticks multi-chunk.
## Cuando el backend divide un tick en N mensajes (chunk_total > 1), el cliente
## acumula los vehículos de cada fragmento en `_pending_tick_vehicles` y solo
## emite `tick_received` una vez que han llegado todos los chunks del mismo
## tick. Esto evita que el renderer aplique un estado parcial (unos vehículos
## del tick N, otros del N-1), que antes producía jitter visible.
var _pending_tick: int = -1
var _pending_sim_time: float = 0.0
var _pending_tick_vehicles: Array = []
var _pending_chunks_received: int = 0
var _pending_chunks_total: int = 0

## Stats
var _ticks_received: int = 0
var _messages_processed: int = 0
var _last_tick_time: float = 0.0
var _measured_tick_rate: float = 0.0
var _stats_timer: float = 0.0


## Public read-only API ----------------------------------------------------

## Current connection state
var connection_state: ConnectionState:
	get:
		return _state

## True when the WebSocket is fully open
var is_connected_to_backend: bool:
	get:
		return _state == ConnectionState.CONNECTED

## How many ticks have been received since last connect
var ticks_received: int:
	get:
		return _ticks_received

## Measured tick rate in ticks/second (rolling single-frame estimate)
var measured_tick_rate: float:
	get:
		return _measured_tick_rate

## How many messages have been processed total
var messages_processed: int:
	get:
		return _messages_processed


## Lifecycle ---------------------------------------------------------------

func _ready() -> void:
	_setup_reconnect_timer()
	_start_parser_thread()
	_connect_to_backend()
	_log_info("Initialized — connecting to %s" % Config.ws_url)


func _exit_tree() -> void:
	_stop_parser_thread()


func _process(delta: float) -> void:
	_poll_websocket()
	_drain_queue()
	_update_stats_log(delta)


## Public API --------------------------------------------------------------

## Manually close the connection and stop reconnecting
func disconnect_from_backend() -> void:
	_reconnect_timer.stop()
	_ws.close()
	_state = ConnectionState.DISCONNECTED
	_log_info("Disconnected by request")


## Get a snapshot of current stats for the UI / debug panel
func get_stats() -> Dictionary:
	_queue_mutex.lock()
	var raw_size := _raw_queue.size()
	var parsed_size := _parsed_queue.size()
	_queue_mutex.unlock()
	return {
		"state": ConnectionState.keys()[_state],
		"ticks_received": _ticks_received,
		"messages_processed": _messages_processed,
		"measured_tick_rate": snappedf(_measured_tick_rate, 0.1),
		"queue_size": parsed_size,
		"raw_queue_size": raw_size,
		"reconnect_attempts": _reconnect_attempts,
	}


## Internal: setup ---------------------------------------------------------

func _setup_reconnect_timer() -> void:
	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_do_reconnect)
	add_child(_reconnect_timer)


func _connect_to_backend() -> void:
	_state = ConnectionState.CONNECTING
	_ws = WebSocketPeer.new()
	# Aumentar el buffer de recepción para soportar tick messages con miles
	# de vehículos. El límite por defecto de Godot es 64 KB, lo que causa
	# desconexión con código 1009 ("Message too big") cuando el payload
	# supera ese umbral. 4 MB cubre tick messages con hasta ~30 000 vehículos.
	_ws.inbound_buffer_size  = 4 * 1024 * 1024   # 4 MB
	_ws.outbound_buffer_size = 256 * 1024          # 256 KB (saliente es pequeño)
	var err := _ws.connect_to_url(Config.ws_url)
	if err != OK:
		_handle_connection_failed("connect_to_url returned error %d" % err)


## Internal: WebSocket polling ---------------------------------------------

func _poll_websocket() -> void:
	if _state == ConnectionState.DISCONNECTED:
		return

	_ws.poll()

	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if _state != ConnectionState.CONNECTED:
				_on_ws_opened()
			_read_available_packets()

		WebSocketPeer.STATE_CLOSED:
			if _state == ConnectionState.CONNECTING or _state == ConnectionState.CONNECTED:
				var code := _ws.get_close_code()
				var reason := _ws.get_close_reason()
				_on_ws_closed(code, reason)

		WebSocketPeer.STATE_CLOSING:
			pass  # Will transition to CLOSED shortly


func _read_available_packets() -> void:
	if _ws.get_available_packet_count() <= 0:
		return
	# Mover los bytes raw a la cola del worker en una sola operación bajo el
	# mutex. El worker los parseará (binario o JSON) en background y dejará
	# Dictionaries listos para `_drain_queue`.
	_queue_mutex.lock()
	while _ws.get_available_packet_count() > 0:
		# Si la cola raw se acumula es síntoma de que el parser thread no
		# está siguiendo el ritmo (con CPU saturada o un mensaje gigante).
		# Descartamos el más antiguo para mantener la cola acotada.
		if _raw_queue.size() >= Config.WS_MAX_QUEUE_SIZE:
			_raw_queue.pop_front()
		_raw_queue.push_back(_ws.get_packet())
	_queue_mutex.unlock()
	# Despertar al parser: si la cola tenía N elementos nuevos, un único
	# post() basta porque el worker drena todo lo disponible en cada
	# wait(). Esto sub-cuenta los posts vs los items, pero el worker
	# itera el while interno hasta vaciar; no se quedan paquetes huérfanos.
	_parser_semaphore.post()


## Internal: parser thread + queues ----------------------------------------

func _start_parser_thread() -> void:
	_parser_running = true
	_parser_thread.start(_parser_loop)


func _stop_parser_thread() -> void:
	if not _parser_running:
		return
	_parser_running = false
	_parser_semaphore.post()  # despertar para que vea el flag y salga
	if _parser_thread.is_started():
		_parser_thread.wait_to_finish()


## Worker thread: parsea paquetes raw → Dictionaries hasta que se le pida
## salir. Bloqueado en `wait()` cuando no hay trabajo (CPU 0).
func _parser_loop() -> void:
	while true:
		_parser_semaphore.wait()
		if not _parser_running:
			return
		while true:
			_queue_mutex.lock()
			if _raw_queue.is_empty():
				_queue_mutex.unlock()
				break
			var raw: PackedByteArray = _raw_queue.pop_front()
			_queue_mutex.unlock()

			var msg := _parse_packet(raw)
			if msg.is_empty():
				continue

			_queue_mutex.lock()
			_parsed_queue.push_back(msg)
			_queue_mutex.unlock()


## Detecta el formato del paquete por su primer byte y decodifica:
##   0x01  → tick binario (StreamPeerBuffer).
##   0x7B  → JSON ('{') (JSON.parse_string).
## Cualquier otro primer byte se ignora con warning.
func _parse_packet(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty():
		return {}
	var first := raw[0]
	if first == Config.WireProtocol.TICK_BINARY_MAGIC:
		return _decode_tick_binary(raw)
	if first == 0x7B:  # '{'
		var json_str := raw.get_string_from_utf8()
		var parsed = JSON.parse_string(json_str)
		if parsed is Dictionary:
			return parsed
		push_warning("[SimulationClient] JSON parse failed: %s" % json_str.left(80))
		return {}
	push_warning("[SimulationClient] Unknown packet magic 0x%02x" % first)
	return {}


## Decodifica un tick message binario al mismo Dictionary que produciría el
## parser JSON (forma `{type: "tick", tick, sim_time, vehicles, count,
## chunk_index, chunk_total}`) para que `_handle_tick` no necesite cambios.
func _decode_tick_binary(raw: PackedByteArray) -> Dictionary:
	var spb := StreamPeerBuffer.new()
	spb.big_endian = false
	spb.data_array = raw
	spb.seek(0)
	# Header
	var _magic := spb.get_u8()  # 0x01 — ya verificado por el caller
	var _version := spb.get_u8()  # 0x01 — sin lógica de fallback por ahora
	var tick := int(spb.get_u32())
	var sim_time := spb.get_float()
	var chunk_index := int(spb.get_u16())
	var chunk_total := int(spb.get_u16())
	var n := int(spb.get_u32())
	# Per-vehicle
	var vehicles: Array = []
	vehicles.resize(n)
	var status_table: Array[String] = Config.WireProtocol.STATUS_FROM_INT
	var vtype_table: Array[String] = Config.WireProtocol.VTYPE_FROM_INT
	var status_n := status_table.size()
	var vtype_n := vtype_table.size()
	for i in range(n):
		var id_len := spb.get_u8()
		var id_bytes := spb.get_data(id_len)
		var vid: String = ""
		if id_bytes is Array and id_bytes.size() == 2 and id_bytes[0] == OK:
			vid = (id_bytes[1] as PackedByteArray).get_string_from_utf8()
		var lon := spb.get_float()
		var lat := spb.get_float()
		var h := spb.get_float()
		var v := spb.get_float()
		var a := spb.get_float()
		var edge_idx := int(spb.get_u32())
		var progress := spb.get_float()
		var status_int := spb.get_u8()
		var lane := int(spb.get_u8())
		var vtype_int := spb.get_u8()
		var status_str: String = status_table[status_int] if status_int < status_n else "idle"
		var vtype_str: String = vtype_table[vtype_int] if vtype_int < vtype_n else "car"
		vehicles[i] = {
			"id": vid,
			"lon": lon,
			"lat": lat,
			"h": h,
			"v": v,
			"a": a,
			"edge_idx": edge_idx,
			"progress": progress,
			"status": status_str,
			"lane": lane,
			"vtype": vtype_str,
		}
	return {
		"type": Config.SimMessageTypes.TICK,
		"tick": tick,
		"sim_time": sim_time,
		"vehicles": vehicles,
		"count": n,
		"chunk_index": chunk_index,
		"chunk_total": chunk_total,
	}


func _drain_queue() -> void:
	# Extraer hasta WS_MAX_MESSAGES_PER_FRAME mensajes parseados bajo el
	# mutex en una sola operación, y procesarlos fuera. Esto minimiza el
	# tiempo que el main thread retiene el mutex (clave: el parser thread
	# está continuamente queriendo escribir).
	var to_process: Array[Dictionary] = []
	_queue_mutex.lock()
	var limit := mini(_parsed_queue.size(), Config.WS_MAX_MESSAGES_PER_FRAME)
	for _i in range(limit):
		to_process.append(_parsed_queue.pop_front())
	_queue_mutex.unlock()
	for msg in to_process:
		_route_message(msg)


## Internal: message routing -----------------------------------------------

func _route_message(msg: Dictionary) -> void:
	var type := JsonUtils.get_string(msg, "type", "")
	_messages_processed += 1

	match type:
		Config.SimMessageTypes.TICK:
			_handle_tick(msg)

		Config.SimMessageTypes.SIM_STATE:
			var state := JsonUtils.get_string(msg, "state", "")
			sim_state_received.emit(state)

		Config.SimMessageTypes.VEHICLE_SPAWNED:
			var vid := JsonUtils.get_string(msg, "vehicle_id", "")
			vehicle_spawned.emit(vid, msg)

		Config.SimMessageTypes.VEHICLES_BATCH_SPAWNED:
			var arr := JsonUtils.get_array(msg, "vehicles", [])
			vehicles_batch_spawned.emit(arr)

		Config.SimMessageTypes.VEHICLE_FINISHED:
			var vid := JsonUtils.get_string(msg, "vehicle_id", "")
			vehicle_finished.emit(vid)

		Config.SimMessageTypes.TRAFFIC_LIGHT:
			traffic_light_received.emit(msg)

		Config.SimMessageTypes.VEHICLE_COLLISION:
			var vid1 := JsonUtils.get_string(msg, "vehicle_id_1", "")
			var vid2 := JsonUtils.get_string(msg, "vehicle_id_2", "")
			var edge := JsonUtils.get_array(msg, "blocked_edge", [])
			vehicle_collision.emit(vid1, vid2, edge)

		Config.SimMessageTypes.INCIDENT:
			incident_received.emit(msg)

		Config.SimMessageTypes.ZONE:
			zone_received.emit(msg)

		_:
			_log_warning("Unknown message type: '%s'" % type)


func _handle_tick(msg: Dictionary) -> void:
	var tick := JsonUtils.get_int(msg, "tick", 0)
	var sim_time := JsonUtils.get_float(msg, "sim_time", 0.0)
	var vehicles := JsonUtils.get_array(msg, "vehicles", [])
	var chunk_total := JsonUtils.get_int(msg, "chunk_total", 1)

	# Caso frecuente: tick en un solo fragmento — emitir directamente.
	if chunk_total <= 1:
		_flush_pending_if_any()
		_emit_tick(tick, sim_time, vehicles)
		return

	# Si llega el primer chunk de un tick nuevo mientras aún hay uno pendiente,
	# significa que perdimos algún fragmento del anterior; flusheamos lo
	# parcial y arrancamos el nuevo ensamblaje.
	if _pending_tick != tick:
		_flush_pending_if_any()
		_pending_tick = tick
		_pending_sim_time = sim_time
		_pending_tick_vehicles = []
		_pending_chunks_received = 0
		_pending_chunks_total = chunk_total

	_pending_tick_vehicles.append_array(vehicles)
	_pending_chunks_received += 1

	# Tick completo: emitir como una única actualización atómica.
	if _pending_chunks_received >= _pending_chunks_total:
		_emit_tick(_pending_tick, _pending_sim_time, _pending_tick_vehicles)
		_reset_pending_tick()


func _emit_tick(tick: int, sim_time: float, vehicles: Array) -> void:
	# Rolling tick-rate estimate
	var now := Time.get_ticks_msec() / 1000.0
	if _ticks_received > 0 and _last_tick_time > 0.0:
		var dt := now - _last_tick_time
		if dt > 0.0:
			_measured_tick_rate = 1.0 / dt
	_last_tick_time = now
	_ticks_received += 1

	tick_received.emit(tick, sim_time, vehicles)


func _flush_pending_if_any() -> void:
	if _pending_tick < 0:
		return
	if _pending_tick_vehicles.size() > 0:
		_log_warning(
			"Tick %d incompleto: %d/%d chunks — emitiendo parcial" % [
				_pending_tick,
				_pending_chunks_received,
				_pending_chunks_total,
			]
		)
		_emit_tick(_pending_tick, _pending_sim_time, _pending_tick_vehicles)
	_reset_pending_tick()


func _reset_pending_tick() -> void:
	_pending_tick = -1
	_pending_sim_time = 0.0
	_pending_tick_vehicles = []
	_pending_chunks_received = 0
	_pending_chunks_total = 0


## Internal: connection events ---------------------------------------------

func _on_ws_opened() -> void:
	_state = ConnectionState.CONNECTED
	_reconnect_attempts = 0
	_ticks_received = 0
	_messages_processed = 0
	_measured_tick_rate = 0.0
	_queue_mutex.lock()
	_raw_queue.clear()
	_parsed_queue.clear()
	_queue_mutex.unlock()
	_reset_pending_tick()
	_log_info("WebSocket connected to %s" % Config.ws_url)
	connected.emit()


func _on_ws_closed(code: int, reason: String) -> void:
	_state = ConnectionState.DISCONNECTED
	_log_info("WebSocket closed (code=%d reason='%s')" % [code, reason])
	disconnected.emit()
	_schedule_reconnect()


func _handle_connection_failed(reason: String) -> void:
	_state = ConnectionState.DISCONNECTED
	_log_warning("Connection failed: %s" % reason)
	connection_failed.emit(reason)
	_schedule_reconnect()


## Internal: reconnection with exponential backoff -------------------------

func _schedule_reconnect() -> void:
	_state = ConnectionState.RECONNECTING
	var delay := _backoff_delay()
	_reconnect_attempts += 1
	_log_info("Reconnecting in %.1fs (attempt %d)..." % [delay, _reconnect_attempts])
	_reconnect_timer.start(delay)


func _do_reconnect() -> void:
	_connect_to_backend()


func _backoff_delay() -> float:
	var delay := Config.WS_BASE_RECONNECT_DELAY * pow(2.0, _reconnect_attempts)
	return minf(delay, Config.WS_MAX_RECONNECT_DELAY)


## Internal: periodic stat logging -----------------------------------------

func _update_stats_log(delta: float) -> void:
	if _state != ConnectionState.CONNECTED:
		return
	_stats_timer += delta
	if _stats_timer >= Config.WS_STATS_LOG_INTERVAL:
		_stats_timer = 0.0
		_log_info(
			"Receiving tick messages at %.1f/s — messages processed: %d" % [
				_measured_tick_rate,
				_messages_processed,
			]
		)


## Internal: logging -------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[SimulationClient] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[SimulationClient] %s" % message)


func _log_error(message: String) -> void:
	if Config.should_log(Config.LogLevel.ERROR):
		push_error("[SimulationClient] %s" % message)
