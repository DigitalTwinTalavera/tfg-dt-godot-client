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

## Message queue (bounded ring-buffer behaviour)
var _message_queue: Array[Dictionary] = []

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
	_connect_to_backend()
	_log_info("Initialized — connecting to %s" % Config.ws_url)


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
	return {
		"state": ConnectionState.keys()[_state],
		"ticks_received": _ticks_received,
		"messages_processed": _messages_processed,
		"measured_tick_rate": snappedf(_measured_tick_rate, 0.1),
		"queue_size": _message_queue.size(),
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
	while _ws.get_available_packet_count() > 0:
		var raw := _ws.get_packet()
		var json_str := raw.get_string_from_utf8()
		var result := JsonUtils.parse(json_str)
		if result.success and result.data is Dictionary:
			_enqueue(result.data)
		else:
			_log_warning("Failed to parse packet: %s" % json_str.left(80))


## Internal: message queue -------------------------------------------------

func _enqueue(msg: Dictionary) -> void:
	if _message_queue.size() >= Config.WS_MAX_QUEUE_SIZE:
		_message_queue.pop_front()  # drop oldest to make room
	_message_queue.push_back(msg)


func _drain_queue() -> void:
	var limit := mini(_message_queue.size(), Config.WS_MAX_MESSAGES_PER_FRAME)
	for _i in range(limit):
		_route_message(_message_queue.pop_front())


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
	var chunk_index := JsonUtils.get_int(msg, "chunk_index", 0)
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
	_message_queue.clear()
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
