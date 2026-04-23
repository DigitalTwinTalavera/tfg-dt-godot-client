## Node Renderer using MultiMeshInstance3D for efficient rendering
## Renders road network nodes as 3D spheres with color coding by type
##
## Performance: Uses MultiMesh to render 5000+ nodes in a single draw call
## Features:
##   - Per-instance colors based on node type
##   - LOD system for distant nodes
##   - Node selection via raycast
##   - Hover detection for debug info
##
## Traffic lights (TRAFFIC_LIGHT nodes) use a SEPARATE MultiMesh with radio FIJO
## (Config.NodeRendering.TL_FIXED_RADIUS) y UNA INSTANCIA POR ARISTA DE
## APROXIMACIÓN: en un cruce de 4 brazos se dibujan 4 esferas independientes,
## cada una justo antes de la línea de stop de su calle, coloreadas según la
## fase de ese brazo concreto (N-S verde mientras E-O rojo, p.ej.).
class_name NodeRenderer
extends Node3D


signal node_selected(node_data: NodeData)
signal node_hovered(node_data: NodeData)
signal node_hover_ended()
signal render_complete(node_count: int)


## MultiMesh para nodos normales (intersecciones, etc.) — radio escalable.
var _multi_mesh_instance: MultiMeshInstance3D

## MultiMesh exclusiva para semáforos — radio FIJO, una instancia por arista
## entrante. Se mantiene separada para poder ocultarla/escalarla aparte.
var _tl_multi_mesh_instance: MultiMeshInstance3D

## Reference to the coordinate converter
var _converter: CoordinateConverter

## Regular nodes: instance → NodeData
var _instance_to_node: Array[NodeData] = []
var _node_id_to_instance: Dictionary = {}  # int -> int
var _node_count: int = 0

## TL instances: cada instancia representa UN semáforo de UN brazo.
##   _tl_instance_to_node[i] → NodeData del nodo (compartido entre instancias del mismo cruce)
##   _tl_instance_to_edge_key[i] → "u_v" (edge_key de la arista entrante)
##   _tl_edge_key_to_instance["<nid>_<u>_<v>"] → i
##   _tl_node_id_to_first_instance[nid] → primera instancia del nodo (para selección/HUD)
var _tl_instance_to_node: Array[NodeData] = []
var _tl_instance_to_edge_key: Array[String] = []
var _tl_edge_key_to_instance: Dictionary = {}       # "nid_u_v" -> int
var _tl_node_id_to_first_instance: Dictionary = {}  # int -> int
var _tl_count: int = 0

var _selected_node: NodeData = null
var _hovered_node: NodeData = null
var _collision_areas: Array[Area3D] = []

## Sphere radius for rendering (regular nodes only)
var _node_radius: float = Config.NodeRendering.DEFAULT_RADIUS

## Mesh resources — separate so cada uno tiene su propio radio.
var _regular_sphere_mesh: SphereMesh
var _tl_sphere_mesh: SphereMesh

## Material for the spheres
var _material: StandardMaterial3D

## Camera reference for LOD calculations
var _camera: Camera3D = null


func _ready() -> void:
	_setup_multi_mesh()
	_setup_material()


## Setup the two MultiMeshInstance3D (regular nodes + traffic lights)
func _setup_multi_mesh() -> void:
	# Sphere mesh para nodos normales (radio escalable)
	_regular_sphere_mesh = SphereMesh.new()
	_regular_sphere_mesh.radius = _node_radius
	_regular_sphere_mesh.height = _node_radius * 2.0
	_regular_sphere_mesh.radial_segments = Config.NodeRendering.SPHERE_RADIAL_SEGMENTS
	_regular_sphere_mesh.rings = Config.NodeRendering.SPHERE_RINGS

	_multi_mesh_instance = MultiMeshInstance3D.new()
	_multi_mesh_instance.name = "NodeMultiMesh"
	add_child(_multi_mesh_instance)
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.use_custom_data = false
	multi_mesh.mesh = _regular_sphere_mesh
	_multi_mesh_instance.multimesh = multi_mesh

	# Sphere mesh para semáforos — radio derivado del de nodos regulares
	_tl_sphere_mesh = SphereMesh.new()
	_tl_sphere_mesh.radius = _tl_radius()
	_tl_sphere_mesh.height = _tl_radius() * 2.0
	_tl_sphere_mesh.radial_segments = Config.NodeRendering.TL_SPHERE_SEGMENTS
	_tl_sphere_mesh.rings = Config.NodeRendering.TL_SPHERE_RINGS

	_tl_multi_mesh_instance = MultiMeshInstance3D.new()
	_tl_multi_mesh_instance.name = "TLMultiMesh"
	add_child(_tl_multi_mesh_instance)
	var tl_multi_mesh := MultiMesh.new()
	tl_multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	tl_multi_mesh.use_colors = true
	tl_multi_mesh.use_custom_data = false
	tl_multi_mesh.mesh = _tl_sphere_mesh
	_tl_multi_mesh_instance.multimesh = tl_multi_mesh


## Radio actual de una esfera de semáforo — fracción del radio regular.
func _tl_radius() -> float:
	return _node_radius * Config.NodeRendering.TL_RADIUS_FRACTION


func _setup_material() -> void:
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = Config.NodeRendering.MATERIAL_ROUGHNESS
	_material.metallic = Config.NodeRendering.MATERIAL_METALLIC
	_material.metallic_specular = Config.NodeRendering.METALLIC_SPECULAR
	_material.emission_enabled = true
	_material.emission_energy_multiplier = Config.NodeRendering.EMISSION_ENERGY

	# Aplicar a ambas mallas (son dos recursos distintos ahora)
	if _regular_sphere_mesh:
		_regular_sphere_mesh.surface_set_material(0, _material)
	if _tl_sphere_mesh:
		_tl_sphere_mesh.surface_set_material(0, _material)


func set_converter(converter: CoordinateConverter) -> void:
	_converter = converter


func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Set the node radius. Escala también la malla de semáforos de manera
## proporcional (TL_RADIUS_FRACTION) para que permanezcan visibles a cualquier
## tamaño de mapa pero sigan siendo MÁS PEQUEÑOS que las intersecciones.
func set_node_radius(radius: float) -> void:
	_node_radius = radius
	if _regular_sphere_mesh:
		_regular_sphere_mesh.radius = radius
		_regular_sphere_mesh.height = radius * 2.0
	if _tl_sphere_mesh:
		var tl_r := _tl_radius()
		_tl_sphere_mesh.radius = tl_r
		_tl_sphere_mesh.height = tl_r * 2.0


## Render all nodes from a RoadNetwork — ruta preferida, da acceso a las
## aristas entrantes necesarias para pintar un semáforo por brazo.
func render_network(network: RoadNetwork) -> void:
	if not _converter or not _converter.is_initialized():
		push_error("NodeRenderer: Converter not set or not initialized")
		return

	var nodes_array: Array[NodeData] = []
	for node_id in network.get_node_ids():
		var node := network.get_node(node_id)
		if node:
			nodes_array.append(node)

	_render_nodes_internal(nodes_array, network)


## Render an array of NodeData sin contexto de red — los semáforos se pintan
## en el centro del nodo (una sola instancia). Conservar para compatibilidad.
func render_nodes(nodes: Array[NodeData]) -> void:
	_render_nodes_internal(nodes, null)


func _render_nodes_internal(nodes: Array[NodeData], network: RoadNetwork) -> void:
	if not _converter or not _converter.is_initialized():
		push_error("NodeRenderer: Converter not set or not initialized")
		return

	_clear_internal()

	var regular_nodes: Array[NodeData] = []
	var tl_nodes: Array[NodeData] = []
	for node in nodes:
		if node.node_type == NodeData.NodeType.TRAFFIC_LIGHT:
			tl_nodes.append(node)
		else:
			regular_nodes.append(node)

	_node_count = regular_nodes.size()

	# ── Contar instancias TL necesarias (una por arista entrante; mínimo 1) ───
	var tl_instance_slots: Array = []  # Array of { node, edge_key, position }
	for node in tl_nodes:
		var node_pos := _converter.gps_to_godot(node.longitude, node.latitude)
		var incoming: Array = []
		if network != null:
			incoming = network.get_incoming_edges(node.id)

		if incoming.is_empty():
			# Sin información de aristas → una instancia centrada en el nodo
			tl_instance_slots.append({
				"node": node,
				"edge_key": "*",
				"position": node_pos + Vector3(0.0, _tl_height(), 0.0),
			})
			continue

		for edge in incoming:
			var edge_key := "%d_%d" % [edge.start_node_id, edge.end_node_id]
			var stop_pos := _compute_stop_line_position(node, node_pos, edge)
			tl_instance_slots.append({
				"node": node,
				"edge_key": edge_key,
				"position": stop_pos,
			})

	_tl_count = tl_instance_slots.size()

	var total_count := _node_count + _tl_count
	if total_count == 0:
		render_complete.emit(0)
		return

	# ── Populate regular nodes mesh ────────────────────────────────────────────
	_multi_mesh_instance.multimesh.instance_count = _node_count
	_instance_to_node.resize(_node_count)
	_node_id_to_instance.clear()

	var pos_min := Vector3(INF, INF, INF)
	var pos_max := Vector3(-INF, -INF, -INF)

	for i in range(_node_count):
		var node := regular_nodes[i]
		_instance_to_node[i] = node
		_node_id_to_instance[node.id] = i
		var godot_pos := _converter.gps_to_godot(node.longitude, node.latitude)
		pos_min.x = minf(pos_min.x, godot_pos.x); pos_min.y = minf(pos_min.y, godot_pos.y); pos_min.z = minf(pos_min.z, godot_pos.z)
		pos_max.x = maxf(pos_max.x, godot_pos.x); pos_max.y = maxf(pos_max.y, godot_pos.y); pos_max.z = maxf(pos_max.z, godot_pos.z)
		var t := Transform3D(); t.origin = godot_pos
		_multi_mesh_instance.multimesh.set_instance_transform(i, t)
		_multi_mesh_instance.multimesh.set_instance_color(i, _get_node_color(node.node_type))
		
		

	# ── Populate traffic-light mesh (una instancia por arista) ─────────────────
	_tl_multi_mesh_instance.multimesh.instance_count = _tl_count
	_tl_instance_to_node.resize(_tl_count)
	_tl_instance_to_edge_key.resize(_tl_count)
	_tl_edge_key_to_instance.clear()
	_tl_node_id_to_first_instance.clear()

	for i in range(_tl_count):
		var slot: Dictionary = tl_instance_slots[i]
		var node: NodeData = slot["node"]
		var edge_key: String = slot["edge_key"]
		var godot_pos: Vector3 = slot["position"]

		_tl_instance_to_node[i] = node
		_tl_instance_to_edge_key[i] = edge_key
		_tl_edge_key_to_instance["%d_%s" % [node.id, edge_key]] = i
		if not _tl_node_id_to_first_instance.has(node.id):
			_tl_node_id_to_first_instance[node.id] = i

		pos_min.x = minf(pos_min.x, godot_pos.x); pos_min.y = minf(pos_min.y, godot_pos.y); pos_min.z = minf(pos_min.z, godot_pos.z)
		pos_max.x = maxf(pos_max.x, godot_pos.x); pos_max.y = maxf(pos_max.y, godot_pos.y); pos_max.z = maxf(pos_max.z, godot_pos.z)
		var t := Transform3D(); t.origin = godot_pos
		_tl_multi_mesh_instance.multimesh.set_instance_transform(i, t)
		_tl_multi_mesh_instance.multimesh.set_instance_color(i, Config.TLColors.UNKNOWN)

	if Config.should_log(Config.LogLevel.DEBUG):
		print("[NodeRenderer] Actual node positions - min: %s, max: %s" % [pos_min, pos_max])
		print("[NodeRenderer] Position range: %s" % (pos_max - pos_min))

	if Config.should_log(Config.LogLevel.INFO):
		print("[NodeRenderer] Rendered %d regular nodes + %d TL instances (%d TL nodes)" % [_node_count, _tl_count, tl_nodes.size()])

	render_complete.emit(total_count)


## Calcula la posición de la línea de stop sobre la arista entrante,
## a TL_STOP_LINE_OFFSET_M metros antes del nodo y elevada TL_HEIGHT_M.
func _compute_stop_line_position(_node: NodeData, node_pos: Vector3, edge) -> Vector3:
	# Dirección: desde el punto previo del geometry hacia el nodo. Si no hay
	# geometry, usar el nodo origen de la arista.
	var prev_pos: Vector3 = node_pos
	if edge.geometry is Array and edge.geometry.size() >= 2:
		var prev_point = edge.geometry[edge.geometry.size() - 2]
		var prev_lon: float = 0.0
		var prev_lat: float = 0.0
		if prev_point is Vector2:
			prev_lon = prev_point.x
			prev_lat = prev_point.y
		elif prev_point is Array and prev_point.size() >= 2:
			prev_lon = float(prev_point[0])
			prev_lat = float(prev_point[1])
		elif prev_point is Dictionary:
			prev_lon = float(prev_point.get("lon", prev_point.get("x", 0.0)))
			prev_lat = float(prev_point.get("lat", prev_point.get("y", 0.0)))
		prev_pos = _converter.gps_to_godot(prev_lon, prev_lat)

	var horizontal := Vector3(prev_pos.x - node_pos.x, 0.0, prev_pos.z - node_pos.z)
	if horizontal.length_squared() < 1e-6:
		# Arista degenerada — plantar la esfera en el nodo
		return node_pos + Vector3(0.0, _tl_height(), 0.0)
	var dir := horizontal.normalized()
	var offset := _tl_offset()
	return Vector3(
		node_pos.x + dir.x * offset,
		node_pos.y + _tl_height(),
		node_pos.z + dir.z * offset,
	)


## Offset horizontal del semáforo respecto al centro del nodo (línea de stop).
func _tl_offset() -> float:
	return _node_radius * Config.NodeRendering.TL_OFFSET_FRACTION


## Altura del foco del semáforo sobre la calzada.
func _tl_height() -> float:
	return _node_radius * Config.NodeRendering.TL_HEIGHT_FRACTION


func _get_node_color(node_type: NodeData.NodeType) -> Color:
	match node_type:
		NodeData.NodeType.INTERSECTION:
			return Config.NodeColors.INTERSECTION
		NodeData.NodeType.TRAFFIC_LIGHT:
			return Config.NodeColors.TRAFFIC_LIGHT
		NodeData.NodeType.ROUNDABOUT:
			return Config.NodeColors.ROUNDABOUT
		NodeData.NodeType.STOP_SIGN:
			return Config.NodeColors.STOP_SIGN
		NodeData.NodeType.YIELD_SIGN:
			return Config.NodeColors.YIELD_SIGN
		NodeData.NodeType.DEAD_END:
			return Config.NodeColors.DEAD_END
		NodeData.NodeType.ENTRY_POINT:
			return Config.NodeColors.ENTRY_POINT
		NodeData.NodeType.EXIT_POINT:
			return Config.NodeColors.EXIT_POINT
		_:
			return Config.NodeColors.UNKNOWN


func clear() -> void:
	_clear_internal()
	if Config.should_log(Config.LogLevel.INFO):
		print("[NodeRenderer] Cleared all nodes")


func _clear_internal() -> void:
	_node_count = 0
	_instance_to_node.clear()
	_node_id_to_instance.clear()

	_tl_count = 0
	_tl_instance_to_node.clear()
	_tl_instance_to_edge_key.clear()
	_tl_edge_key_to_instance.clear()
	_tl_node_id_to_first_instance.clear()

	_selected_node = null
	_hovered_node = null

	if _multi_mesh_instance and _multi_mesh_instance.multimesh:
		_multi_mesh_instance.multimesh.instance_count = 0
	if _tl_multi_mesh_instance and _tl_multi_mesh_instance.multimesh:
		_tl_multi_mesh_instance.multimesh.instance_count = 0

	for area in _collision_areas:
		area.queue_free()
	_collision_areas.clear()


## Get node at screen position using raycast
func get_node_at_position(screen_pos: Vector2, camera: Camera3D) -> NodeData:
	if (_node_count + _tl_count) == 0 or not camera:
		return null

	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var ray_end := ray_origin + ray_dir * Config.NodeRendering.RAYCAST_MAX_DISTANCE

	return _raycast_nodes(ray_origin, ray_end)


func _raycast_nodes(ray_origin: Vector3, ray_end: Vector3) -> NodeData:
	var ray_dir := (ray_end - ray_origin).normalized()
	var closest_node: NodeData = null
	var closest_dist: float = INF

	# Regular nodes
	if _multi_mesh_instance.visible:
		for i in range(_node_count):
			var sphere_center := _multi_mesh_instance.multimesh.get_instance_transform(i).origin
			var dist := _ray_sphere_intersection(ray_origin, ray_dir, sphere_center, _node_radius)
			if dist >= 0.0 and dist < closest_dist:
				closest_dist = dist
				closest_node = _instance_to_node[i]

	# Traffic lights — usar el radio escalado
	if _tl_multi_mesh_instance.visible:
		var tl_radius: float = _tl_radius()
		for i in range(_tl_count):
			var sphere_center := _tl_multi_mesh_instance.multimesh.get_instance_transform(i).origin
			var dist := _ray_sphere_intersection(ray_origin, ray_dir, sphere_center, tl_radius)
			if dist >= 0.0 and dist < closest_dist:
				closest_dist = dist
				closest_node = _tl_instance_to_node[i]

	return closest_node


func _ray_sphere_intersection(ray_origin: Vector3, ray_dir: Vector3, sphere_center: Vector3, radius: float) -> float:
	var oc := ray_origin - sphere_center
	var a := ray_dir.dot(ray_dir)
	var b := 2.0 * oc.dot(ray_dir)
	var c := oc.dot(oc) - radius * radius
	var discriminant := b * b - 4.0 * a * c

	if discriminant < 0.0:
		return -1.0

	var t := (-b - sqrt(discriminant)) / (2.0 * a)
	if t < 0.0:
		t = (-b + sqrt(discriminant)) / (2.0 * a)

	return t if t >= 0.0 else -1.0


func select_node(node: NodeData) -> void:
	if _selected_node:
		_clear_highlight(_selected_node)
	_selected_node = node
	if _selected_node:
		_apply_highlight(_selected_node, Config.NodeRendering.SELECTION_HIGHLIGHT_SCALE)
		node_selected.emit(_selected_node)


func deselect() -> void:
	if _selected_node:
		_clear_highlight(_selected_node)
	_selected_node = null


func set_hovered_node(node: NodeData) -> void:
	if node == _hovered_node:
		return
	if _hovered_node and _hovered_node != _selected_node:
		_clear_highlight(_hovered_node)
	_hovered_node = node
	if _hovered_node and _hovered_node != _selected_node:
		_apply_highlight(_hovered_node, Config.NodeRendering.HOVER_HIGHLIGHT_SCALE)
		node_hovered.emit(_hovered_node)
	elif not _hovered_node:
		node_hover_ended.emit()


func clear_hover() -> void:
	set_hovered_node(null)


## Aplica highlight a un nodo (regular o a todas las instancias TL del nodo).
func _apply_highlight(node: NodeData, scale_factor: float) -> void:
	if _is_tl_node(node):
		_scale_all_tl_instances_of_node(node.id, scale_factor)
	elif _node_id_to_instance.has(node.id):
		_scale_instance(_node_id_to_instance[node.id], scale_factor)


func _clear_highlight(node: NodeData) -> void:
	if _is_tl_node(node):
		_scale_all_tl_instances_of_node(node.id, 1.0)
	elif _node_id_to_instance.has(node.id):
		_reset_instance_scale(_node_id_to_instance[node.id])


func _scale_instance(index: int, scale_factor: float) -> void:
	if index < 0 or index >= _node_count:
		return
	var inst_transform := _multi_mesh_instance.multimesh.get_instance_transform(index)
	var origin := inst_transform.origin
	var t := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale_factor), origin)
	_multi_mesh_instance.multimesh.set_instance_transform(index, t)


func _reset_instance_scale(index: int) -> void:
	if index < 0 or index >= _node_count:
		return
	var pos := _multi_mesh_instance.multimesh.get_instance_transform(index).origin
	var t := Transform3D(); t.origin = pos
	_multi_mesh_instance.multimesh.set_instance_transform(index, t)


func _scale_all_tl_instances_of_node(node_id: int, scale_factor: float) -> void:
	for i in range(_tl_count):
		if _tl_instance_to_node[i] != null and _tl_instance_to_node[i].id == node_id:
			var inst_transform := _tl_multi_mesh_instance.multimesh.get_instance_transform(i)
			var origin := inst_transform.origin
			var t := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale_factor), origin)
			_tl_multi_mesh_instance.multimesh.set_instance_transform(i, t)


func _is_tl_node(node: NodeData) -> bool:
	return node != null and _tl_node_id_to_first_instance.has(node.id)


func get_selected_node() -> NodeData:
	return _selected_node


func get_hovered_node() -> NodeData:
	return _hovered_node


func get_node_by_id(node_id: int) -> NodeData:
	if _node_id_to_instance.has(node_id):
		var idx: int = _node_id_to_instance[node_id]
		return _instance_to_node[idx]
	if _tl_node_id_to_first_instance.has(node_id):
		var idx: int = _tl_node_id_to_first_instance[node_id]
		return _tl_instance_to_node[idx]
	return null


func get_node_position(node: NodeData) -> Vector3:
	if _tl_node_id_to_first_instance.has(node.id):
		var idx: int = _tl_node_id_to_first_instance[node.id]
		return _tl_multi_mesh_instance.multimesh.get_instance_transform(idx).origin
	if _node_id_to_instance.has(node.id):
		var idx: int = _node_id_to_instance[node.id]
		return _multi_mesh_instance.multimesh.get_instance_transform(idx).origin
	return Vector3.ZERO


func get_node_count() -> int:
	# Cuenta nodos lógicos, no instancias TL — los semáforos aportan 1 por nodo.
	return _node_count + _tl_node_id_to_first_instance.size()


func has_nodes() -> bool:
	return (_node_count + _tl_count) > 0


func update_lod(camera: Camera3D) -> void:
	if not camera or _node_count == 0:
		return

	var camera_pos := camera.global_position

	for i in range(_node_count):
		var inst_transform := _multi_mesh_instance.multimesh.get_instance_transform(i)
		var node_pos := inst_transform.origin
		var distance := camera_pos.distance_to(node_pos)

		if distance > Config.NodeRendering.LOD_DISTANCE_HIDE:
			inst_transform.basis = Basis.IDENTITY.scaled(Vector3.ZERO)
		elif distance > Config.NodeRendering.LOD_DISTANCE_LOW:
			var scale_factor := Config.NodeRendering.LOD_LOW_SCALE
			inst_transform.basis = Basis.IDENTITY.scaled(Vector3.ONE * scale_factor)
		else:
			inst_transform.basis = Basis.IDENTITY

		_multi_mesh_instance.multimesh.set_instance_transform(i, inst_transform)


func set_nodes_visible(nodes_visible: bool) -> void:
	_multi_mesh_instance.visible = nodes_visible


func set_traffic_lights_visible(tl_visible: bool) -> void:
	_tl_multi_mesh_instance.visible = tl_visible


func are_nodes_visible() -> bool:
	return _multi_mesh_instance.visible


func are_traffic_lights_visible() -> bool:
	return _tl_multi_mesh_instance.visible


func get_node_debug_info(node: NodeData) -> String:
	if not node:
		return ""

	var info := "Node ID: %d\n" % node.id
	info += "Name: %s\n" % (node.name if node.name else "N/A")
	info += "Type: %s\n" % node.get_type_string()
	info += "GPS: [%.6f, %.6f]\n" % [node.longitude, node.latitude]

	var pos := get_node_position(node)
	info += "Godot: [%.2f, %.2f, %.2f]\n" % [pos.x, pos.y, pos.z]
	info += "Active: %s" % ("Yes" if node.is_active else "No")

	return info


func get_stats() -> Dictionary:
	var type_counts := {}
	for node in _instance_to_node:
		var type_name := node.get_type_string()
		type_counts[type_name] = type_counts.get(type_name, 0) + 1
	# Para TLs, contar nodos lógicos (no instancias)
	for node_id in _tl_node_id_to_first_instance:
		var idx: int = _tl_node_id_to_first_instance[node_id]
		var node: NodeData = _tl_instance_to_node[idx]
		if node:
			var type_name := node.get_type_string()
			type_counts[type_name] = type_counts.get(type_name, 0) + 1

	return {
		"total_nodes": _node_count + _tl_node_id_to_first_instance.size(),
		"regular_nodes": _node_count,
		"traffic_lights": _tl_node_id_to_first_instance.size(),
		"tl_instances": _tl_count,
		"type_counts": type_counts,
		"has_selection": _selected_node != null,
		"selected_node_id": _selected_node.id if _selected_node else -1,
	}


## Legacy: actualiza TODAS las instancias del semáforo con la misma fase.
## Se conserva para retro-compatibilidad con el HUD global de override.
## Prefiera `update_traffic_light_state_per_edge` para fases por dirección.
func update_traffic_light_state(node_id: int, phase: String) -> void:
	var color := _phase_to_color(phase)
	for i in range(_tl_count):
		if _tl_instance_to_node[i] != null and _tl_instance_to_node[i].id == node_id:
			_tl_multi_mesh_instance.multimesh.set_instance_color(i, color)


## Actualiza la fase de UN brazo concreto del semáforo (N-S distinto de E-O).
## edge_key viene como "u_v" (start_node_id "_" end_node_id).
## Caso especial "*": el backend no pudo agrupar por eje (TL a mitad de calle)
## → se aplica la misma fase a TODAS las instancias del nodo.
func update_traffic_light_state_per_edge(node_id: int, edge_key: String, phase: String) -> void:
	if edge_key == "*":
		update_traffic_light_state(node_id, phase)
		return
	var lookup := "%d_%s" % [node_id, edge_key]
	if _tl_edge_key_to_instance.has(lookup):
		var idx: int = _tl_edge_key_to_instance[lookup]
		_tl_multi_mesh_instance.multimesh.set_instance_color(idx, _phase_to_color(phase))
		return
	# Edge key desconocido (desajuste backend/cliente): fallback a toda la instancia
	update_traffic_light_state(node_id, phase)


func _phase_to_color(phase: String) -> Color:
	match phase:
		"green":  return Config.TLColors.GREEN
		"yellow": return Config.TLColors.YELLOW
		"red":    return Config.TLColors.RED
		_:        return Config.TLColors.UNKNOWN


func get_rendered_bounds() -> Dictionary:
	if _node_count == 0 and _tl_count == 0:
		return {
			"min": Vector3.ZERO,
			"max": Vector3.ZERO,
			"center": Vector3.ZERO,
			"size": Vector3.ZERO,
		}

	var pos_min := Vector3(INF, INF, INF)
	var pos_max := Vector3(-INF, -INF, -INF)

	for i in range(_node_count):
		var pos := _multi_mesh_instance.multimesh.get_instance_transform(i).origin
		pos_min.x = minf(pos_min.x, pos.x); pos_min.y = minf(pos_min.y, pos.y); pos_min.z = minf(pos_min.z, pos.z)
		pos_max.x = maxf(pos_max.x, pos.x); pos_max.y = maxf(pos_max.y, pos.y); pos_max.z = maxf(pos_max.z, pos.z)

	for i in range(_tl_count):
		var pos := _tl_multi_mesh_instance.multimesh.get_instance_transform(i).origin
		pos_min.x = minf(pos_min.x, pos.x); pos_min.y = minf(pos_min.y, pos.y); pos_min.z = minf(pos_min.z, pos.z)
		pos_max.x = maxf(pos_max.x, pos.x); pos_max.y = maxf(pos_max.y, pos.y); pos_max.z = maxf(pos_max.z, pos.z)

	var center := (pos_min + pos_max) / 2.0
	var size := pos_max - pos_min

	return {
		"min": pos_min,
		"max": pos_max,
		"center": center,
		"size": size,
	}
