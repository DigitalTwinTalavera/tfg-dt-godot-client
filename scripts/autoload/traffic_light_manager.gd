## TrafficLightManager autoload singleton
## Receives traffic_light messages from SimulationClient and maintains
## the state of all traffic lights in the simulation.
##
## Protocolo (version: 2): el backend envía estados POR ARISTA de aproximación.
## Cada nodo agrupa sus aristas entrantes en 2 ejes con fases opuestas, de
## modo que un cruce N-S puede estar verde mientras E-O está rojo.
##
## Formato del mensaje:
##   { type: "traffic_light", version: 2,
##     states: { "<node_id>": { "<u>_<v>": "red"|"yellow"|"green", ... } } }
extends Node


## Señal legada: fase representativa del nodo (primera arista) — para HUD.
signal traffic_light_updated(node_id: int, phase: String)

## Señal nueva: fase por arista entrante concreta — usada por el renderer
## para pintar una luz por cada calle que llega al cruce.
signal traffic_light_edge_updated(node_id: int, edge_key: String, phase: String)


## Estado actual: { node_id (int) → { edge_key (String) → phase (String) } }
var traffic_lights: Dictionary = {}


func _ready() -> void:
	SimulationClient.traffic_light_received.connect(_on_traffic_light)
	SimulationClient.connected.connect(_on_connected)
	_log_info("Initialized (per-edge phases)")


func get_light_count() -> int:
	return traffic_lights.size()


## Devuelve el dict {edge_key: phase} de un nodo, o {} si no existe.
func get_light_edges(node_id: int) -> Dictionary:
	return traffic_lights.get(node_id, {})


## Fase concreta de una arista entrante (edge_key = "u_v"). Devuelve ""
## si el nodo o la arista no existen.
func get_phase_for_edge(node_id: int, edge_key: String) -> String:
	var edges: Dictionary = traffic_lights.get(node_id, {})
	return edges.get(edge_key, "")


## Handlers ----------------------------------------------------------------

func _on_traffic_light(data: Dictionary) -> void:
	var states: Dictionary = data.get("states", {})
	if states.is_empty():
		_log_warning("Received traffic_light message without states dict")
		return

	var version: int = int(data.get("version", 1))
	for node_id_str in states:
		var raw = states[node_id_str]
		var node_id: int = int(node_id_str)

		# Normalizar a formato anidado { edge_key: phase }
		var edge_phases: Dictionary = {}
		if typeof(raw) == TYPE_DICTIONARY:
			edge_phases = raw
		else:
			# Legacy (version 1): un solo string — fingimos una arista "*"
			edge_phases = {"*": String(raw)}

		traffic_lights[node_id] = edge_phases

		# Emitir señal por arista para el renderer
		for edge_key in edge_phases:
			var phase: String = String(edge_phases[edge_key])
			traffic_light_edge_updated.emit(node_id, String(edge_key), phase)

		# Señal legada con la fase representativa (primera arista) para HUD
		if not edge_phases.is_empty():
			var first_phase: String = String(edge_phases.values()[0])
			traffic_light_updated.emit(node_id, first_phase)

	_log_debug("Traffic lights batch updated: %d semáforos (v%d)" % [states.size(), version])


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
