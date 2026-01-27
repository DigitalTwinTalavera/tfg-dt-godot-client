## Node Renderer using MultiMeshInstance3D for efficient rendering
## Renders road network nodes as 3D spheres with color coding by type
##
## Performance: Uses MultiMesh to render 5000+ nodes in a single draw call
## Features:
##   - Per-instance colors based on node type
##   - LOD system for distant nodes
##   - Node selection via raycast
##   - Hover detection for debug info
class_name NodeRenderer
extends Node3D


## Emitted when a node is selected
signal node_selected(node_data: NodeData)

## Emitted when a node is hovered
signal node_hovered(node_data: NodeData)

## Emitted when hover ends
signal node_hover_ended()

## Emitted when rendering is complete
signal render_complete(node_count: int)


## The MultiMeshInstance3D for rendering all nodes
var _multi_mesh_instance: MultiMeshInstance3D

## Reference to the coordinate converter
var _converter: CoordinateConverter

## Mapping from instance index to NodeData
var _instance_to_node: Array[NodeData] = []

## Mapping from node ID to instance index
var _node_id_to_instance: Dictionary = {}  # int -> int

## Current number of rendered nodes
var _node_count: int = 0

## Currently selected node
var _selected_node: NodeData = null

## Currently hovered node
var _hovered_node: NodeData = null

## Collision detection area (for raycast)
var _collision_areas: Array[Area3D] = []

## Sphere radius for rendering
var _node_radius: float = Config.NodeRendering.DEFAULT_RADIUS

## Material for the spheres
var _material: StandardMaterial3D

## Camera reference for LOD calculations
var _camera: Camera3D = null


func _ready() -> void:
	_setup_multi_mesh()
	_setup_material()


## Setup the MultiMeshInstance3D with a sphere mesh
func _setup_multi_mesh() -> void:
	_multi_mesh_instance = MultiMeshInstance3D.new()
	_multi_mesh_instance.name = "NodeMultiMesh"
	add_child(_multi_mesh_instance)

	# Create the MultiMesh resource
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.use_custom_data = false

	# Create low-poly sphere mesh
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = _node_radius
	sphere_mesh.height = _node_radius * 2.0
	sphere_mesh.radial_segments = Config.NodeRendering.SPHERE_RADIAL_SEGMENTS
	sphere_mesh.rings = Config.NodeRendering.SPHERE_RINGS

	multi_mesh.mesh = sphere_mesh
	_multi_mesh_instance.multimesh = multi_mesh


## Setup material with proper lighting
func _setup_material() -> void:
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.7
	_material.metallic = 0.1
	_material.metallic_specular = 0.3

	# Enable some emission for visibility
	_material.emission_enabled = true
	_material.emission_energy_multiplier = 0.1

	# Apply to mesh
	if _multi_mesh_instance and _multi_mesh_instance.multimesh and _multi_mesh_instance.multimesh.mesh:
		_multi_mesh_instance.multimesh.mesh.surface_set_material(0, _material)


## Set the coordinate converter
func set_converter(converter: CoordinateConverter) -> void:
	_converter = converter


## Set the camera reference for LOD calculations
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Set the node radius
func set_node_radius(radius: float) -> void:
	_node_radius = radius
	if _multi_mesh_instance and _multi_mesh_instance.multimesh:
		var sphere_mesh := _multi_mesh_instance.multimesh.mesh as SphereMesh
		if sphere_mesh:
			sphere_mesh.radius = radius
			sphere_mesh.height = radius * 2.0


## Render all nodes from a RoadNetwork
func render_network(network: RoadNetwork) -> void:
	if not _converter or not _converter.is_initialized():
		push_error("NodeRenderer: Converter not set or not initialized")
		return

	var nodes_array: Array[NodeData] = []
	for node_id in network.get_node_ids():
		var node := network.get_node(node_id)
		if node:
			nodes_array.append(node)

	render_nodes(nodes_array)


## Render an array of NodeData
func render_nodes(nodes: Array[NodeData]) -> void:
	if not _converter or not _converter.is_initialized():
		push_error("NodeRenderer: Converter not set or not initialized")
		return

	_clear_internal()

	_node_count = nodes.size()
	if _node_count == 0:
		render_complete.emit(0)
		return

	# Resize the MultiMesh
	_multi_mesh_instance.multimesh.instance_count = _node_count

	# Resize arrays
	_instance_to_node.resize(_node_count)
	_node_id_to_instance.clear()

	# Track position bounds for debugging
	var pos_min := Vector3(INF, INF, INF)
	var pos_max := Vector3(-INF, -INF, -INF)

	# Populate instances
	for i in range(_node_count):
		var node := nodes[i]
		_instance_to_node[i] = node
		_node_id_to_instance[node.id] = i

		# Calculate Godot position
		var godot_pos := _converter.gps_to_godot(node.longitude, node.latitude)

		# Track bounds
		pos_min.x = minf(pos_min.x, godot_pos.x)
		pos_min.y = minf(pos_min.y, godot_pos.y)
		pos_min.z = minf(pos_min.z, godot_pos.z)
		pos_max.x = maxf(pos_max.x, godot_pos.x)
		pos_max.y = maxf(pos_max.y, godot_pos.y)
		pos_max.z = maxf(pos_max.z, godot_pos.z)

		# Create transform
		var inst_transform := Transform3D()
		inst_transform.origin = godot_pos

		# Set instance transform
		_multi_mesh_instance.multimesh.set_instance_transform(i, inst_transform)

		# Set instance color based on node type
		var color := _get_node_color(node.node_type)
		_multi_mesh_instance.multimesh.set_instance_color(i, color)

	if Config.should_log(Config.LogLevel.DEBUG):
		print("[NodeRenderer] Actual node positions - min: %s, max: %s" % [pos_min, pos_max])
		print("[NodeRenderer] Position range: %s" % (pos_max - pos_min))

	if Config.should_log(Config.LogLevel.INFO):
		print("[NodeRenderer] Rendered %d nodes" % _node_count)

	render_complete.emit(_node_count)


## Get color for a node type
func _get_node_color(node_type: NodeData.NodeType) -> Color:
	match node_type:
		NodeData.NodeType.INTERSECTION:
			return Config.NodeColors.INTERSECTION
		NodeData.NodeType.TRAFFIC_LIGHT:
			return Config.NodeColors.TRAFFIC_LIGHT
		NodeData.NodeType.ROUNDABOUT:
			return Config.NodeColors.ROUNDABOUT
		NodeData.NodeType.DEAD_END:
			return Config.NodeColors.DEAD_END
		NodeData.NodeType.ENTRY_POINT:
			return Config.NodeColors.ENTRY_POINT
		NodeData.NodeType.EXIT_POINT:
			return Config.NodeColors.EXIT_POINT
		_:
			return Config.NodeColors.UNKNOWN


## Clear all rendered nodes
func clear() -> void:
	_clear_internal()
	if Config.should_log(Config.LogLevel.INFO):
		print("[NodeRenderer] Cleared all nodes")


func _clear_internal() -> void:
	_node_count = 0
	_instance_to_node.clear()
	_node_id_to_instance.clear()
	_selected_node = null
	_hovered_node = null

	if _multi_mesh_instance and _multi_mesh_instance.multimesh:
		_multi_mesh_instance.multimesh.instance_count = 0

	# Clear collision areas if any
	for area in _collision_areas:
		area.queue_free()
	_collision_areas.clear()


## Get node at screen position using raycast
## Returns null if no node found
func get_node_at_position(screen_pos: Vector2, camera: Camera3D) -> NodeData:
	if _node_count == 0 or not camera:
		return null

	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var ray_end := ray_origin + ray_dir * 10000.0

	return _raycast_nodes(ray_origin, ray_end)


## Perform raycast against all node positions
## Uses sphere intersection for efficiency
func _raycast_nodes(ray_origin: Vector3, ray_end: Vector3) -> NodeData:
	var ray_dir := (ray_end - ray_origin).normalized()
	var closest_node: NodeData = null
	var closest_dist: float = INF

	for i in range(_node_count):
		var inst_transform := _multi_mesh_instance.multimesh.get_instance_transform(i)
		var sphere_center := inst_transform.origin

		# Ray-sphere intersection
		var dist := _ray_sphere_intersection(ray_origin, ray_dir, sphere_center, _node_radius)
		if dist >= 0.0 and dist < closest_dist:
			closest_dist = dist
			closest_node = _instance_to_node[i]

	return closest_node


## Ray-sphere intersection test
## Returns distance to intersection, or -1 if no intersection
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


## Select a node by its data
func select_node(node: NodeData) -> void:
	# Deselect previous
	if _selected_node and _node_id_to_instance.has(_selected_node.id):
		var prev_idx: int = _node_id_to_instance[_selected_node.id]
		_reset_instance_scale(prev_idx)

	_selected_node = node

	# Highlight new selection
	if _selected_node and _node_id_to_instance.has(_selected_node.id):
		var idx: int = _node_id_to_instance[_selected_node.id]
		_scale_instance(idx, Config.NodeRendering.SELECTION_HIGHLIGHT_SCALE)
		node_selected.emit(_selected_node)


## Deselect current node
func deselect() -> void:
	if _selected_node and _node_id_to_instance.has(_selected_node.id):
		var idx: int = _node_id_to_instance[_selected_node.id]
		_reset_instance_scale(idx)

	_selected_node = null


## Set hovered node (for debug info)
func set_hovered_node(node: NodeData) -> void:
	if node == _hovered_node:
		return

	# Reset previous hover
	if _hovered_node and _hovered_node != _selected_node:
		if _node_id_to_instance.has(_hovered_node.id):
			var prev_idx: int = _node_id_to_instance[_hovered_node.id]
			_reset_instance_scale(prev_idx)

	_hovered_node = node

	# Highlight new hover (if not already selected)
	if _hovered_node and _hovered_node != _selected_node:
		if _node_id_to_instance.has(_hovered_node.id):
			var idx: int = _node_id_to_instance[_hovered_node.id]
			_scale_instance(idx, Config.NodeRendering.HOVER_HIGHLIGHT_SCALE)
		node_hovered.emit(_hovered_node)
	elif not _hovered_node:
		node_hover_ended.emit()


## Clear hover state
func clear_hover() -> void:
	set_hovered_node(null)


## Scale an instance for highlighting
func _scale_instance(index: int, scale_factor: float) -> void:
	if index < 0 or index >= _node_count:
		return

	var inst_transform := _multi_mesh_instance.multimesh.get_instance_transform(index)
	inst_transform.basis = inst_transform.basis.scaled(Vector3.ONE * scale_factor)
	_multi_mesh_instance.multimesh.set_instance_transform(index, inst_transform)


## Reset instance scale to default
func _reset_instance_scale(index: int) -> void:
	if index < 0 or index >= _node_count:
		return

	var inst_transform := _multi_mesh_instance.multimesh.get_instance_transform(index)
	# Reset to identity rotation/scale, keep position
	var pos := inst_transform.origin
	inst_transform = Transform3D()
	inst_transform.origin = pos
	_multi_mesh_instance.multimesh.set_instance_transform(index, inst_transform)


## Get the currently selected node
func get_selected_node() -> NodeData:
	return _selected_node


## Get the currently hovered node
func get_hovered_node() -> NodeData:
	return _hovered_node


## Get node by ID
func get_node_by_id(node_id: int) -> NodeData:
	if _node_id_to_instance.has(node_id):
		var idx: int = _node_id_to_instance[node_id]
		return _instance_to_node[idx]
	return null


## Get Godot position for a node
func get_node_position(node: NodeData) -> Vector3:
	if not _node_id_to_instance.has(node.id):
		return Vector3.ZERO

	var idx: int = _node_id_to_instance[node.id]
	return _multi_mesh_instance.multimesh.get_instance_transform(idx).origin


## Get total rendered node count
func get_node_count() -> int:
	return _node_count


## Check if any nodes are rendered
func has_nodes() -> bool:
	return _node_count > 0


## Update LOD based on camera distance
## Call this from _process if LOD is needed
func update_lod(camera: Camera3D) -> void:
	if not camera or _node_count == 0:
		return

	var camera_pos := camera.global_position

	for i in range(_node_count):
		var inst_transform := _multi_mesh_instance.multimesh.get_instance_transform(i)
		var node_pos := inst_transform.origin
		var distance := camera_pos.distance_to(node_pos)

		# Hide nodes beyond LOD distance
		if distance > Config.NodeRendering.LOD_DISTANCE_HIDE:
			# Scale to 0 to "hide"
			inst_transform.basis = Basis.IDENTITY.scaled(Vector3.ZERO)
		elif distance > Config.NodeRendering.LOD_DISTANCE_LOW:
			# Reduce scale for distant nodes
			var scale_factor := 0.5
			inst_transform.basis = Basis.IDENTITY.scaled(Vector3.ONE * scale_factor)
		else:
			# Full scale for close nodes
			inst_transform.basis = Basis.IDENTITY

		_multi_mesh_instance.multimesh.set_instance_transform(i, inst_transform)


## Set visibility of all nodes
func set_nodes_visible(nodes_visible: bool) -> void:
	_multi_mesh_instance.visible = nodes_visible


## Get visibility state
func are_nodes_visible() -> bool:
	return _multi_mesh_instance.visible


## Get debug info string for a node
func get_node_debug_info(node: NodeData) -> String:
	if not node:
		return ""

	var info := "Node ID: %d\n" % node.id
	info += "Name: %s\n" % (node.name if node.name else "N/A")
	info += "Type: %s\n" % node.get_type_string()
	info += "GPS: [%.6f, %.6f]\n" % [node.longitude, node.latitude]

	if _node_id_to_instance.has(node.id):
		var idx: int = _node_id_to_instance[node.id]
		var pos := _multi_mesh_instance.multimesh.get_instance_transform(idx).origin
		info += "Godot: [%.2f, %.2f, %.2f]\n" % [pos.x, pos.y, pos.z]

	info += "Active: %s" % ("Yes" if node.is_active else "No")

	return info


## Get statistics about rendered nodes
func get_stats() -> Dictionary:
	var type_counts := {}

	for node in _instance_to_node:
		var type_name := node.get_type_string()
		type_counts[type_name] = type_counts.get(type_name, 0) + 1

	return {
		"total_nodes": _node_count,
		"type_counts": type_counts,
		"has_selection": _selected_node != null,
		"selected_node_id": _selected_node.id if _selected_node else -1
	}


## Get the bounding box of all rendered nodes
## Returns Dictionary with min, max, center, size as Vector3
func get_rendered_bounds() -> Dictionary:
	if _node_count == 0:
		return {
			"min": Vector3.ZERO,
			"max": Vector3.ZERO,
			"center": Vector3.ZERO,
			"size": Vector3.ZERO
		}

	var pos_min := Vector3(INF, INF, INF)
	var pos_max := Vector3(-INF, -INF, -INF)

	for i in range(_node_count):
		var pos := _multi_mesh_instance.multimesh.get_instance_transform(i).origin
		pos_min.x = minf(pos_min.x, pos.x)
		pos_min.y = minf(pos_min.y, pos.y)
		pos_min.z = minf(pos_min.z, pos.z)
		pos_max.x = maxf(pos_max.x, pos.x)
		pos_max.y = maxf(pos_max.y, pos.y)
		pos_max.z = maxf(pos_max.z, pos.z)

	var center := (pos_min + pos_max) / 2.0
	var size := pos_max - pos_min

	return {
		"min": pos_min,
		"max": pos_max,
		"center": center,
		"size": size
	}
