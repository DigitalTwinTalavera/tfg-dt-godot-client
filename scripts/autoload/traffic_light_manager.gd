## TrafficLightManager autoload singleton
## Receives traffic_light messages from SimulationClient and maintains
## the state of all traffic lights in the simulation.
##
## Stub implementation — to be expanded in a future sprint with
## actual 3D traffic light rendering and signal-cycle logic.
extends Node


## Emitted when a traffic light state is updated
signal traffic_light_updated(light_id: String, state: Dictionary)


## Active traffic lights: id → state dict
var traffic_lights: Dictionary = {}


func _ready() -> void:
	SimulationClient.traffic_light_received.connect(_on_traffic_light)
	SimulationClient.connected.connect(_on_connected)
	_log_info("Initialized (stub)")


func get_light_count() -> int:
	return traffic_lights.size()


func get_light(light_id: String) -> Dictionary:
	return traffic_lights.get(light_id, {})


## Handlers ----------------------------------------------------------------

func _on_traffic_light(data: Dictionary) -> void:
	var lid := JsonUtils.get_string(data, "light_id", "")
	if lid.is_empty():
		_log_warning("Received traffic_light message without light_id")
		return
	traffic_lights[lid] = data
	traffic_light_updated.emit(lid, data)
	_log_debug("Traffic light updated: %s" % lid)


func _on_connected() -> void:
	traffic_lights.clear()


## Logging -----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[TrafficLightManager] %s" % message)


func _log_debug(message: String) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TrafficLightManager] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[TrafficLightManager] %s" % message)
