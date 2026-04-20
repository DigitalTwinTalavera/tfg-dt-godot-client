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

## Follow vehicle
var _follow_vehicle_id: String = ""
var _follow_height: float = 200.0

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

	_hud = GameHUD.new()
	_hud.set_camera(camera)
	_hud.set_converter(_converter)
	_hud.set_renderers(node_renderer, edge_renderer, _vehicle_renderer)
	add_child(_hud)

	# Vehicle click → HUD right panel
	_vehicle_renderer.vehicle_selected.connect(
		func(vid: String, state: Dictionary) -> void:
			_hud.show_vehicle_info(vid, state)
	)

	# HUD follow signals → camera
	_hud.follow_vehicle_requested.connect(_on_follow_vehicle)
	_hud.unfollow_requested.connect(_on_unfollow)

	# HUD map/config signals → scene handlers
	_hud.reset_camera_requested.connect(_on_reset_camera)
	_hud.reload_map_requested.connect(_on_reload_map)
	_hud.camera_speed_changed.connect(_on_camera_speed_changed)
	_hud.camera_smooth_changed.connect(_on_camera_smooth_changed)


func _connect_signals() -> void:
	node_renderer.render_complete.connect(_on_node_render_complete)
	node_renderer.node_selected.connect(_on_node_selected)
	node_renderer.node_hovered.connect(_on_node_hovered)
	node_renderer.node_hover_ended.connect(_on_node_hover_ended)

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


func _on_camera_smooth_changed(_enabled: bool) -> void:
	pass


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
		print("[TestNetworkRenderer] Network bounds_min: %s" % network.bounds_min)
		print("[TestNetworkRenderer] Network bounds_max: %s" % network.bounds_max)
		print("[TestNetworkRenderer] Nodes: %d, Edges: %d" % [
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
		print("[TestNetworkRenderer] Rendered %d nodes" % node_count)


func _on_edge_render_complete(edge_count: int) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[TestNetworkRenderer] Rendered %d edges" % edge_count)


func _on_node_selected(node: NodeData) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestNetworkRenderer] Selected node: %d (%s)" % [node.id, node.get_type_string()])


func _on_node_hovered(_node: NodeData) -> void:
	pass


func _on_node_hover_ended() -> void:
	pass
