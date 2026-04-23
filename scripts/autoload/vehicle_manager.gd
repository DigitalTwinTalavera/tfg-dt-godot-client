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


## Active vehicles: id (String) → state (Dictionary)
var vehicles: Dictionary = {}

## Cumulative counters (reset on reconnect)
var total_spawned: int = 0
var total_finished: int = 0


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


## Returns the state dict for a specific vehicle, or an empty dict if not found
func get_vehicle(vehicle_id: String) -> Dictionary:
	return vehicles.get(vehicle_id, {})


## Returns all vehicle IDs currently tracked
func get_all_ids() -> Array:
	return vehicles.keys()


## Returns a snapshot copy of all vehicle states
func get_all_vehicles() -> Dictionary:
	return vehicles.duplicate(true)


## Handlers ----------------------------------------------------------------

func _on_tick(_tick: int, sim_time: float, vehicle_states: Array) -> void:
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

		if vehicles.has(vid):
			# Delta update: merge changed fields into existing entry.
			# NO emitimos `vehicle_updated` por vehículo — con 6000 vehículos
			# son 60 000 signal dispatches/s que bloqueaban el main thread y
			# provocaban frame drops visibles como tirones. El renderer
			# consume el array entero en una sola llamada vía `tick_received`.
			vehicles[vid].merge(state, true)
		else:
			# New vehicle seen for the first time via tick
			vehicles[vid] = state.duplicate()
			new_batch.append([vid, vehicles[vid]])

		updated += 1

	# Emit all new vehicles in a single batch signal so the renderer can
	# allocate all slots and call _set_visible_count() only once.
	if new_batch.size() > 0:
		vehicles_batch_added.emit(new_batch)

	if updated > 0:
		vehicles_batch_updated.emit(updated)


func _on_vehicle_spawned(vehicle_id: String, data: Dictionary) -> void:
	if not vehicles.has(vehicle_id):
		vehicles[vehicle_id] = {"id": vehicle_id}
	vehicles[vehicle_id].merge(data, true)
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
		if not vehicles.has(vid):
			vehicles[vid] = data.duplicate()
		else:
			vehicles[vid].merge(data, true)
		pairs.append([vid, vehicles[vid]])
	total_spawned += pairs.size()
	if pairs.size() > 0:
		vehicles_batch_added.emit(pairs)
	_log_info("Batch spawned: %d vehicles (active: %d)" % [pairs.size(), vehicles.size()])


func _on_vehicle_finished(vehicle_id: String) -> void:
	if vehicles.has(vehicle_id):
		vehicles.erase(vehicle_id)
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
