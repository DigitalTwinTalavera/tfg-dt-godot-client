## Test scene for NodeRenderer
## Visualizes road network nodes in 3D with interaction
extends Node3D


## UI References
@onready var ui_panel: PanelContainer = $UI/PanelContainer
@onready var stats_label: Label = $UI/PanelContainer/VBoxContainer/StatsLabel
@onready var node_info_label: RichTextLabel = $UI/PanelContainer/VBoxContainer/NodeInfoLabel
@onready var fps_label: Label = $UI/FPSLabel
@onready var load_button: Button = $UI/PanelContainer/VBoxContainer/LoadButton
@onready var clear_button: Button = $UI/PanelContainer/VBoxContainer/ClearButton
@onready var back_button: Button = $UI/PanelContainer/VBoxContainer/BackButton
@onready var lod_check: CheckBox = $UI/PanelContainer/VBoxContainer/LODCheck

## 3D References
@onready var camera: Camera3D = $Camera3D
@onready var node_renderer: NodeRenderer = $NodeRenderer
@onready var environment_light: DirectionalLight3D = $DirectionalLight3D

## Camera control
var _camera_speed: float = 100.0
var _camera_rotation_speed: float = 0.003
var _camera_dragging: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO

## Coordinate converter
var _converter: CoordinateConverter

## LOD enabled
var _lod_enabled: bool = false

## Performance tracking
var _frame_times: Array[float] = []
var _max_frame_samples: int = 60


func _ready() -> void:
	_setup_converter()
	_setup_renderer()
	_connect_signals()
	_update_stats()

	# Set initial camera position
	camera.position = Vector3(0, 500, 500)
	camera.look_at(Vector3.ZERO)


func _setup_converter() -> void:
	_converter = CoordinateConverter.new()
	_converter.set_center(
		Config.Coordinates.DEFAULT_CENTER_LON,
		Config.Coordinates.DEFAULT_CENTER_LAT
	)


func _setup_renderer() -> void:
	node_renderer.set_converter(_converter)
	node_renderer.set_camera(camera)


func _connect_signals() -> void:
	load_button.pressed.connect(_on_load_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	back_button.pressed.connect(_on_back_pressed)
	lod_check.toggled.connect(_on_lod_toggled)

	node_renderer.render_complete.connect(_on_render_complete)
	node_renderer.node_selected.connect(_on_node_selected)
	node_renderer.node_hovered.connect(_on_node_hovered)
	node_renderer.node_hover_ended.connect(_on_node_hover_ended)

	NetworkManager.loading_started.connect(_on_loading_started)
	NetworkManager.loading_progress.connect(_on_loading_progress)
	NetworkManager.loading_completed.connect(_on_loading_completed)
	NetworkManager.loading_failed.connect(_on_loading_failed)


func _process(delta: float) -> void:
	_handle_camera_movement(delta)
	_update_fps(delta)

	# Update LOD if enabled
	if _lod_enabled and node_renderer.has_nodes():
		node_renderer.update_lod(camera)


func _input(event: InputEvent) -> void:
	# Camera rotation with right mouse button
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
			_camera_dragging = mouse_event.pressed
			_last_mouse_pos = mouse_event.position

		# Node selection with left click
		elif mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			_handle_node_click(mouse_event.position)

		# Camera zoom with scroll
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.position += camera.basis.z * -50.0
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.position += camera.basis.z * 50.0

	# Camera rotation
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _camera_dragging:
			var delta_pos := motion.position - _last_mouse_pos
			_last_mouse_pos = motion.position

			camera.rotate_y(-delta_pos.x * _camera_rotation_speed)
			camera.rotate_object_local(Vector3.RIGHT, -delta_pos.y * _camera_rotation_speed)

		# Node hover detection
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

	# Speed boost with Shift
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
		_clear_node_info()


func _update_fps(delta: float) -> void:
	_frame_times.append(delta)
	if _frame_times.size() > _max_frame_samples:
		_frame_times.pop_front()

	var avg_delta := 0.0
	for t in _frame_times:
		avg_delta += t
	avg_delta /= _frame_times.size()

	var fps := 1.0 / avg_delta if avg_delta > 0 else 0.0
	fps_label.text = "FPS: %.1f" % fps


func _update_stats() -> void:
	var stats := node_renderer.get_stats()
	var text := "Nodes: %d\n" % stats.total_nodes

	if stats.type_counts.size() > 0:
		text += "\nBy Type:\n"
		for type_name in stats.type_counts:
			text += "  %s: %d\n" % [type_name, stats.type_counts[type_name]]

	stats_label.text = text


func _update_node_info(node: NodeData) -> void:
	var info := node_renderer.get_node_debug_info(node)
	node_info_label.text = "[b]Selected Node[/b]\n" + info


func _clear_node_info() -> void:
	node_info_label.text = "Click on a node to see info"


## Button handlers
func _on_load_pressed() -> void:
	load_button.disabled = true

	if NetworkManager.is_loaded:
		# Already loaded, just render
		_render_nodes()
	else:
		# Load from backend
		stats_label.text = "Loading network..."
		await NetworkManager.load_network()


func _on_clear_pressed() -> void:
	node_renderer.clear()
	_update_stats()
	_clear_node_info()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_lod_toggled(enabled: bool) -> void:
	_lod_enabled = enabled
	if not enabled and node_renderer.has_nodes():
		# Re-render without LOD to restore full scale
		_render_nodes()


## Network loading handlers
func _on_loading_started() -> void:
	stats_label.text = "Loading network from backend..."


func _on_loading_progress(progress: float, message: String) -> void:
	stats_label.text = "Loading: %.0f%%\n%s" % [progress * 100, message]


func _on_loading_completed(network: RoadNetwork) -> void:
	stats_label.text = "Network loaded! Rendering..."

	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestNodeRenderer] Network bounds_min: %s" % network.bounds_min)
		print("[TestNodeRenderer] Network bounds_max: %s" % network.bounds_max)
		print("[TestNodeRenderer] Network center: %s" % network.get_center())

	# Update converter with network bounds
	_converter.set_bounds_from_network(network)
	node_renderer.set_converter(_converter)

	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestNodeRenderer] Converter: %s" % _converter)
		print("[TestNodeRenderer] Converter bounds size (meters): %s" % _converter.get_bounds_size_meters())

	# Render nodes
	_render_nodes()

	load_button.disabled = false


func _on_loading_failed(error: String) -> void:
	stats_label.text = "Load failed: %s" % error
	load_button.disabled = false


## Render the network nodes
func _render_nodes() -> void:
	if not NetworkManager.is_loaded:
		return

	node_renderer.render_network(NetworkManager.network)

	# Calculate camera position based on actual rendered nodes
	_position_camera_for_nodes()


## Position camera to see all rendered nodes
func _position_camera_for_nodes() -> void:
	if not node_renderer.has_nodes():
		return

	# Get bounds from rendered nodes
	var bounds := node_renderer.get_rendered_bounds()
	var center: Vector3 = bounds.center
	var size_vec: Vector3 = bounds.size
	var max_size: float = maxf(size_vec.x, size_vec.z)

	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestNodeRenderer] Rendered bounds - min: %s, max: %s" % [bounds.min, bounds.max])
		print("[TestNodeRenderer] Center: %s" % center)
		print("[TestNodeRenderer] Size: %s, max_size: %.2f" % [size_vec, max_size])

	# Adjust node radius based on network size for visibility
	# Target: ~200-500 nodes visible at once, each node should be ~0.5-1% of view
	var ideal_radius := maxf(max_size / 500.0, Config.NodeRendering.DEFAULT_RADIUS)
	ideal_radius = minf(ideal_radius, 50.0)  # Cap at 50 meters max
	node_renderer.set_node_radius(ideal_radius)
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestNodeRenderer] Adjusted node radius to: %.2f meters" % ideal_radius)

	# Ensure minimum camera distance
	if max_size < 100.0:
		max_size = 1000.0  # Default view distance

	# Position camera above and looking at center
	var camera_height := maxf(max_size * 0.5, 100.0)
	var camera_distance := maxf(max_size * 0.5, 100.0)
	var camera_offset := Vector3(0, camera_height, camera_distance)
	camera.position = center + camera_offset

	# Point camera at center
	if camera.position.distance_to(center) > 1.0:
		camera.look_at(center)
	else:
		camera.rotation_degrees = Vector3(-45, 0, 0)

	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestNodeRenderer] Camera position: %s" % camera.position)


## Renderer signal handlers
func _on_render_complete(node_count: int) -> void:
	_update_stats()
	if Config.should_log(Config.LogLevel.INFO):
		print("[TestNodeRenderer] Rendered %d nodes" % node_count)


func _on_node_selected(node: NodeData) -> void:
	_update_node_info(node)
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestNodeRenderer] Selected node: %d (%s)" % [node.id, node.get_type_string()])


func _on_node_hovered(_node: NodeData) -> void:
	# Update cursor or show tooltip
	pass


func _on_node_hover_ended() -> void:
	pass
