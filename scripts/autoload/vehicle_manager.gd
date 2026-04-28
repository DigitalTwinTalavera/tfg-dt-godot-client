## VehicleManager autoload singleton
## Receives vehicle data from SimulationClient and maintains the live
## vehicle state dictionary used by renderers and debug panels.
##
## Vehicle state dict keys (from backend tick message):
##   id        - String vehicle ID ("v_001")
##   lon, lat  - float GPS position
##   v         - float velocity (m/s)
##   a         - float acceleration (m/s²)
##   h         - float compass heading (0=N, 90=E)
##   status    - String ("idle" | "moving" | "finished")
##   edge_idx  - int current edge index in route
##   progress  - float 0.0..1.0 progress along current edge
##   lane      - int lane occupied (0 = rightmost)
##   vtype     - String ("car" | "moto" | "truck")
extends Node


## Emitted when a vehicle is newly added to the active set (individual path)
signal vehicle_added(vehicle_id: String, state: Dictionary)

## Emitted when a vehicle's state changes (delta update)
signal vehicle_updated(vehicle_id: String, state: Dictionary)

## Emitted when a vehicle is removed from the active set
signal vehicle_removed(vehicle_id: String)

## Emitted once per tick with all new vehicles as Array of [vehicle_id, state]
## Use this instead of vehicle_added for batch rendering (avoids N GPU calls)
signal vehicles_batch_added(batch: Array)

## Emitted at the end of each tick with the total number of vehicles updated
signal vehicles_batch_updated(count: int)


## Active vehicles: id (String) → state (Dictionary) — actualizado por tick.
## Contiene SOLO los campos del último tick (lon, lat, v, a, h, status,
## edge_idx, progress, lane, vtype, _sim_time). Los campos del spawn
## (route_edges, start_node_id, end_node_id, route_length_m) viven en
## `_vehicles_meta` para evitar copiarlos en cada tick.
var vehicles: Dictionary = {}

## Spawn-time metadata: id → Dictionary con campos que NO cambian tras el
## spawn (route_edges, start_node_id, end_node_id, route_length_m, etc.).
## Se rellena desde `_on_vehicle_spawned` y `_on_vehicles_batch_spawned`,
## y se limpia en `_on_vehicle_finished`. `get_vehicle()` lo combina con
## `vehicles[vid]` para los consumidores que esperan el dict completo.
var _vehicles_meta: Dictionary = {}

## Cumulative counters (reset on reconnect)
var total_spawned: int = 0
var total_finished: int = 0

## Stats de rendimiento del handler `_on_tick`. Usado para detectar tirones
## sin necesidad de un overlay: cada PERF_LOG_INTERVAL ticks emitimos un
## resumen con tiempo medio y máximo del tick, y FPS actual.
const _PERF_LOG_INTERVAL: int = 100
var _perf_tick_count: int = 0
var _perf_sum_us: int = 0
var _perf_max_us: int = 0


func _ready() -> void:
	SimulationClient.tick_received.connect(_on_tick)
	SimulationClient.vehicle_spawned.connect(_on_vehicle_spawned)
	SimulationClient.vehicle_finished.connect(_on_vehicle_finished)
	SimulationClient.vehicles_batch_spawned.connect(_on_vehicles_batch_spawned)
	SimulationClient.connected.connect(_on_connected)
	_log_info("Initialized")


## Returns the number of currently tracked vehicles
func get_vehicle_count() -> int:
	return vehicles.size()


## Returns the state dict for a specific vehicle, or an empty dict if not found.
## Combina los campos del último tick con la metadata del spawn (route_edges,
## start_node_id, end_node_id, …) para que los consumidores de UI vean el
## dict completo sin necesidad de saber sobre la separación interna.
func get_vehicle(vehicle_id: String) -> Dictionary:
	var state: Dictionary = vehicles.get(vehicle_id, {})
	if state.is_empty():
		return {}
	var meta: Dictionary = _vehicles_meta.get(vehicle_id, {})
	if meta.is_empty():
		return state
	# meta primero, state encima: si un campo aparece en ambos (lon/lat,
	# vtype, lane), gana el del tick (más reciente).
	var combined: Dictionary = meta.duplicate()
	combined.merge(state, true)
	return combined


## Returns all vehicle IDs currently tracked
func get_all_ids() -> Array:
	return vehicles.keys()


## Returns a snapshot copy of all vehicle states (con metadata del spawn).
func get_all_vehicles() -> Dictionary:
	var out: Dictionary = {}
	for vid in vehicles:
		out[vid] = get_vehicle(vid)
	return out


## Handlers ----------------------------------------------------------------

func _on_tick(_tick: int, sim_time: float, vehicle_states: Array) -> void:
	var t0 := Time.get_ticks_usec()
	var updated := 0
	var new_batch: Array = []

	for state in vehicle_states:
		if not state is Dictionary:
			continue
		var vid := JsonUtils.get_string(state, "id", "")
		if vid.is_empty():
			continue

		# Sella el snapshot con el sim_time del servidor. El renderer lo usa
		# para la interpolación basada en reloj de servidor (sin depender del
		# tiempo local de llegada del mensaje).
		state["_sim_time"] = sim_time

		# Asignación directa: el `state` viene fresh del parser (cada tick
		# es un Dictionary nuevo) y los campos invariantes del spawn viven
		# en `_vehicles_meta`. Esto reemplaza el `merge(state, true)` que
		# costaba ~10 dict-writes por vehículo y por tick — con 5000 vehs
		# a 10 Hz son 500 000 ops/s en main thread. NO emitimos
		# `vehicle_updated` por vehículo: el renderer consume el array
		# completo en una sola llamada vía `tick_received`.
		var was_new := not vehicles.has(vid)
		vehicles[vid] = state

		if was_new:
			new_batch.append([vid, state])

		updated += 1

	# Emit all new vehicles in a single batch signal so the renderer can
	# allocate all slots and call _set_visible_count() only once.
	if new_batch.size() > 0:
		vehicles_batch_added.emit(new_batch)

	if updated > 0:
		vehicles_batch_updated.emit(updated)

	# Stats de tiempo de procesado del tick (microsegundos). Cada
	# _PERF_LOG_INTERVAL ticks loggeamos avg/max + FPS y vehículos activos.
	var dt_us := Time.get_ticks_usec() - t0
	_perf_sum_us += dt_us
	if dt_us > _perf_max_us:
		_perf_max_us = dt_us
	_perf_tick_count += 1
	if _perf_tick_count >= _PERF_LOG_INTERVAL:
		var avg_ms := (_perf_sum_us / float(_perf_tick_count)) / 1000.0
		var max_ms := _perf_max_us / 1000.0
		_log_info(
			"Perf: on_tick avg=%.2f ms max=%.2f ms | FPS=%.0f | active=%d" % [
				avg_ms, max_ms, Engine.get_frames_per_second(), vehicles.size(),
			]
		)
		_perf_sum_us = 0
		_perf_max_us = 0
		_perf_tick_count = 0


func _on_vehicle_spawned(vehicle_id: String, data: Dictionary) -> void:
	# El mensaje `vehicle_spawned` trae los campos meta (route_edges,
	# start_node_id, end_node_id, route_length_m) además de algunos de
	# state. Guardamos meta en _vehicles_meta para que sobreviva al
	# refresh del tick, y dejamos que el primer tick rellene el state.
	_vehicles_meta[vehicle_id] = data
	if not vehicles.has(vehicle_id):
		# Inicializa el state con el data del spawn por si la UI consulta
		# antes de que llegue el primer tick.
		vehicles[vehicle_id] = data
	total_spawned += 1
	vehicle_added.emit(vehicle_id, vehicles[vehicle_id])
	_log_info(
		"Vehicle spawned: %s  (active: %d  total spawned: %d)" % [
			vehicle_id,
			vehicles.size(),
			total_spawned,
		]
	)


func _on_vehicles_batch_spawned(batch: Array) -> void:
	var pairs: Array = []
	for data in batch:
		if not data is Dictionary:
			continue
		var vid := JsonUtils.get_string(data, "id", "")
		if vid.is_empty():
			continue
		_vehicles_meta[vid] = data
		if not vehicles.has(vid):
			vehicles[vid] = data
		pairs.append([vid, vehicles[vid]])
	total_spawned += pairs.size()
	if pairs.size() > 0:
		vehicles_batch_added.emit(pairs)
	_log_info("Batch spawned: %d vehicles (active: %d)" % [pairs.size(), vehicles.size()])


func _on_vehicle_finished(vehicle_id: String) -> void:
	if vehicles.has(vehicle_id):
		vehicles.erase(vehicle_id)
		_vehicles_meta.erase(vehicle_id)
		total_finished += 1
		vehicle_removed.emit(vehicle_id)
		_log_debug(
			"Vehicle finished: %s  (remaining: %d  total finished: %d)" % [
				vehicle_id,
				vehicles.size(),
				total_finished,
			]
		)


func _on_connected() -> void:
	vehicles.clear()
	_vehicles_meta.clear()
	total_spawned = 0
	total_finished = 0
	_log_info("Reset — connection established")


## Logging -----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[VehicleManager] %s" % message)


func _log_debug(message: String) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[VehicleManager] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[VehicleManager] %s" % message)
