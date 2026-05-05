## EdgeRenderer - Renders road network edges as 3D roads
## Uses ImmediateMesh for efficient rendering of road geometry
## Supports color coding by road type, width by lanes, and one-way arrows
class_name EdgeRenderer
extends Node3D


## Emitted when rendering completes
signal render_complete(edge_count: int)


## Mesh instance for roads
var _road_mesh_instance: MeshInstance3D

## Mesh instance for one-way arrows
var _arrow_mesh_instance: MeshInstance3D

## Mesh instance for incident overlays (rendered above the road mesh).
## Cada tramo con incidente activo se redibuja aquí en el color de su tipo,
## sin tocar la malla principal — así basta un re-draw del overlay (decenas de
## edges como mucho) cuando cambia un incidente, no del road mesh entero.
var _overlay_mesh_instance: MeshInstance3D

## ImmediateMesh for roads
var _road_mesh: ImmediateMesh

## ImmediateMesh for arrows
var _arrow_mesh: ImmediateMesh

## ImmediateMesh for incident overlays
var _overlay_mesh: ImmediateMesh

## Material for roads (vertex colors)
var _road_material: StandardMaterial3D

## Material for arrows
var _arrow_material: StandardMaterial3D

## Material for overlays (vertex colors + alpha)
var _overlay_material: StandardMaterial3D

## Coordinate converter
var _converter: CoordinateConverter

## Camera reference for LOD
var _camera: Camera3D

## Edge data storage
var _edges: Array[EdgeData] = []
var _edge_count: int = 0

## Edge ID to edge mapping
var _edge_id_to_edge: Dictionary = {}  # int -> EdgeData

## (start_node_id, end_node_id) → EdgeData. Lo construimos junto con
## `_edge_id_to_edge` para que la UI pueda resolver una arista por sus
## endpoints (lo que viene en el payload de incidente del backend).
var _edge_by_endpoints: Dictionary = {}  # "u_v" -> EdgeData

## Visibility by road type
var _visible_road_types: Dictionary = {}  # RoadType -> bool

## Selected and hovered edges
var _selected_edge: EdgeData = null
var _hovered_edge: EdgeData = null

## Overlay state — clave: edge_id (int) → Color a pintar encima del tramo.
var _edge_overlays: Dictionary = {}

## Color del hover en modo cierre/reapertura. Si es null no se dibuja.
var _hover_overlay_color: Variant = null

## LOD state
var _lod_enabled: bool = false
var _current_lod_level: int = 0  # 0 = full, 1 = simplified, 2 = hidden


func _ready() -> void:
	_setup_mesh_instances()
	_setup_materials()
	_init_visibility_filters()
	# Localizable desde autoloads (IncidentManager) sin acoplar el path de
	# escena: cualquier que necesite empujar overlays usa
	# `get_tree().get_first_node_in_group("edge_renderer")`.
	add_to_group("edge_renderer")


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

	# Overlay mesh — pintamos los tramos con incidente activo aquí, ligeramente
	# elevados para que aparezcan encima del road mesh sin z-fighting.
	_overlay_mesh = ImmediateMesh.new()
	_overlay_mesh_instance = MeshInstance3D.new()
	_overlay_mesh_instance.mesh = _overlay_mesh
	_overlay_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_overlay_mesh_instance)


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

	# Overlay material — vertex colors con alpha para no ocultar el road por
	# completo. Unshaded para garantizar que el color del tipo de incidente se
	# vea exactamente como está definido en Config.IncidentColors, sin afectarlo
	# por la iluminación de la escena.
	_overlay_material = StandardMaterial3D.new()
	_overlay_material.vertex_color_use_as_albedo = true
	_overlay_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_overlay_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_overlay_mesh_instance.material_override = _overlay_material


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
	_edge_by_endpoints.clear()
	for edge in edges:
		_edge_id_to_edge[edge.id] = edge
		_edge_by_endpoints[_endpoints_key(edge.start_node_id, edge.end_node_id)] = edge

	# Render roads
	_render_roads()

	# Render one-way arrows
	_render_arrows()

	# Si la red se pinta DESPUÉS de que el WS de incidentes haya empujado
	# overlays (caso habitual: snapshot inicial llega antes que los edges),
	# `_clear_internal` habrá borrado nuestro dict — pedimos a IncidentManager
	# que vuelva a empujar la lista. Si no, simplemente repintamos lo que
	# tenemos (vacío, normalmente).
	var im := get_node_or_null("/root/IncidentManager")
	if im and im.has_method("refresh_overlays"):
		im.call_deferred("refresh_overlays")
	else:
		_render_overlays()

	if Config.should_log(Config.LogLevel.INFO):
		print("[EdgeRenderer] Rendered %d edges" % _edge_count)

	render_complete.emit(_edge_count)


static func _endpoints_key(u: int, v: int) -> String:
	return "%d_%d" % [u, v]


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
	# Roundabouts get a slightly desaturated teal so they pop against ordinary
	# asphalt. The extra width reinforces the visual cue — an operator should
	# be able to spot a roundabout from the camera altitude the HUD defaults to.
	if edge.is_roundabout:
		color = color.lerp(
			Config.EdgeRendering.ROUNDABOUT_TINT_COLOR,
			Config.EdgeRendering.ROUNDABOUT_TINT_BLEND,
		)
	var extent := _road_lateral_extent(edge)
	if edge.is_roundabout:
		extent *= Config.EdgeRendering.ROUNDABOUT_WIDTH_MULTIPLIER
	var elevation := Config.EdgeRendering.ROAD_ELEVATION

	var points := _curve_samples(edge, elevation)

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

		# Vértices del quad: derecha = +perp · extent.y; izquierda = -perp · extent.x.
		# Para aristas one-way (extent.x == 0) el lado izquierdo colapsa al
		# centerline, dejando la malla íntegramente a la derecha del heading
		# — alineada con el offset del vehículo (lane + 0.5)·LW a la derecha.
		var v1 := p1 + perpendicular * extent.y
		var v2 := p1 - perpendicular * extent.x
		var v3 := p2 + perpendicular * extent.y
		var v4 := p2 - perpendicular * extent.x

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

	var points := _curve_samples(edge, Config.EdgeRendering.ARROW_HEIGHT)

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


## Muestreo en world-space (Y = elevation) de la geometría de un edge.
## Para aristas con `is_roundabout=True` evaluamos una spline Catmull-Rom
## centrípeta sobre los waypoints en (lon, lat) y luego convertimos a Vector3
## — coincide bit-a-bit con el muestreo que hace el backend en
## network_graph._splinify_roundabout_edges, así la calzada que ve el operador
## y el path por el que el simulador mueve los vehículos son la misma curva.
##
## Para el resto de aristas devolvemos los waypoints tal cual: el polyline
## original ya es lo bastante denso fuera de las rotondas y no queremos
## introducir suavizado donde el OSM pone codos rectos a propósito (p. ej.
## intersecciones en T).
const _CURVE_SAMPLES_PER_SEGMENT: int = 8

func _curve_samples(edge: EdgeData, elevation: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if edge == null or edge.geometry == null:
		return out

	# Convertimos primero los waypoints a world-space (metros) y SÓLO
	# DESPUÉS muestreamos la spline. Razón: Godot 4 usa float32 por defecto;
	# si la Catmull-Rom centrípeta opera sobre Vector2(lon, lat) en grados, las
	# diferencias entre muestras adyacentes (~1e-5°) caen al filo del epsilon
	# de float32 y el algoritmo degenera a quads radiales (pelo de calzada).
	# `gps_to_godot` es prácticamente lineal a escala urbana, así que mover el
	# muestreo a metros preserva la forma de la curva y le da margen numérico.
	if edge.is_roundabout and edge.geometry.size() >= 2:
		var planar := PackedVector2Array()
		for coord in edge.geometry:
			if coord is Array and coord.size() >= 2:
				var w := _converter.gps_to_godot(float(coord[0]), float(coord[1]))
				planar.append(Vector2(w.x, w.z))
		if planar.size() >= 2:
			var sampled := Spline.sample(planar, _CURVE_SAMPLES_PER_SEGMENT)
			out.resize(sampled.size())
			for i in range(sampled.size()):
				var s: Vector2 = sampled[i]
				out[i] = Vector3(s.x, elevation, s.y)
			return out

	for coord in edge.geometry:
		if coord is Array and coord.size() >= 2:
			var godot_pos := _converter.gps_to_godot(float(coord[0]), float(coord[1]))
			godot_pos.y = elevation
			out.append(godot_pos)
	return out


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


## Distancia lateral (m) que la calzada se extiende a cada lado del centerline.
## Devuelve Vector2(left, right). Convención:
##   • Arista one-way → left=0, right=lanes·LW. Toda la malla queda a la
##     derecha del heading, alineada con el offset del vehículo
##     ((lane+0.5)·LW a la derecha).
##   • Arista bidireccional → left=right=lanes·LW. Cubre el rango lateral
##     que pueden ocupar los vehículos en ambos sentidos (el simulador
##     ejecuta MOBIL con `lanes` carriles en cada dirección — ver
##     network_graph._load_edges).
func _road_lateral_extent(edge: EdgeData) -> Vector2:
	var lw := Config.VehicleRendering.LANE_WIDTH_M
	var lanes := maxi(edge.lanes, 1)
	var span := float(lanes) * lw
	if edge.one_way:
		return Vector2(0.0, span)
	return Vector2(span, span)


## Anchura total proyectada (m) — left + right. Para picking/threshold.
func _road_total_width(edge: EdgeData) -> float:
	var extent := _road_lateral_extent(edge)
	return extent.x + extent.y


## Check if edge should be rendered (visibility filter)
func _is_edge_visible(edge: EdgeData) -> bool:
	return _visible_road_types.get(edge.road_type, true)


## ─────────────────────────────────────────────────────────────────────────
## Overlay de tramos restringidos
##
## El "overlay" es una segunda pasada de quads que pintamos por encima del
## road mesh para señalizar tramos con incidente activo. Lo mantenemos en
## una mesh aparte para no tener que re-renderizar la red entera cada vez
## que cambia un incidente — basta con redibujar este overlay (típicamente
## decenas de edges como mucho).
## ─────────────────────────────────────────────────────────────────────────


## Aplica un mapping {edge_id: Color} sobre los tramos a pintar como
## restringidos. Sustituye la tabla anterior por completo. Pasar `{}` para
## limpiar todos los overlays.
func set_edge_overlays(overlays: Dictionary) -> void:
	_edge_overlays = overlays.duplicate()
	_render_overlays()


## Cambia el edge resaltado (hover) durante los modos de cierre/reapertura.
## El color del hover se decide por el caller (cyan claro al cerrar, etc.)
## para que el HUD pueda dar pistas visuales distintas según el modo.
## Pasa `null` o un `Variant` no-Color para limpiar el hover.
func set_hover_edge(edge: EdgeData, hover_color: Variant = null) -> void:
	var changed: bool = edge != _hovered_edge or hover_color != _hover_overlay_color
	_hovered_edge = edge
	_hover_overlay_color = hover_color
	if changed:
		_render_overlays()


func clear_hover() -> void:
	set_hover_edge(null, null)


## Resuelve un edge por (start_node_id, end_node_id). Devuelve null si no
## existe (por ejemplo, una arista del backend cuya geometría no se ha
## cargado todavía, o porque la dirección no coincide).
func get_edge_by_endpoints(u: int, v: int) -> EdgeData:
	return _edge_by_endpoints.get(_endpoints_key(u, v), null)


## Devuelve el edge más cercano al cursor en píxeles, o null. Iteramos
## sobre la geometría real (no sobre quads de la malla, que se descartan
## tras `surface_end()`); proyectamos cada vértice a screen-space y nos
## quedamos con el segmento de menor distancia 2D al cursor.
##
## Threshold por defecto: la mitad del ancho del carril proyectada a píxeles
## (con un mínimo de 8 px). Esto permite "pinchar" tramos finos en zoom
## bajo sin que el cursor tenga que estar exactamente sobre el píxel.
func get_edge_at_position(screen_pos: Vector2, camera: Camera3D) -> EdgeData:
	if _edge_count == 0 or camera == null or _converter == null:
		return null

	var viewport_size: Vector2 = camera.get_viewport().get_visible_rect().size
	var elevation := Config.EdgeRendering.ROAD_ELEVATION
	var best_edge: EdgeData = null
	var best_dist_sq: float = INF

	for edge in _edges:
		if not _is_edge_visible(edge):
			continue
		if edge.geometry.size() < 2:
			continue

		# Threshold proporcional al ancho del tramo (proyectado).
		var width := _road_total_width(edge)
		var threshold_px := _world_width_to_pixels(width, edge, camera, viewport_size)
		# La selección debe estar dentro del propio carril (más un poco).
		# Mínimo 8 px para tramos muy lejanos donde el carril es subpíxel.
		threshold_px = maxf(threshold_px * 0.6, 8.0)
		var threshold_sq := threshold_px * threshold_px

		var prev_screen: Vector2 = Vector2.ZERO
		var prev_valid: bool = false

		# Iterar sobre las muestras de la spline (rotondas) o sobre los
		# waypoints originales — la misma fuente que pintamos en pantalla,
		# para que el cursor "vea" exactamente lo mismo que el operador.
		var samples := _curve_samples(edge, elevation)
		for godot_pos in samples:
			# `is_position_behind` evita matemáticas raras cuando el punto
			# queda detrás de la cámara (proyección no definida).
			if camera.is_position_behind(godot_pos):
				prev_valid = false
				continue
			var screen := camera.unproject_position(godot_pos)
			if prev_valid:
				var dsq := _point_to_segment_distance_sq(screen_pos, prev_screen, screen)
				if dsq < threshold_sq and dsq < best_dist_sq:
					best_dist_sq = dsq
					best_edge = edge
			prev_screen = screen
			prev_valid = true

	return best_edge


## Renderiza el overlay con los edges presentes en `_edge_overlays` + el
## edge en hover (si tiene color asignado).
func _render_overlays() -> void:
	if _overlay_mesh == null:
		return
	_overlay_mesh.clear_surfaces()

	var has_overlays := not _edge_overlays.is_empty()
	var has_hover := _hovered_edge != null and _hover_overlay_color is Color

	if not has_overlays and not has_hover:
		return  # nada que pintar — surface_begin sin contenido tira warning

	_overlay_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for edge_id in _edge_overlays.keys():
		var edge: EdgeData = _edge_id_to_edge.get(edge_id, null)
		if edge == null:
			continue
		if not _is_edge_visible(edge):
			continue
		var color: Color = _edge_overlays[edge_id]
		_render_overlay_quads(edge, color)

	if has_hover:
		# El hover puede coincidir con un overlay activo (p. ej. al pasar
		# sobre un tramo ya cerrado en modo "Reabrir") — lo pintamos igual,
		# encima, para dar feedback de que ese es el tramo apuntado.
		var hover_col: Color = _hover_overlay_color
		_render_overlay_quads(_hovered_edge, hover_col)

	_overlay_mesh.surface_end()


## Pinta los quads de un edge en color uniforme, con un width un 5% mayor
## que el del road para crear un "halo" visible.
func _render_overlay_quads(edge: EdgeData, color: Color) -> void:
	if not edge.has_valid_geometry() or edge.geometry.size() < 2:
		return

	# Halo de 5% sobre el ancho base; rotonda añade 25% extra.
	var extent := _road_lateral_extent(edge) * 1.05
	if edge.is_roundabout:
		extent *= 1.25
	# Pintar 5 cm por encima del road para evitar z-fighting; con material
	# unshaded esto basta y no se nota visualmente como "elevación".
	var elevation := Config.EdgeRendering.ROAD_ELEVATION + 0.05

	var points := _curve_samples(edge, elevation)
	if points.size() < 2:
		return

	for i in range(points.size() - 1):
		var p1 := points[i]
		var p2 := points[i + 1]
		var direction := (p2 - p1).normalized()
		var perpendicular := Vector3(-direction.z, 0, direction.x).normalized()
		var v1 := p1 + perpendicular * extent.y
		var v2 := p1 - perpendicular * extent.x
		var v3 := p2 + perpendicular * extent.y
		var v4 := p2 - perpendicular * extent.x

		_overlay_mesh.surface_set_normal(Vector3.UP)
		_overlay_mesh.surface_set_color(color)
		_overlay_mesh.surface_add_vertex(v1)
		_overlay_mesh.surface_set_normal(Vector3.UP)
		_overlay_mesh.surface_set_color(color)
		_overlay_mesh.surface_add_vertex(v2)
		_overlay_mesh.surface_set_normal(Vector3.UP)
		_overlay_mesh.surface_set_color(color)
		_overlay_mesh.surface_add_vertex(v3)

		_overlay_mesh.surface_set_normal(Vector3.UP)
		_overlay_mesh.surface_set_color(color)
		_overlay_mesh.surface_add_vertex(v2)
		_overlay_mesh.surface_set_normal(Vector3.UP)
		_overlay_mesh.surface_set_color(color)
		_overlay_mesh.surface_add_vertex(v4)
		_overlay_mesh.surface_set_normal(Vector3.UP)
		_overlay_mesh.surface_set_color(color)
		_overlay_mesh.surface_add_vertex(v3)


## Distancia 2D al cuadrado entre un punto y un segmento (a, b).
## La devolvemos al cuadrado para evitar el sqrt en el caller.
static func _point_to_segment_distance_sq(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var ab_len_sq := ab.length_squared()
	if ab_len_sq < 1e-6:
		return p.distance_squared_to(a)
	var t := clampf((p - a).dot(ab) / ab_len_sq, 0.0, 1.0)
	var projected := a + ab * t
	return p.distance_squared_to(projected)


## Aproxima el ancho de un tramo proyectado a píxeles, usando un punto del
## edge como referencia. Es una aproximación — basta para calcular un
## threshold de picking.
func _world_width_to_pixels(world_width: float, edge: EdgeData, camera: Camera3D, _viewport_size: Vector2) -> float:
	# Tomar el primer punto válido como referencia para la proyección.
	for coord in edge.geometry:
		if coord is Array and coord.size() >= 2:
			var center := _converter.gps_to_godot(float(coord[0]), float(coord[1]))
			center.y = Config.EdgeRendering.ROAD_ELEVATION
			if camera.is_position_behind(center):
				continue
			# Construir un offset perpendicular al rayo cámara→punto (en plano).
			var ray := center - camera.global_position
			var horizontal := Vector3(ray.x, 0.0, ray.z)
			if horizontal.length_squared() < 1e-6:
				return 8.0
			var dir := horizontal.normalized()
			var perp := Vector3(-dir.z, 0.0, dir.x)
			var p_a := center + perp * (world_width * 0.5)
			var p_b := center - perp * (world_width * 0.5)
			if camera.is_position_behind(p_a) or camera.is_position_behind(p_b):
				return 8.0
			var sa := camera.unproject_position(p_a)
			var sb := camera.unproject_position(p_b)
			return sa.distance_to(sb)
	return 8.0


## Clear internal data
func _clear_internal() -> void:
	_edges.clear()
	_edge_count = 0
	_edge_id_to_edge.clear()
	_edge_by_endpoints.clear()
	_edge_overlays.clear()
	_selected_edge = null
	_hovered_edge = null
	_hover_overlay_color = null
	_road_mesh.clear_surfaces()
	_arrow_mesh.clear_surfaces()
	if _overlay_mesh:
		_overlay_mesh.clear_surfaces()


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
func set_road_type_visible(road_type: EdgeData.RoadType, visible_flag: bool) -> void:
	_visible_road_types[road_type] = visible_flag


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
			if _overlay_mesh_instance:
				_overlay_mesh_instance.visible = false
		else:
			_road_mesh_instance.visible = true
			_arrow_mesh_instance.visible = true
			if _overlay_mesh_instance:
				_overlay_mesh_instance.visible = true
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
func set_roads_visible(visible_flag: bool) -> void:
	_road_mesh_instance.visible = visible_flag
	_arrow_mesh_instance.visible = visible_flag
	if _overlay_mesh_instance:
		_overlay_mesh_instance.visible = visible_flag


## Toggle only the one-way direction arrows
func set_arrows_visible(visible_flag: bool) -> void:
	_arrow_mesh_instance.visible = visible_flag


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
