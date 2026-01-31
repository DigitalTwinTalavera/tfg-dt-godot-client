## EdgeRenderer - Renders road network edges as 3D roads
## Uses ImmediateMesh for efficient rendering of road geometry
## Supports color coding by road type, width by lanes, and one-way arrows
class_name EdgeRenderer
extends Node3D


## Emitted when edge is selected
signal edge_selected(edge_data: EdgeData)

## Emitted when edge is hovered
signal edge_hovered(edge_data: EdgeData)

## Emitted when hover ends
signal edge_hover_ended()

## Emitted when rendering completes
signal render_complete(edge_count: int)


## Mesh instance for roads
var _road_mesh_instance: MeshInstance3D

## Mesh instance for one-way arrows
var _arrow_mesh_instance: MeshInstance3D

## ImmediateMesh for roads
var _road_mesh: ImmediateMesh

## ImmediateMesh for arrows
var _arrow_mesh: ImmediateMesh

## Material for roads (vertex colors)
var _road_material: StandardMaterial3D

## Material for arrows
var _arrow_material: StandardMaterial3D

## Coordinate converter
var _converter: CoordinateConverter

## Camera reference for LOD
var _camera: Camera3D

## Edge data storage
var _edges: Array[EdgeData] = []
var _edge_count: int = 0

## Edge ID to edge mapping
var _edge_id_to_edge: Dictionary = {}  # int -> EdgeData

## Visibility by road type
var _visible_road_types: Dictionary = {}  # RoadType -> bool

## Selected and hovered edges
var _selected_edge: EdgeData = null
var _hovered_edge: EdgeData = null

## LOD state
var _lod_enabled: bool = false
var _current_lod_level: int = 0  # 0 = full, 1 = simplified, 2 = hidden


func _ready() -> void:
	_setup_mesh_instances()
	_setup_materials()
	_init_visibility_filters()


func _setup_mesh_instances() -> void:
	# Road mesh
	_road_mesh = ImmediateMesh.new()
	_road_mesh_instance = MeshInstance3D.new()
	_road_mesh_instance.mesh = _road_mesh
	_road_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_road_mesh_instance)

	# Arrow mesh
	_arrow_mesh = ImmediateMesh.new()
	_arrow_mesh_instance = MeshInstance3D.new()
	_arrow_mesh_instance.mesh = _arrow_mesh
	_arrow_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arrow_mesh_instance)


func _setup_materials() -> void:
	# Road material with vertex colors
	_road_material = StandardMaterial3D.new()
	_road_material.vertex_color_use_as_albedo = true
	_road_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_road_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_road_mesh_instance.material_override = _road_material

	# Arrow material
	_arrow_material = StandardMaterial3D.new()
	_arrow_material.albedo_color = Config.EdgeRendering.ARROW_COLOR
	_arrow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_arrow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_arrow_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_arrow_mesh_instance.material_override = _arrow_material


func _init_visibility_filters() -> void:
	# Initialize all road types as visible
	for road_type in EdgeData.RoadType.values():
		_visible_road_types[road_type] = true


## Set the coordinate converter
func set_converter(converter: CoordinateConverter) -> void:
	_converter = converter


## Set the camera reference for LOD
func set_camera(camera: Camera3D) -> void:
	_camera = camera


## Render all edges from a RoadNetwork
func render_network(network: RoadNetwork) -> void:
	if not _converter or not _converter.is_initialized():
		push_error("EdgeRenderer: Converter not set or not initialized")
		return

	var edges_array: Array[EdgeData] = []
	for edge_id in network.get_edge_ids():
		var edge := network.get_edge(edge_id)
		if edge:
			edges_array.append(edge)

	render_edges(edges_array)


## Render an array of EdgeData
func render_edges(edges: Array[EdgeData]) -> void:
	if not _converter or not _converter.is_initialized():
		push_error("EdgeRenderer: Converter not set or not initialized")
		return

	_clear_internal()

	_edges = edges
	_edge_count = edges.size()

	if _edge_count == 0:
		render_complete.emit(0)
		return

	# Build edge ID mapping
	_edge_id_to_edge.clear()
	for edge in edges:
		_edge_id_to_edge[edge.id] = edge

	# Render roads
	_render_roads()

	# Render one-way arrows
	_render_arrows()

	if Config.should_log(Config.LogLevel.INFO):
		print("[EdgeRenderer] Rendered %d edges" % _edge_count)

	render_complete.emit(_edge_count)


## Render road geometry
func _render_roads() -> void:
	_road_mesh.clear_surfaces()
	_road_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for edge in _edges:
		if not _is_edge_visible(edge):
			continue

		_render_single_road(edge)

	_road_mesh.surface_end()


## Render a single road edge
func _render_single_road(edge: EdgeData) -> void:
	if not edge.has_valid_geometry() or edge.geometry.size() < 2:
		return

	var color := _get_road_color(edge.road_type)
	var width := _get_road_width(edge.lanes)
	var half_width := width / 2.0
	var elevation := Config.EdgeRendering.ROAD_ELEVATION

	# Convert geometry to Godot positions
	var points: Array[Vector3] = []
	for coord in edge.geometry:
		if coord is Array and coord.size() >= 2:
			var godot_pos := _converter.gps_to_godot(float(coord[0]), float(coord[1]))
			godot_pos.y = elevation
			points.append(godot_pos)

	if points.size() < 2:
		return

	# Simplify geometry if needed for LOD
	if _lod_enabled and _current_lod_level > 0:
		points = _simplify_geometry(points)

	# Generate road quads
	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]

		# Calculate perpendicular direction for road width
		var direction := (p2 - p1).normalized()
		var perpendicular := Vector3(-direction.z, 0, direction.x).normalized()

		# Create quad vertices
		var v1 := p1 + perpendicular * half_width
		var v2 := p1 - perpendicular * half_width
		var v3 := p2 + perpendicular * half_width
		var v4 := p2 - perpendicular * half_width

		# Triangle 1: v1, v2, v3
		_road_mesh.surface_set_normal(Vector3.UP)
		_road_mesh.surface_set_color(color)
		_road_mesh.surface_add_vertex(v1)
		_road_mesh.surface_set_normal(Vector3.UP)
		_road_mesh.surface_set_color(color)
		_road_mesh.surface_add_vertex(v2)
		_road_mesh.surface_set_normal(Vector3.UP)
		_road_mesh.surface_set_color(color)
		_road_mesh.surface_add_vertex(v3)

		# Triangle 2: v2, v4, v3
		_road_mesh.surface_set_normal(Vector3.UP)
		_road_mesh.surface_set_color(color)
		_road_mesh.surface_add_vertex(v2)
		_road_mesh.surface_set_normal(Vector3.UP)
		_road_mesh.surface_set_color(color)
		_road_mesh.surface_add_vertex(v4)
		_road_mesh.surface_set_normal(Vector3.UP)
		_road_mesh.surface_set_color(color)
		_road_mesh.surface_add_vertex(v3)


## Render one-way arrows
func _render_arrows() -> void:
	_arrow_mesh.clear_surfaces()
	_arrow_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for edge in _edges:
		if not _is_edge_visible(edge):
			continue
		if not edge.one_way:
			continue

		_render_edge_arrows(edge)

	_arrow_mesh.surface_end()


## Render arrows for a single one-way edge
func _render_edge_arrows(edge: EdgeData) -> void:
	if not edge.has_valid_geometry() or edge.geometry.size() < 2:
		return

	# Convert geometry to Godot positions
	var points: Array[Vector3] = []
	for coord in edge.geometry:
		if coord is Array and coord.size() >= 2:
			var godot_pos := _converter.gps_to_godot(float(coord[0]), float(coord[1]))
			godot_pos.y = Config.EdgeRendering.ARROW_HEIGHT
			points.append(godot_pos)

	if points.size() < 2:
		return

	# Calculate total length and place arrows at intervals
	var total_length := 0.0
	for i in range(points.size() - 1):
		total_length += points[i].distance_to(points[i + 1])

	var arrow_spacing := Config.EdgeRendering.ARROW_SPACING
	var num_arrows := int(total_length / arrow_spacing)
	if num_arrows < 1:
		num_arrows = 1

	# Place arrows along the path
	var accumulated_length := 0.0
	var arrow_index := 0
	var next_arrow_distance := arrow_spacing / 2.0  # Start at half spacing

	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]
		var segment_length := p1.distance_to(p2)
		var segment_dir := (p2 - p1).normalized()

		while next_arrow_distance < accumulated_length + segment_length:
			if arrow_index >= num_arrows:
				break

			var t := (next_arrow_distance - accumulated_length) / segment_length
			var arrow_pos := p1.lerp(p2, t)
			_draw_arrow(arrow_pos, segment_dir)

			arrow_index += 1
			next_arrow_distance += arrow_spacing

		accumulated_length += segment_length


## Draw a single arrow at position pointing in direction
func _draw_arrow(arrow_position: Vector3, direction: Vector3) -> void:
	var arrow_size := Config.EdgeRendering.ARROW_SIZE
	var half_size := arrow_size / 2.0

	# Calculate perpendicular for arrow width
	var perpendicular := Vector3(-direction.z, 0, direction.x).normalized()

	# Arrow vertices (triangle pointing in direction)
	var tip := arrow_position + direction * half_size
	var base_left := arrow_position - direction * half_size + perpendicular * half_size * 0.5
	var base_right := arrow_position - direction * half_size - perpendicular * half_size * 0.5

	# Add triangle with normals
	_arrow_mesh.surface_set_normal(Vector3.UP)
	_arrow_mesh.surface_add_vertex(tip)
	_arrow_mesh.surface_set_normal(Vector3.UP)
	_arrow_mesh.surface_add_vertex(base_left)
	_arrow_mesh.surface_set_normal(Vector3.UP)
	_arrow_mesh.surface_add_vertex(base_right)


## Simplify geometry for LOD
func _simplify_geometry(points: Array[Vector3]) -> Array[Vector3]:
	if points.size() <= 2:
		return points

	var min_length := Config.EdgeRendering.LOD_MIN_SEGMENT_LENGTH
	var simplified: Array[Vector3] = [points[0]]

	var accumulated_length := 0.0
	for i in range(1, points.size() - 1):
		accumulated_length += points[i - 1].distance_to(points[i])
		if accumulated_length >= min_length:
			simplified.append(points[i])
			accumulated_length = 0.0

	simplified.append(points[points.size() - 1])
	return simplified


## Get road color based on type
func _get_road_color(road_type: EdgeData.RoadType) -> Color:
	match road_type:
		EdgeData.RoadType.MOTORWAY:
			return Config.RoadColors.MOTORWAY
		EdgeData.RoadType.MOTORWAY_LINK:
			return Config.RoadColors.MOTORWAY_LINK
		EdgeData.RoadType.TRUNK:
			return Config.RoadColors.TRUNK
		EdgeData.RoadType.TRUNK_LINK:
			return Config.RoadColors.TRUNK_LINK
		EdgeData.RoadType.PRIMARY:
			return Config.RoadColors.PRIMARY
		EdgeData.RoadType.PRIMARY_LINK:
			return Config.RoadColors.PRIMARY_LINK
		EdgeData.RoadType.SECONDARY:
			return Config.RoadColors.SECONDARY
		EdgeData.RoadType.SECONDARY_LINK:
			return Config.RoadColors.SECONDARY_LINK
		EdgeData.RoadType.TERTIARY:
			return Config.RoadColors.TERTIARY
		EdgeData.RoadType.TERTIARY_LINK:
			return Config.RoadColors.TERTIARY_LINK
		EdgeData.RoadType.RESIDENTIAL:
			return Config.RoadColors.RESIDENTIAL
		EdgeData.RoadType.SERVICE:
			return Config.RoadColors.SERVICE
		EdgeData.RoadType.UNCLASSIFIED:
			return Config.RoadColors.UNCLASSIFIED
		EdgeData.RoadType.LIVING_STREET:
			return Config.RoadColors.LIVING_STREET
		_:
			return Config.RoadColors.UNKNOWN


## Get road width based on lane count
func _get_road_width(lanes: int) -> float:
	if lanes <= 1:
		return Config.EdgeRendering.WIDTH_1_LANE
	elif lanes == 2:
		return Config.EdgeRendering.WIDTH_2_LANES
	elif lanes == 3:
		return Config.EdgeRendering.WIDTH_3_LANES
	else:
		return Config.EdgeRendering.WIDTH_4_LANES


## Check if edge should be rendered (visibility filter)
func _is_edge_visible(edge: EdgeData) -> bool:
	return _visible_road_types.get(edge.road_type, true)


## Clear internal data
func _clear_internal() -> void:
	_edges.clear()
	_edge_count = 0
	_edge_id_to_edge.clear()
	_selected_edge = null
	_hovered_edge = null
	_road_mesh.clear_surfaces()
	_arrow_mesh.clear_surfaces()


## Clear all rendered edges
func clear() -> void:
	_clear_internal()


## Check if renderer has edges
func has_edges() -> bool:
	return _edge_count > 0


## Get edge count
func get_edge_count() -> int:
	return _edge_count


## Get edge by ID
func get_edge_by_id(edge_id: int) -> EdgeData:
	return _edge_id_to_edge.get(edge_id, null)


## Set visibility for a road type
func set_road_type_visible(road_type: EdgeData.RoadType, is_visible: bool) -> void:
	_visible_road_types[road_type] = is_visible


## Check if road type is visible
func is_road_type_visible(road_type: EdgeData.RoadType) -> bool:
	return _visible_road_types.get(road_type, true)


## Toggle visibility for a road type
func toggle_road_type(road_type: EdgeData.RoadType) -> void:
	_visible_road_types[road_type] = not _visible_road_types.get(road_type, true)


## Re-render with current visibility settings
func refresh() -> void:
	if _edges.size() > 0:
		var edges_copy := _edges.duplicate()
		render_edges(edges_copy)


## Update LOD based on camera distance
func update_lod(camera: Camera3D) -> void:
	if not camera or _edge_count == 0:
		return

	# Calculate distance to center of rendered edges
	var bounds := get_rendered_bounds()
	var bounds_center: Vector3 = bounds.center
	var distance := camera.global_position.distance_to(bounds_center)

	var new_lod_level := 0
	if distance > Config.EdgeRendering.LOD_DISTANCE_HIDE:
		new_lod_level = 2  # Hidden
	elif distance > Config.EdgeRendering.LOD_DISTANCE_SIMPLIFY:
		new_lod_level = 1  # Simplified

	if new_lod_level != _current_lod_level:
		_current_lod_level = new_lod_level

		if new_lod_level == 2:
			_road_mesh_instance.visible = false
			_arrow_mesh_instance.visible = false
		else:
			_road_mesh_instance.visible = true
			_arrow_mesh_instance.visible = true
			# Re-render with new LOD level
			_lod_enabled = new_lod_level > 0
			refresh()


## Enable/disable LOD
func set_lod_enabled(enabled: bool) -> void:
	_lod_enabled = enabled
	if not enabled:
		_current_lod_level = 0
		refresh()


## Get rendered bounds
func get_rendered_bounds() -> Dictionary:
	if _edge_count == 0:
		return {
			"min": Vector3.ZERO,
			"max": Vector3.ZERO,
			"center": Vector3.ZERO,
			"size": Vector3.ZERO
		}

	var pos_min := Vector3(INF, INF, INF)
	var pos_max := Vector3(-INF, -INF, -INF)

	for edge in _edges:
		for coord in edge.geometry:
			if coord is Array and coord.size() >= 2:
				var pos := _converter.gps_to_godot(float(coord[0]), float(coord[1]))
				pos_min.x = minf(pos_min.x, pos.x)
				pos_min.z = minf(pos_min.z, pos.z)
				pos_max.x = maxf(pos_max.x, pos.x)
				pos_max.z = maxf(pos_max.z, pos.z)

	pos_min.y = 0
	pos_max.y = 0

	var center := (pos_min + pos_max) / 2.0
	var size := pos_max - pos_min

	return {
		"min": pos_min,
		"max": pos_max,
		"center": center,
		"size": size
	}


## Set visibility of all roads
func set_roads_visible(is_visible: bool) -> void:
	_road_mesh_instance.visible = is_visible
	_arrow_mesh_instance.visible = is_visible


## Check if roads are visible
func are_roads_visible() -> bool:
	return _road_mesh_instance.visible


## Get statistics about rendered edges
func get_stats() -> Dictionary:
	var type_counts := {}
	var one_way_count := 0
	var total_length := 0.0

	for edge in _edges:
		var road_type_name: String = EdgeData.RoadType.keys()[edge.road_type]
		type_counts[road_type_name] = type_counts.get(road_type_name, 0) + 1
		if edge.one_way:
			one_way_count += 1
		total_length += edge.length

	return {
		"total_edges": _edge_count,
		"type_counts": type_counts,
		"one_way_count": one_way_count,
		"total_length_meters": total_length,
		"total_length_km": total_length / 1000.0,
		"has_selection": _selected_edge != null
	}


## Get debug info for an edge
func get_edge_debug_info(edge: EdgeData) -> String:
	if not edge:
		return ""

	var info := "Edge ID: %d\n" % edge.id
	info += "Name: %s\n" % (edge.name if edge.name else "N/A")
	info += "Type: %s\n" % EdgeData.RoadType.keys()[edge.road_type]
	info += "Lanes: %d\n" % edge.lanes
	info += "One-way: %s\n" % ("Yes" if edge.one_way else "No")
	info += "Length: %.1f m\n" % edge.length
	info += "Max speed: %d km/h\n" % edge.max_speed
	info += "Points: %d\n" % edge.geometry.size()

	return info
