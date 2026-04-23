## IncidentManager autoload singleton
## Mantiene el estado vivo de los incidentes de tráfico y emite señales
## para que el renderer dibuje marcadores y los edges afectados.
##
## Protocolo WS: el backend emite eventos de tipo "incident":
##   { type: "incident", action: "created"|"updated"|"cleared",
##     incident: { id, type, edge:[u,v], edge_id, lanes_affected,
##                 start_time, duration_s, severity, status, description } }
extends Node


signal incident_created(incident_id: int, data: Dictionary)
signal incident_updated(incident_id: int, data: Dictionary)
signal incident_cleared(incident_id: int, data: Dictionary)


## Estado vivo: { incident_id → incident dict }.
var incidents: Dictionary = {}


func _ready() -> void:
	SimulationClient.incident_received.connect(_on_incident)
	SimulationClient.connected.connect(_on_connected)
	_log_info("Initialized")


func get_incident(incident_id: int) -> Dictionary:
	return incidents.get(incident_id, {})


func get_all_incidents() -> Array:
	return incidents.values()


func get_incident_count() -> int:
	return incidents.size()


## Consulta: devuelve la lista de carriles cerrados sobre una arista (u,v).
## Útil para el edge_renderer a la hora de pintar rayas diagonales.
func closed_lanes_on_edge(u: int, v: int) -> Array:
	var result: Array[int] = []
	var seen := {}
	for inc in incidents.values():
		if inc.get("status", "") != "active":
			continue
		var edge: Array = inc.get("edge", [])
		if edge.size() != 2 or int(edge[0]) != u or int(edge[1]) != v:
			continue
		for lane in inc.get("lanes_affected", []):
			var li := int(lane)
			if not seen.has(li):
				seen[li] = true
				result.append(li)
	return result


## Handlers ----------------------------------------------------------------

func _on_incident(msg: Dictionary) -> void:
	var action: String = String(msg.get("action", ""))
	var inc: Dictionary = msg.get("incident", {})
	if inc.is_empty():
		_log_warning("Mensaje 'incident' sin payload")
		return
	var iid: int = int(inc.get("id", 0))
	match action:
		"created":
			incidents[iid] = inc
			incident_created.emit(iid, inc)
		"updated":
			incidents[iid] = inc
			incident_updated.emit(iid, inc)
		"cleared":
			incidents.erase(iid)
			incident_cleared.emit(iid, inc)
		_:
			_log_warning("Acción de incidente desconocida: '%s'" % action)


func _on_connected() -> void:
	incidents.clear()
	# Al conectar, sembrar el estado con la lista actual vía HTTP.
	_request_initial_snapshot()


func _request_initial_snapshot() -> void:
	var result: HTTPResult = await HTTPManager.get_request("/incidents")
	if not result.success or result.data == null:
		return
	var items: Array = result.data.get("incidents", [])
	for inc in items:
		var iid := int(inc.get("id", 0))
		incidents[iid] = inc
		incident_created.emit(iid, inc)


## Logging -----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[IncidentManager] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[IncidentManager] %s" % message)
