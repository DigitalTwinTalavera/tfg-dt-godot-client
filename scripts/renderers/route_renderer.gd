## RouteRenderer
## Dibuja la ruta pendiente de un vehículo como una polilínea 3D elevada
## ligeramente sobre la calzada. Sólo hay UNA ruta visible a la vez — la del
## vehículo seleccionado en el HUD.
class_name RouteRenderer
extends Node3D


const LINE_HEIGHT_M: float = 4.0
const LINE_WIDTH_M: float = 0.8
const COLOR: Color = Color(1.00, 0.45, 0.05, 0.95)


var _converter: CoordinateConverter = null
var _network: RoadNetwork = null
var _mesh_instance: MeshInstance3D = null


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	add_child(_mesh_instance)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = COLOR
	mat.emission_enabled = true
	mat.emission = COLOR
	mat.emission_energy_multiplier = 0.8
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mesh_instance.material_override = mat


func setup(converter: CoordinateConverter, network: RoadNetwork) -> void:
	_converter = converter
	_network = network


func set_network(network: RoadNetwork) -> void:
	_network = network


## Dibuja la ruta pendiente. ``route_edges`` = array de edge_id (ints).
## ``current_edge_index`` = índice dentro de route_edges del edge actual (se
## excluyen los ya recorridos).
func show_route(route_edges: Array, current_edge_index: int = 0) -> void:
	clear_route()
	if _converter == null or _network == null:
		return
	if route_edges.is_empty():
		return

	var points: PackedVector3Array = PackedVector3Array()
	var start_idx: int = max(0, int(current_edge_index))
	var added_nodes: Dictionary = {}  # evita duplicar nodos compartidos
	for i in range(start_idx, route_edges.size()):
		var eid: int = int(route_edges[i])
		var ed: EdgeData = _network.get_edge(eid)
		if ed == null:
			continue
		var u: NodeData = _network.get_node(ed.start_node_id)
		var v: NodeData = _network.get_node(ed.end_node_id)
		if u == null or v == null:
			continue
		if not added_nodes.has(u.id):
			points.append(_converter.gps_to_godot(u.longitude, u.latitude, LINE_HEIGHT_M))
			added_nodes[u.id] = true
		points.append(_converter.gps_to_godot(v.longitude, v.latitude, LINE_HEIGHT_M))
		added_nodes[v.id] = true

	if points.size() < 2:
		return

	_mesh_instance.mesh = _build_ribbon(points, LINE_WIDTH_M)


func clear_route() -> void:
	if _mesh_instance != null:
		_mesh_instance.mesh = null


## Construye una cinta horizontal a lo largo de ``points`` con ancho
## ``width``. Cada segmento genera 2 triángulos. Más ligero que ImmediateMesh
## y soporta antialiasing por shader unshaded.
func _build_ribbon(points: PackedVector3Array, width: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_w := width * 0.5
	for i in range(points.size() - 1):
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var dir := b - a
		dir.y = 0.0
		if dir.length_squared() < 0.0001:
			continue
		var perp := Vector3(-dir.z, 0.0, dir.x).normalized() * half_w
		var v0 := a + perp
		var v1 := a - perp
		var v2 := b + perp
		var v3 := b - perp
		st.add_vertex(v0); st.add_vertex(v2); st.add_vertex(v1)
		st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v3)
	return st.commit()
