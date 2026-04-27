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


## Devuelve el primer incidente activo sobre la arista (u,v), o {} si no
## hay ninguno. Lo usa el modo "Reabrir tramo" para localizar qué incidente
## hay que retirar al pulsar sobre un tramo cerrado.
func find_active_incident_on_edge(u: int, v: int) -> Dictionary:
	for inc in incidents.values():
		if inc.get("status", "") != "active":
			continue
		var edge: Array = inc.get("edge", [])
		if edge.size() == 2 and int(edge[0]) == u and int(edge[1]) == v:
			return inc
	return {}


## Color del overlay para un tipo de incidente. Si el tipo no se reconoce,
## se cae a `UNKNOWN`. La severidad se ignora aquí (el plan de demo asocia
## el color al tipo, no a la gravedad), pero se mantiene en la firma por
## si en el futuro se quiere modular el alpha.
static func color_for(incident_type: String, _severity: int = 1) -> Color:
	match incident_type:
		"accident":
			return Config.IncidentColors.ACCIDENT
		"roadwork":
			return Config.IncidentColors.ROADWORK
		"breakdown":
			return Config.IncidentColors.BREAKDOWN
		"event":
			return Config.IncidentColors.EVENT
		_:
			return Config.IncidentColors.UNKNOWN


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
			return
	refresh_overlays()


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
	refresh_overlays()


## Construye el dict {edge_id: Color} con los incidentes activos y lo
## empuja al EdgeRenderer. Si la red no está cargada todavía (o el edge_id
## viene a 0 — incidente sintético sin BD), ese tramo se ignora silenciosamente.
##
## Idempotente: se puede llamar tantas veces como se quiera. La debe invocar
## el EdgeRenderer al terminar de pintar la red, para cubrir el caso en que
## el snapshot inicial de incidentes haya llegado por WS antes de que la red
## se haya cargado.
func refresh_overlays() -> void:
	var edge_renderer := get_tree().get_first_node_in_group("edge_renderer")
	if edge_renderer == null:
		return  # red sin renderizar aún (HUD seguirá mostrando la lista)
	var overlays: Dictionary = {}
	for inc in incidents.values():
		if inc.get("status", "") != "active":
			continue
		var edge_id := int(inc.get("edge_id", 0))
		if edge_id <= 0:
			continue
		var lanes_affected: Array = inc.get("lanes_affected", [])
		# Solo pintamos el overlay para cierres "totales" (todos los carriles).
		# Cierres parciales mantienen su cilindro 3D actual del IncidentRenderer
		# y la lista del HUD; pintar overlay para 1-de-3 carriles confundiría
		# visualmente al operador. La heurística: si la cuenta de lanes_affected
		# coincide con `edge.lanes` del renderer, es total. Si no, lo dejamos
		# fuera. Como el edge_id está, podemos consultarlo:
		var edge: EdgeData = edge_renderer.get_edge_by_id(edge_id)
		if edge == null:
			continue
		if lanes_affected.size() < edge.lanes:
			continue  # cierre parcial — no overlay
		var color: Color = color_for(String(inc.get("type", "")), int(inc.get("severity", 1)))
		overlays[edge_id] = color
	edge_renderer.set_edge_overlays(overlays)


## Logging -----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[IncidentManager] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[IncidentManager] %s" % message)
