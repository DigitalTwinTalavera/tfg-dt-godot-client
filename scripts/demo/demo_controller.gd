## Main 3D visualisation scene.
## Orchestrates NodeRenderer, EdgeRenderer, VehicleRenderer and the unified
## GameHUD (Cities-Skylines-style bottom bar). The map is auto-loaded on
## _ready() so the user never needs to click a "Load" button.
extends Node3D


## 3D references
@onready var camera: Camera3D = $Camera3D
@onready var node_renderer: NodeRenderer = $NodeRenderer
@onready var edge_renderer: EdgeRenderer = $EdgeRenderer

## Simulation UI / rendering — created programmatically in _ready()
var _vehicle_renderer: VehicleRenderer
var _hud: GameHUD
var _incident_renderer: IncidentRenderer
var _zone_renderer: ZoneRenderer
var _route_renderer: RouteRenderer
var _debug_overlay: CanvasLayer

## Estado de modos de operador: creación de incidente (seleccionar arista por
## clicks sucesivos en 2 nodos), dibujo de zona (polígono por clicks), y
## cierre/reapertura rápida de tramos por clic directo sobre la calle (pensado
## para la demo: durante la presentación los nodos están ocultos, así que la
## selección por nodos no es viable y se sustituye por picking de edge).
enum Mode {
	DEFAULT,
	INCIDENT_PICK_START,
	INCIDENT_PICK_END,
	ZONE_DRAWING,
	LANE_CLOSE_PICK,
	LANE_OPEN_PICK,
}
var _mode: int = Mode.DEFAULT
var _incident_first_node: int = -1
var _zone_vertices_world: PackedVector3Array = PackedVector3Array()
var _zone_preview: MeshInstance3D = null

## Follow vehicle
var _follow_vehicle_id: String = ""
var _follow_height: float = 200.0

## Coche cuya ruta se está consultando/pintando. Sirve para descartar
## respuestas HTTP tardías de `_show_route_for_vehicle()` cuando el usuario
## ya seleccionó otro coche o cerró el panel.
var _route_vehicle_id: String = ""

## Camera control
var _camera_speed: float = Config.Camera.KEYBOARD_MOVE_SPEED
var _camera_rotation_speed: float = Config.Camera.ROTATION_SPEED
var _camera_dragging: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO

## Coordinate converter
var _converter: CoordinateConverter

func _ready() -> void:
	_setup_converter()
	_setup_renderer()
	_setup_sim_components()
	_connect_signals()

	# Initial camera position
	camera.position = Vector3(0, 500, 500)
	camera.look_at(Vector3.ZERO)

	# Auto-load the network on entry (deferred so the HUD has had one frame to
	# finish building and connecting to NetworkManager signals).
	call_deferred("_auto_load_network")


func _setup_converter() -> void:
	_converter = CoordinateConverter.new()
	_converter.set_center(
		Config.Coordinates.DEFAULT_CENTER_LON,
		Config.Coordinates.DEFAULT_CENTER_LAT
	)


func _setup_renderer() -> void:
	node_renderer.set_converter(_converter)
	node_renderer.set_camera(camera)
	edge_renderer.set_converter(_converter)
	edge_renderer.set_camera(camera)


func _setup_sim_components() -> void:
	_vehicle_renderer = VehicleRenderer.new()
	add_child(_vehicle_renderer)
	_vehicle_renderer.set_camera(camera)

	# Renderers para incidentes, zonas y ruta seleccionada (Módulo 4)
	_incident_renderer = IncidentRenderer.new()
	add_child(_incident_renderer)
	_zone_renderer = ZoneRenderer.new()
	add_child(_zone_renderer)
	_route_renderer = RouteRenderer.new()
	add_child(_route_renderer)

	_hud = GameHUD.new()
	_hud.set_camera(camera)
	_hud.set_converter(_converter)
	_hud.set_renderers(node_renderer, edge_renderer, _vehicle_renderer)
	add_child(_hud)

	# Debug overlay (F3) — pintado encima del HUD, oculto por defecto.
	_debug_overlay = (load("res://scripts/ui/debug_overlay.gd") as GDScript).new()
	add_child(_debug_overlay)

	# Vehicle click → HUD right panel + dibujar ruta pendiente
	_vehicle_renderer.vehicle_selected.connect(
		func(vid: String, state: Dictionary) -> void:
			_hud.show_vehicle_info(vid, state)
			_show_route_for_vehicle(vid)
	)

	# HUD follow signals → camera
	_hud.follow_vehicle_requested.connect(_on_follow_vehicle)
	_hud.unfollow_requested.connect(_on_unfollow)

	# HUD map/config signals → scene handlers
	_hud.reset_camera_requested.connect(_on_reset_camera)
	_hud.reload_map_requested.connect(_on_reload_map)
	_hud.camera_speed_changed.connect(_on_camera_speed_changed)

	# HUD → modos operador
	_hud.incident_mode_requested.connect(_on_incident_mode_start)
	_hud.zone_draw_mode_requested.connect(_on_zone_draw_mode_start)
	_hud.lane_close_mode_requested.connect(_on_lane_close_mode_start)
	_hud.lane_open_mode_requested.connect(_on_lane_open_mode_start)
	_hud.operator_mode_cancelled.connect(_on_operator_mode_cancel)
	_hud.right_panel_closed.connect(
		func() -> void:
			_route_vehicle_id = ""
			_route_renderer.clear_route()
	)


func _connect_signals() -> void:
	node_renderer.render_complete.connect(_on_node_render_complete)
	node_renderer.node_selected.connect(_on_node_selected)

	# Fase por arista → pinta cada brazo del cruce con su fase independiente.
	# (No conectamos la señal legada `traffic_light_updated` al renderer: sobre-
	# escribiría la fase por arista con un valor uniforme. El HUD sí la usa.)
	TrafficLightManager.traffic_light_edge_updated.connect(
		func(node_id: int, edge_key: String, phase: String) -> void:
			node_renderer.update_traffic_light_state_per_edge(node_id, edge_key, phase)
	)

	# Node selection → HUD right panel (for traffic-light nodes)
	node_renderer.node_selected.connect(
		func(node: NodeData) -> void:
			_hud.show_node_info(node.id, node.get_type_string())
	)

	edge_renderer.render_complete.connect(_on_edge_render_complete)

	NetworkManager.loading_completed.connect(_on_loading_completed)


func _auto_load_network() -> void:
	if NetworkManager.is_loaded:
		_render_network()
	else:
		NetworkManager.load_network()


func _process(delta: float) -> void:
	_handle_camera_movement(delta)
	_follow_tick(delta)


func _follow_tick(_delta: float) -> void:
	if _follow_vehicle_id.is_empty():
		return
	var state := VehicleManager.get_vehicle(_follow_vehicle_id)
	if state.is_empty():
		_follow_vehicle_id = ""
		return
	var world_pos := _converter.gps_to_godot(
		state.get("lon", 0.0), state.get("lat", 0.0)
	)
	var target := world_pos + Vector3(0, _follow_height, 0)
	camera.global_position = camera.global_position.lerp(target, _delta * 5.0)
	camera.look_at(world_pos, Vector3.UP)


func _on_follow_vehicle(vehicle_id: String) -> void:
	_follow_vehicle_id = vehicle_id


func _on_unfollow() -> void:
	_follow_vehicle_id = ""


func _on_reset_camera() -> void:
	camera.position = Vector3(0, Config.Camera.DEFAULT_HEIGHT, Config.Camera.DEFAULT_DISTANCE)
	camera.rotation_degrees = Vector3(Config.Camera.DEFAULT_PITCH, Config.Camera.DEFAULT_YAW, 0)


func _on_reload_map() -> void:
	# Reload always triggers a fresh download — also works as first load.
	edge_renderer.clear()
	node_renderer.clear()
	NetworkManager.load_network()


func _on_camera_speed_changed(speed: float) -> void:
	_camera_speed = speed


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			_camera_dragging = mouse_event.pressed
			_last_mouse_pos = mouse_event.position

		elif mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			if not _follow_vehicle_id.is_empty():
				_follow_vehicle_id = ""
				_hud.unfollow_requested.emit()

			if _hud and _hud.is_reroute_mode():
				var node := node_renderer.get_node_at_position(mouse_event.position, camera)
				if node:
					_hud.set_reroute_target(node.id)
				else:
					_hud.cancel_reroute()
			elif _mode == Mode.INCIDENT_PICK_START or _mode == Mode.INCIDENT_PICK_END:
				_handle_incident_click(mouse_event.position)
			elif _mode == Mode.ZONE_DRAWING:
				_handle_zone_click(mouse_event.position, mouse_event.double_click)
			elif _mode == Mode.LANE_CLOSE_PICK:
				_handle_lane_close_click(mouse_event.position)
			elif _mode == Mode.LANE_OPEN_PICK:
				_handle_lane_open_click(mouse_event.position)
			else:
				_handle_node_click(mouse_event.position)

		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.position += camera.basis.z * -Config.Camera.ZOOM_SPEED
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.position += camera.basis.z * Config.Camera.ZOOM_SPEED

	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _camera_dragging:
			var delta_pos := motion.position - _last_mouse_pos
			_last_mouse_pos = motion.position

			camera.rotate_y(-delta_pos.x * _camera_rotation_speed)
			camera.rotate_object_local(Vector3.RIGHT, -delta_pos.y * _camera_rotation_speed)

		elif _mode == Mode.LANE_CLOSE_PICK or _mode == Mode.LANE_OPEN_PICK:
			# Hover sobre edges con feedback de "preview" (cyan claro). En modo
			# reapertura solo iluminamos tramos que efectivamente están cerrados,
			# para evitar engañar al operador haciéndole creer que cualquier
			# tramo es "reabrible".
			var hovered_edge: EdgeData = edge_renderer.get_edge_at_position(motion.position, camera)
			if _mode == Mode.LANE_OPEN_PICK and hovered_edge != null:
				var inc := IncidentManager.find_active_incident_on_edge(
					hovered_edge.start_node_id, hovered_edge.end_node_id
				)
				if inc.is_empty():
					hovered_edge = null
			edge_renderer.set_hover_edge(hovered_edge, Config.IncidentColors.HOVER_PREVIEW)

		elif node_renderer.has_nodes():
			var hovered := node_renderer.get_node_at_position(motion.position, camera)
			node_renderer.set_hovered_node(hovered)


func _handle_camera_movement(delta: float) -> void:
	var direction := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		direction -= camera.basis.z
	if Input.is_key_pressed(KEY_S):
		direction += camera.basis.z
	if Input.is_key_pressed(KEY_A):
		direction -= camera.basis.x
	if Input.is_key_pressed(KEY_D):
		direction += camera.basis.x
	if Input.is_key_pressed(KEY_Q):
		direction -= Vector3.UP
	if Input.is_key_pressed(KEY_E):
		direction += Vector3.UP

	var speed := _camera_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 3.0

	if direction.length() > 0:
		direction = direction.normalized()
		camera.position += direction * speed * delta


func _handle_node_click(screen_pos: Vector2) -> void:
	var node := node_renderer.get_node_at_position(screen_pos, camera)
	if node:
		node_renderer.select_node(node)
	else:
		node_renderer.deselect()


func _on_loading_completed(network: RoadNetwork) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[Demo] Network bounds_min: %s" % network.bounds_min)
		print("[Demo] Network bounds_max: %s" % network.bounds_max)
		print("[Demo] Nodes: %d, Edges: %d" % [
			network.get_node_count(), network.get_edge_count()
		])

	# Update converter with network bounds and propagate to every renderer
	_converter.set_bounds_from_network(network)
	node_renderer.set_converter(_converter)
	edge_renderer.set_converter(_converter)
	_vehicle_renderer.set_converter(_converter)
	if _hud:
		_hud.set_converter(_converter)
		var net_stats := network.get_stats()
		_hud.update_network_stats(
			network.get_node_count(),
			network.get_edge_count(),
			net_stats.get("total_length_km", 0.0),
		)

	_render_network()

	if _hud:
		_hud.update_render_stats(node_renderer.get_stats(), edge_renderer.get_stats())

	# Módulo 4: conectar renderers a red + converter una vez cargada la red.
	_wire_module4_renderers()


## Render the complete network (nodes and edges). The HUD checkboxes drive
## visibility directly on the renderers, so we always render both and let the
## renderer honour its visibility flag.
func _render_network() -> void:
	if not NetworkManager.is_loaded:
		return

	edge_renderer.render_network(NetworkManager.network)
	node_renderer.render_network(NetworkManager.network)

	_position_camera_for_network()


## Position camera to see the rendered network
func _position_camera_for_network() -> void:
	var bounds: Dictionary
	if edge_renderer.has_edges():
		bounds = edge_renderer.get_rendered_bounds()
	elif node_renderer.has_nodes():
		bounds = node_renderer.get_rendered_bounds()
	else:
		return

	var center: Vector3 = bounds.center
	var size_vec: Vector3 = bounds.size
	var max_size: float = maxf(size_vec.x, size_vec.z)

	# Adjust node radius to network size
	var ideal_radius := maxf(max_size / Config.NodeRendering.RADIUS_SCALE_FACTOR, Config.NodeRendering.DEFAULT_RADIUS)
	ideal_radius = minf(ideal_radius, Config.NodeRendering.MAX_RADIUS)
	node_renderer.set_node_radius(ideal_radius)

	if max_size < Config.Camera.MIN_HEIGHT:
		max_size = Config.Camera.DEFAULT_DISTANCE

	var camera_height := maxf(max_size * 0.5, Config.Camera.MIN_HEIGHT)
	var camera_distance := maxf(max_size * 0.5, Config.Camera.MIN_HEIGHT)
	camera.position = center + Vector3(0, camera_height, camera_distance)

	if camera.position.distance_to(center) > 1.0:
		camera.look_at(center)
	else:
		camera.rotation_degrees = Vector3(Config.Camera.DEFAULT_PITCH, 0, 0)


## Renderer signal handlers
func _on_node_render_complete(node_count: int) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[Demo] Rendered %d nodes" % node_count)


func _on_edge_render_complete(edge_count: int) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[Demo] Rendered %d edges" % edge_count)


func _on_node_selected(node: NodeData) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[Demo] Selected node: %d (%s)" % [node.id, node.get_type_string()])


## ── Renderers de Módulo 4 ────────────────────────────────────────────────

func _wire_module4_renderers() -> void:
	if _converter == null or not NetworkManager.is_loaded:
		return
	var net: RoadNetwork = NetworkManager.network
	var node_lookup := func(id: int) -> Vector2:
		var n: NodeData = net.get_node(id)
		if n == null:
			return Vector2.ZERO
		return Vector2(n.longitude, n.latitude)
	_incident_renderer.setup(_converter, node_lookup)
	_zone_renderer.setup(_converter)
	_route_renderer.setup(_converter, net)


## ── Ruta del vehículo seleccionado ──────────────────────────────────────

func _show_route_for_vehicle(vehicle_id: String) -> void:
	if _route_renderer == null:
		return
	var state: Dictionary = VehicleManager.get_vehicle(vehicle_id)
	if state.is_empty():
		_route_renderer.clear_route()
		return

	# Recordamos qué coche estamos consultando para descartar respuestas
	# tardías si el usuario clica otro coche (o cierra el panel) mientras
	# esperamos la petición HTTP.
	_route_vehicle_id = vehicle_id

	# Pedimos la ruta FRESCA al backend: si el tramo se cerró y el coche se
	# replanificó, `route_edges` ya refleja la ruta nueva (el cache local del
	# spawn no se entera del reroute). Fallback al cache si la red falla.
	var endpoint := "%s/%s" % [Config.SimEndpoints.VEHICLES, vehicle_id]
	var result: HTTPResult = await HTTPManager.get_request(endpoint)

	# El usuario clicó otro coche (o cerró el panel) mientras esperábamos.
	if _route_vehicle_id != vehicle_id:
		return

	var edges: Array = state.get("route_edges", [])  # fallback: cache del spawn
	if result.success and result.data is Dictionary:
		edges = result.data.get("route_edges", edges)
		VehicleManager.update_vehicle_meta(vehicle_id, result.data)

	# `edge_idx` viene del tick vivo (no del GET): refleja en qué arista de la
	# ruta está ahora el coche. Tras un reroute el backend preserva el prefijo
	# recorrido, así que sigue alineado con la ruta nueva.
	var idx: int = int(VehicleManager.get_vehicle(vehicle_id).get("edge_idx", 0))
	_route_renderer.show_route(edges, idx)


## ── Modos de operador: incidentes ───────────────────────────────────────

func _on_incident_mode_start() -> void:
	_mode = Mode.INCIDENT_PICK_START
	_incident_first_node = -1
	_hud.set_mode_hint("Incidente: haz click en el nodo de INICIO de la arista")


func _on_zone_draw_mode_start() -> void:
	_mode = Mode.ZONE_DRAWING
	_zone_vertices_world.clear()
	_refresh_zone_preview()
	_hud.set_mode_hint(
		"Zona: clicks añaden vértices · doble-click o Enter para cerrar · Esc para cancelar"
	)


func _on_operator_mode_cancel() -> void:
	_mode = Mode.DEFAULT
	_incident_first_node = -1
	_zone_vertices_world.clear()
	_refresh_zone_preview()
	if edge_renderer:
		edge_renderer.clear_hover()
	_hud.set_mode_hint("")


## ── Modos de operador: cierre/reapertura rápida de tramos (demo) ────────

func _on_lane_close_mode_start() -> void:
	_mode = Mode.LANE_CLOSE_PICK
	_hud.set_mode_hint("Cerrar tramo: pulsa sobre la calle a cerrar (Esc para cancelar)")


func _on_lane_open_mode_start() -> void:
	_mode = Mode.LANE_OPEN_PICK
	_hud.set_mode_hint("Reabrir tramo: pulsa sobre un tramo cerrado (Esc para cancelar)")


func _handle_lane_close_click(screen_pos: Vector2) -> void:
	var edge: EdgeData = edge_renderer.get_edge_at_position(screen_pos, camera)
	if edge == null:
		_hud.set_mode_hint("Pulsa directamente sobre el tramo de la calle")
		return
	# Si el tramo ya está cerrado, no hacemos nada — evitamos crear duplicados.
	var existing := IncidentManager.find_active_incident_on_edge(edge.start_node_id, edge.end_node_id)
	if not existing.is_empty():
		_hud.set_mode_hint("Ese tramo ya tiene una restricción activa (#%d)" % int(existing.get("id", 0)))
		return
	# Cerrar TODOS los carriles → el backend marcará blocked_edges y replanea
	# las rutas en curso. Tipo "accident" para que el overlay salga en ROJO
	# por defecto (es lo que comunica al operador y al público "no pasar").
	# Para naranja/amarillo/morado, usar el flujo "Restricción avanzada…".
	var lanes_arr: Array = []
	for i in range(edge.lanes):
		lanes_arr.append(i)
	var payload := {
		"type": "accident",
		"edge": [edge.start_node_id, edge.end_node_id],
		"lanes_affected": lanes_arr,
		"duration_s": null,
		"severity": 3,
		"description": "Cierre manual desde HUD",
	}
	# Salimos del modo antes de la espera HTTP para que un segundo clic no
	# dispare otra petición mientras la primera está en vuelo.
	_mode = Mode.DEFAULT
	edge_renderer.clear_hover()
	_hud.set_mode_hint("Cerrando tramo %d → %d…" % [edge.start_node_id, edge.end_node_id])
	var result: HTTPResult = await HTTPManager.post_request("/incidents", payload)
	if result.success:
		_hud.set_mode_hint("Tramo %d → %d cerrado" % [edge.start_node_id, edge.end_node_id])
	else:
		_hud.set_mode_hint("No se pudo cerrar el tramo (HTTP %d)" % result.status_code)


func _handle_lane_open_click(screen_pos: Vector2) -> void:
	var edge: EdgeData = edge_renderer.get_edge_at_position(screen_pos, camera)
	if edge == null:
		_hud.set_mode_hint("Pulsa directamente sobre un tramo cerrado")
		return
	var inc := IncidentManager.find_active_incident_on_edge(edge.start_node_id, edge.end_node_id)
	if inc.is_empty():
		_hud.set_mode_hint("Ese tramo no tiene ninguna restricción activa")
		return
	var iid := int(inc.get("id", 0))
	_mode = Mode.DEFAULT
	edge_renderer.clear_hover()
	_hud.set_mode_hint("Reabriendo tramo (incidente #%d)…" % iid)
	var result: HTTPResult = await HTTPManager.delete_request("/incidents/%d" % iid)
	if result.success:
		_hud.set_mode_hint("Tramo reabierto")
	else:
		_hud.set_mode_hint("No se pudo reabrir (HTTP %d)" % result.status_code)


func _handle_incident_click(screen_pos: Vector2) -> void:
	var node := node_renderer.get_node_at_position(screen_pos, camera)
	if node == null:
		_hud.set_mode_hint("Haz click sobre un nodo del mapa (no un espacio vacío)")
		return
	if _mode == Mode.INCIDENT_PICK_START:
		_incident_first_node = node.id
		_mode = Mode.INCIDENT_PICK_END
		_hud.set_mode_hint(
			"Inicio %d · ahora click en el nodo de FIN (sentido de la arista)" % node.id
		)
		return
	# INCIDENT_PICK_END
	if node.id == _incident_first_node:
		_hud.set_mode_hint("No se puede elegir el mismo nodo como fin")
		return
	var u := _incident_first_node
	var v := node.id
	_mode = Mode.DEFAULT
	_incident_first_node = -1
	_hud.open_incident_dialog(u, v)


## ── Modos de operador: zona (polígono) ──────────────────────────────────

func _handle_zone_click(screen_pos: Vector2, is_double: bool) -> void:
	# Convertir el screen_pos a punto en el suelo (Y=0).
	var world := _screen_to_ground(screen_pos)
	if world == Vector3.INF:
		return
	if is_double and _zone_vertices_world.size() >= 3:
		_finish_zone_drawing()
		return
	_zone_vertices_world.append(world)
	_refresh_zone_preview()
	_hud.set_mode_hint(
		"Zona: %d vértices · doble-click o Enter para cerrar" % _zone_vertices_world.size()
	)


func _screen_to_ground(screen_pos: Vector2) -> Vector3:
	if camera == null:
		return Vector3.INF
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if abs(dir.y) < 0.0001:
		return Vector3.INF
	var t := -origin.y / dir.y
	if t <= 0.0:
		return Vector3.INF
	return origin + dir * t


func _refresh_zone_preview() -> void:
	if _zone_preview != null:
		_zone_preview.queue_free()
		_zone_preview = null
	if _zone_vertices_world.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in _zone_vertices_world:
		st.add_vertex(Vector3(p.x, 1.0, p.z))
	if _zone_vertices_world.size() >= 3:
		st.add_vertex(Vector3(_zone_vertices_world[0].x, 1.0, _zone_vertices_world[0].z))
	var mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.85, 0.30, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.20, 0.85, 0.30)
	mat.emission_energy_multiplier = 0.7
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)
	_zone_preview = mi


func _finish_zone_drawing() -> void:
	# Convertir vértices Vector3 a lon/lat vía CoordinateConverter.
	var coords: Array = []
	for p in _zone_vertices_world:
		var gps: Vector2 = _converter.godot_to_gps(p)
		coords.append([gps.x, gps.y])
	_mode = Mode.DEFAULT
	_zone_vertices_world.clear()
	_refresh_zone_preview()
	_hud.set_mode_hint("")
	if coords.size() < 3:
		return
	_hud.open_zone_dialog(coords)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			if _mode != Mode.DEFAULT:
				_on_operator_mode_cancel()
			elif _hud != null and _hud.is_reroute_mode():
				_hud.cancel_reroute()
		elif key.keycode == KEY_ENTER and _mode == Mode.ZONE_DRAWING:
			_finish_zone_drawing()
		elif key.keycode == KEY_F3 and _debug_overlay != null:
			_debug_overlay.visible = not _debug_overlay.visible
