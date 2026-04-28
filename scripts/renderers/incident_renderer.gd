## IncidentRenderer
## Dibuja un marcador 3D por cada incidente activo. Un MeshInstance3D por
## incidente (son pocos: decenas como mucho) con un cilindro corto coloreado
## por severidad. El incidente se coloca en el midpoint de su arista.
##
## Se enlaza vía IncidentManager (autoload). La escena contenedora debe
## llamar a ``setup(converter, graph_service)`` una vez tras cargar la red.
class_name IncidentRenderer
extends Node3D


## Indexado por severity-1 (severity 1/2/3 → 0/1/2). Valores tomados de
## Config.IncidentSeverityColors para mantener una sola fuente de verdad.
static var SEVERITY_COLORS: Array[Color] = [
	Config.IncidentSeverityColors.LOW,
	Config.IncidentSeverityColors.MEDIUM,
	Config.IncidentSeverityColors.HIGH,
]
const MARKER_HEIGHT_M: float = 3.0
const MARKER_RADIUS_M: float = 1.5


var _converter: CoordinateConverter = null

## Fuente de coordenadas de nodos. Debe exponer ``get_node_lonlat(node_id)``
## devolviendo Vector2(lon, lat). Lo inyecta la escena tras cargar la red.
var _node_lookup: Callable = Callable()

## incident_id → MeshInstance3D
var _markers: Dictionary = {}


func _ready() -> void:
	IncidentManager.incident_created.connect(_on_created)
	IncidentManager.incident_updated.connect(_on_updated)
	IncidentManager.incident_cleared.connect(_on_cleared)


func setup(converter: CoordinateConverter, node_lookup: Callable) -> void:
	_converter = converter
	_node_lookup = node_lookup
	# Re-dibujar los incidentes ya recibidos antes del setup.
	for iid in IncidentManager.incidents:
		_on_created(iid, IncidentManager.incidents[iid])


func _on_created(incident_id: int, data: Dictionary) -> void:
	if _converter == null or not _node_lookup.is_valid():
		return
	var mesh := _build_marker(data)
	if mesh == null:
		return
	_markers[incident_id] = mesh
	add_child(mesh)


func _on_updated(incident_id: int, data: Dictionary) -> void:
	# Re-colorear si cambió severity; reposicionar si cambió edge.
	var existing: MeshInstance3D = _markers.get(incident_id, null)
	if existing != null:
		existing.queue_free()
		_markers.erase(incident_id)
	_on_created(incident_id, data)


func _on_cleared(incident_id: int, _data: Dictionary) -> void:
	var existing: MeshInstance3D = _markers.get(incident_id, null)
	if existing != null:
		existing.queue_free()
		_markers.erase(incident_id)


func _build_marker(data: Dictionary) -> MeshInstance3D:
	var edge: Array = data.get("edge", [])
	if edge.size() != 2:
		return null
	var p1: Vector2 = _node_lookup.call(int(edge[0]))
	var p2: Vector2 = _node_lookup.call(int(edge[1]))
	if p1 == Vector2.ZERO and p2 == Vector2.ZERO:
		return null
	var mid_lon: float = (p1.x + p2.x) * 0.5
	var mid_lat: float = (p1.y + p2.y) * 0.5
	var world := _converter.gps_to_godot(mid_lon, mid_lat, MARKER_HEIGHT_M * 0.5)

	var cyl := CylinderMesh.new()
	cyl.top_radius = MARKER_RADIUS_M
	cyl.bottom_radius = MARKER_RADIUS_M
	cyl.height = MARKER_HEIGHT_M

	var mat := StandardMaterial3D.new()
	var severity := int(data.get("severity", 1))
	var idx: int = clamp(severity - 1, 0, SEVERITY_COLORS.size() - 1)
	mat.albedo_color = SEVERITY_COLORS[idx]
	mat.emission_enabled = true
	mat.emission = SEVERITY_COLORS[idx]
	mat.emission_energy_multiplier = 0.6
	cyl.material = mat

	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.position = world
	mi.name = "Incident_%d" % int(data.get("id", 0))
	return mi
