## IncidentManager autoload singleton
## Receives incident_created messages from SimulationClient and tracks
## active incidents in the simulation area.
##
## Stub implementation — to be expanded in a future sprint with
## incident visualization and alert UI.
extends Node


## Emitted when a new incident is reported
signal incident_created(incident_id: String, data: Dictionary)


## Active incidents: id → data dict
var incidents: Dictionary = {}

## Total incidents received since last connect
var total_incidents: int = 0


func _ready() -> void:
	SimulationClient.incident_received.connect(_on_incident)
	SimulationClient.connected.connect(_on_connected)
	_log_info("Initialized (stub)")


func get_incident_count() -> int:
	return incidents.size()


func get_incident(incident_id: String) -> Dictionary:
	return incidents.get(incident_id, {})


## Handlers ----------------------------------------------------------------

func _on_incident(data: Dictionary) -> void:
	var iid := JsonUtils.get_string(data, "incident_id", "")
	if iid.is_empty():
		# Generate a fallback key from index
		iid = "inc_%d" % total_incidents
	incidents[iid] = data
	total_incidents += 1
	incident_created.emit(iid, data)
	_log_info("Incident reported: %s (total: %d)" % [iid, total_incidents])


func _on_connected() -> void:
	incidents.clear()
	total_incidents = 0


## Logging -----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[IncidentManager] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[IncidentManager] %s" % message)
