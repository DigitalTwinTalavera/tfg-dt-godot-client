## Debug panel UI overlay for network statistics and controls
## Displays real-time info and provides toggles for visual elements
class_name DebugPanel
extends CanvasLayer


## Emitted when visibility toggles change
signal nodes_visibility_changed(visible: bool)
signal edges_visibility_changed(visible: bool)
signal arrows_visibility_changed(visible: bool)

## Emitted when action buttons are pressed
signal reload_requested()
signal reset_camera_requested()


## References to UI elements (set via scene or code)
var _stats_label: RichTextLabel
var _camera_label: Label
var _fps_label: Label
var _nodes_toggle: CheckBox
var _edges_toggle: CheckBox
var _arrows_toggle: CheckBox
var _reload_button: Button
var _reset_camera_button: Button
var _panel: PanelContainer

## External references (set by parent scene)
var camera_controller: CameraController
var node_renderer: NodeRenderer
var edge_renderer: EdgeRenderer

## Stats cache
var _node_count: int = 0
var _edge_count: int = 0
var _total_road_length_km: float = 0.0
var _camera_position: Vector3 = Vector3.ZERO
var _camera_distance: float = 0.0

## FPS tracking
var _frame_times: Array[float] = []
var _fps_update_timer: float = 0.0
var _current_fps: float = 0.0


func _ready() -> void:
	_setup_ui()
	_connect_signals()
	_update_stats_display()


func _process(delta: float) -> void:
	_update_fps(delta)
	_update_camera_info()


## Build the UI programmatically
func _setup_ui() -> void:
	# Create main panel container
	_panel = PanelContainer.new()
	_panel.name = "DebugPanel"

	# Style the panel
	var style := StyleBoxFlat.new()
	style.bg_color = Config.UI.BACKGROUND_COLOR
	style.corner_radius_top_left = Config.UI.PANEL_CORNER_RADIUS
	style.corner_radius_top_right = Config.UI.PANEL_CORNER_RADIUS
	style.corner_radius_bottom_left = Config.UI.PANEL_CORNER_RADIUS
	style.corner_radius_bottom_right = Config.UI.PANEL_CORNER_RADIUS
	style.content_margin_left = Config.UI.PANEL_CONTENT_MARGIN
	style.content_margin_right = Config.UI.PANEL_CONTENT_MARGIN
	style.content_margin_top = Config.UI.PANEL_VERTICAL_MARGIN
	style.content_margin_bottom = Config.UI.PANEL_VERTICAL_MARGIN
	_panel.add_theme_stylebox_override("panel", style)

	# Position panel
	_panel.anchors_preset = Control.PRESET_TOP_LEFT
	_panel.position = Vector2(Config.UI.PANEL_MARGIN, Config.UI.PANEL_MARGIN)
	_panel.custom_minimum_size = Vector2(Config.UI.PANEL_MIN_WIDTH, 0)

	# Main vertical container
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", Config.UI.PANEL_ITEM_SPACING)
	_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "Debug Panel"
	title.add_theme_color_override("font_color", Config.UI.ACCENT_COLOR)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Separator
	vbox.add_child(_create_separator())

	# Stats section
	var stats_title := Label.new()
	stats_title.text = "Network Stats"
	stats_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	vbox.add_child(stats_title)

	_stats_label = RichTextLabel.new()
	_stats_label.bbcode_enabled = true
	_stats_label.fit_content = true
	_stats_label.scroll_active = false
	_stats_label.custom_minimum_size = Vector2(0, 60)
	vbox.add_child(_stats_label)

	# Separator
	vbox.add_child(_create_separator())

	# Camera section
	var camera_title := Label.new()
	camera_title.text = "Camera"
	camera_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	vbox.add_child(camera_title)

	_camera_label = Label.new()
	_camera_label.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	vbox.add_child(_camera_label)

	# FPS
	_fps_label = Label.new()
	_fps_label.add_theme_color_override("font_color", Config.UI.SUCCESS_COLOR)
	vbox.add_child(_fps_label)

	# Separator
	vbox.add_child(_create_separator())

	# Visibility toggles section
	var toggles_title := Label.new()
	toggles_title.text = "Visibility"
	toggles_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	vbox.add_child(toggles_title)

	_nodes_toggle = _create_checkbox("Show Nodes", true)
	vbox.add_child(_nodes_toggle)

	_edges_toggle = _create_checkbox("Show Roads", true)
	vbox.add_child(_edges_toggle)

	_arrows_toggle = _create_checkbox("Show Arrows", true)
	vbox.add_child(_arrows_toggle)

	# Separator
	vbox.add_child(_create_separator())

	# Action buttons
	var buttons_title := Label.new()
	buttons_title.text = "Actions"
	buttons_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	vbox.add_child(buttons_title)

	_reload_button = _create_button("Reload Network")
	vbox.add_child(_reload_button)

	_reset_camera_button = _create_button("Reset Camera")
	vbox.add_child(_reset_camera_button)

	# Add panel to canvas layer
	add_child(_panel)


func _create_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", Config.UI.SEPARATOR_COLOR)
	return sep


func _create_checkbox(text: String, checked: bool) -> CheckBox:
	var checkbox := CheckBox.new()
	checkbox.text = text
	checkbox.button_pressed = checked
	checkbox.add_theme_color_override("font_color", Config.UI.TEXT_MUTED_COLOR)
	checkbox.add_theme_color_override("font_pressed_color", Config.UI.TEXT_COLOR)
	return checkbox


func _create_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, Config.UI.BUTTON_HEIGHT)

	var style_normal := StyleBoxFlat.new()
	style_normal.bg_color = Config.UI.BUTTON_NORMAL_COLOR
	style_normal.corner_radius_top_left = Config.UI.BUTTON_CORNER_RADIUS
	style_normal.corner_radius_top_right = Config.UI.BUTTON_CORNER_RADIUS
	style_normal.corner_radius_bottom_left = Config.UI.BUTTON_CORNER_RADIUS
	style_normal.corner_radius_bottom_right = Config.UI.BUTTON_CORNER_RADIUS
	button.add_theme_stylebox_override("normal", style_normal)

	var style_hover := StyleBoxFlat.new()
	style_hover.bg_color = Config.UI.BUTTON_HOVER_COLOR
	style_hover.corner_radius_top_left = Config.UI.BUTTON_CORNER_RADIUS
	style_hover.corner_radius_top_right = Config.UI.BUTTON_CORNER_RADIUS
	style_hover.corner_radius_bottom_left = Config.UI.BUTTON_CORNER_RADIUS
	style_hover.corner_radius_bottom_right = Config.UI.BUTTON_CORNER_RADIUS
	button.add_theme_stylebox_override("hover", style_hover)

	var style_pressed := StyleBoxFlat.new()
	style_pressed.bg_color = Config.UI.BUTTON_PRESSED_COLOR
	style_pressed.corner_radius_top_left = Config.UI.BUTTON_CORNER_RADIUS
	style_pressed.corner_radius_top_right = Config.UI.BUTTON_CORNER_RADIUS
	style_pressed.corner_radius_bottom_left = Config.UI.BUTTON_CORNER_RADIUS
	style_pressed.corner_radius_bottom_right = Config.UI.BUTTON_CORNER_RADIUS
	button.add_theme_stylebox_override("pressed", style_pressed)

	return button


func _connect_signals() -> void:
	_nodes_toggle.toggled.connect(_on_nodes_toggled)
	_edges_toggle.toggled.connect(_on_edges_toggled)
	_arrows_toggle.toggled.connect(_on_arrows_toggled)
	_reload_button.pressed.connect(_on_reload_pressed)
	_reset_camera_button.pressed.connect(_on_reset_camera_pressed)


## Update FPS counter
func _update_fps(delta: float) -> void:
	_frame_times.append(delta)
	if _frame_times.size() > Config.UI.FPS_SAMPLE_COUNT:
		_frame_times.pop_front()

	_fps_update_timer += delta
	if _fps_update_timer >= Config.UI.FPS_UPDATE_INTERVAL:
		_fps_update_timer = 0.0

		var avg_delta := 0.0
		for t in _frame_times:
			avg_delta += t
		avg_delta /= _frame_times.size()

		_current_fps = 1.0 / avg_delta if avg_delta > 0 else 0.0
		_update_fps_display()


## Update camera info display
func _update_camera_info() -> void:
	if camera_controller:
		_camera_position = camera_controller.get_focal_point()
		_camera_distance = camera_controller.get_distance()
	elif get_viewport().get_camera_3d():
		var cam := get_viewport().get_camera_3d()
		_camera_position = cam.global_position
		_camera_distance = _camera_position.length()

	_camera_label.text = "Pos: (%.0f, %.0f, %.0f)\nDist: %.0f m" % [
		_camera_position.x, _camera_position.y, _camera_position.z,
		_camera_distance
	]


## Update FPS display with color coding
func _update_fps_display() -> void:
	var color := Config.UI.SUCCESS_COLOR
	if _current_fps < 30:
		color = Config.UI.ERROR_COLOR
	elif _current_fps < 50:
		color = Config.UI.WARNING_COLOR

	_fps_label.text = "FPS: %.0f" % _current_fps
	_fps_label.add_theme_color_override("font_color", color)


## Update network statistics display
func _update_stats_display() -> void:
	var text := "[color=#%s]Nodes:[/color] %d\n" % [Config.UI.TEXT_COLOR.to_html(false), _node_count]
	text += "[color=#%s]Edges:[/color] %d\n" % [Config.UI.TEXT_COLOR.to_html(false), _edge_count]
	text += "[color=#%s]Length:[/color] %.1f km" % [Config.UI.TEXT_COLOR.to_html(false), _total_road_length_km]
	_stats_label.text = text


## Set network statistics
func set_network_stats(nodes: int, edges: int, length_km: float) -> void:
	_node_count = nodes
	_edge_count = edges
	_total_road_length_km = length_km
	_update_stats_display()


## Update stats from renderers
func update_from_renderers() -> void:
	if node_renderer:
		var stats := node_renderer.get_stats()
		_node_count = stats.get("total_nodes", 0)

	if edge_renderer:
		var stats := edge_renderer.get_stats()
		_edge_count = stats.get("total_edges", 0)
		_total_road_length_km = stats.get("total_length_km", 0.0)

	_update_stats_display()


## Set toggle states
func set_nodes_visible(visible: bool) -> void:
	_nodes_toggle.button_pressed = visible


func set_edges_visible(visible: bool) -> void:
	_edges_toggle.button_pressed = visible


func set_arrows_visible(visible: bool) -> void:
	_arrows_toggle.button_pressed = visible


## Get toggle states
func are_nodes_visible() -> bool:
	return _nodes_toggle.button_pressed


func are_edges_visible() -> bool:
	return _edges_toggle.button_pressed


func are_arrows_visible() -> bool:
	return _arrows_toggle.button_pressed


## Show/hide the panel
func set_panel_visible(visible: bool) -> void:
	_panel.visible = visible


func is_panel_visible() -> bool:
	return _panel.visible


func toggle_panel() -> void:
	_panel.visible = not _panel.visible


## Signal handlers
func _on_nodes_toggled(pressed: bool) -> void:
	nodes_visibility_changed.emit(pressed)
	if node_renderer:
		node_renderer.set_nodes_visible(pressed)


func _on_edges_toggled(pressed: bool) -> void:
	edges_visibility_changed.emit(pressed)
	if edge_renderer:
		edge_renderer.set_roads_visible(pressed)


func _on_arrows_toggled(pressed: bool) -> void:
	arrows_visibility_changed.emit(pressed)
	# Arrow visibility would be handled by EdgeRenderer if implemented


func _on_reload_pressed() -> void:
	reload_requested.emit()


func _on_reset_camera_pressed() -> void:
	reset_camera_requested.emit()
	if camera_controller:
		camera_controller.reset_camera()
