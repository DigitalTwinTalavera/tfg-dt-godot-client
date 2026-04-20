## Debug panel UI overlay for network statistics and controls.
## Displays real-time info and provides toggles for visual elements.
## Slides in/out from the left edge; a tab button is always visible.
class_name DebugPanel
extends CanvasLayer


## Emitted when visibility toggles change
signal nodes_visibility_changed(visible: bool)
signal edges_visibility_changed(visible: bool)
signal arrows_visibility_changed(visible: bool)

## Emitted when action buttons are pressed
signal reload_requested()
signal reset_camera_requested()


# ── UI nodes ──────────────────────────────────────────────────────────────
var _stats_label      : RichTextLabel
var _camera_label     : Label
var _fps_label        : Label
var _nodes_toggle     : CheckBox
var _edges_toggle     : CheckBox
var _arrows_toggle    : CheckBox
var _reload_button    : Button
var _reset_camera_button: Button
var _panel            : PanelContainer
var _toggle_tab       : Button          # side tab to open/close the panel


## External references (set by parent scene)
var camera_controller: CameraController
var node_renderer    : NodeRenderer
var edge_renderer    : EdgeRenderer


# ── Stats cache ───────────────────────────────────────────────────────────
var _node_count          : int   = 0
var _edge_count          : int   = 0
var _total_road_length_km: float = 0.0
var _camera_position     : Vector3 = Vector3.ZERO
var _camera_distance     : float   = 0.0


# ── FPS tracking ──────────────────────────────────────────────────────────
var _frame_times    : Array[float] = []
var _fps_update_timer: float = 0.0
var _current_fps    : float = 0.0


# ── Slide state ───────────────────────────────────────────────────────────
var _is_open        : bool  = true
var _tween          : Tween

## Computed once after _setup_ui(); derived from Config.UI constants.
var _pos_panel_open : float   ## panel.position.x when fully visible
var _pos_panel_closed: float  ## panel.position.x when hidden off-screen
var _pos_tab_open   : float   ## tab.position.x when panel is open
var _pos_tab_closed : float   ## tab.position.x when panel is closed

## Fixed vertical position and size of the slide tab
const _TAB_Y     : float = 80.0
const _TAB_W     : float = 20.0
const _TAB_H     : float = 60.0
const _ANIM_DUR  : float = 0.25  ## slide duration in seconds


# ── Lifecycle ─────────────────────────────────────────────────────────────

func _ready() -> void:
	_setup_ui()
	_connect_signals()
	_update_stats_display()


func _process(delta: float) -> void:
	_update_fps(delta)
	_update_camera_info()


# ── Build UI ──────────────────────────────────────────────────────────────

func _setup_ui() -> void:
	# ── Main panel ────────────────────────────────────────────────────────
	_panel = PanelContainer.new()
	_panel.name = "DebugPanel"

	var style := StyleBoxFlat.new()
	style.bg_color                  = Config.UI.BACKGROUND_COLOR
	style.corner_radius_top_left    = Config.UI.PANEL_CORNER_RADIUS
	style.corner_radius_top_right   = Config.UI.PANEL_CORNER_RADIUS
	style.corner_radius_bottom_left = Config.UI.PANEL_CORNER_RADIUS
	style.corner_radius_bottom_right= Config.UI.PANEL_CORNER_RADIUS
	style.content_margin_left       = Config.UI.PANEL_CONTENT_MARGIN
	style.content_margin_right      = Config.UI.PANEL_CONTENT_MARGIN
	style.content_margin_top        = Config.UI.PANEL_VERTICAL_MARGIN
	style.content_margin_bottom     = Config.UI.PANEL_VERTICAL_MARGIN
	_panel.add_theme_stylebox_override("panel", style)

	var margin := float(Config.UI.PANEL_MARGIN)
	var width  := float(Config.UI.PANEL_MIN_WIDTH)

	_panel.anchors_preset     = Control.PRESET_TOP_LEFT
	_panel.position           = Vector2(margin, margin)
	_panel.custom_minimum_size = Vector2(width, 0.0)

	# ── Content ────────────────────────────────────────────────────────────
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", Config.UI.PANEL_ITEM_SPACING)
	_panel.add_child(vbox)

	var title := Label.new()
	title.text = "Debug Panel"
	title.add_theme_color_override("font_color", Config.UI.ACCENT_COLOR)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	vbox.add_child(_create_separator())

	var stats_title := Label.new()
	stats_title.text = "Network Stats"
	stats_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	vbox.add_child(stats_title)

	_stats_label = RichTextLabel.new()
	_stats_label.bbcode_enabled   = true
	_stats_label.fit_content      = true
	_stats_label.scroll_active    = false
	_stats_label.custom_minimum_size = Vector2(0, 60)
	vbox.add_child(_stats_label)

	vbox.add_child(_create_separator())

	var camera_title := Label.new()
	camera_title.text = "Camera"
	camera_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	vbox.add_child(camera_title)

	_camera_label = Label.new()
	_camera_label.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	vbox.add_child(_camera_label)

	_fps_label = Label.new()
	_fps_label.add_theme_color_override("font_color", Config.UI.SUCCESS_COLOR)
	vbox.add_child(_fps_label)

	vbox.add_child(_create_separator())

	var toggles_title := Label.new()
	toggles_title.text = "Visibility"
	toggles_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	vbox.add_child(toggles_title)

	_nodes_toggle  = _create_checkbox("Show Nodes",  true)
	_edges_toggle  = _create_checkbox("Show Roads",  true)
	_arrows_toggle = _create_checkbox("Show Arrows", true)
	vbox.add_child(_nodes_toggle)
	vbox.add_child(_edges_toggle)
	vbox.add_child(_arrows_toggle)

	vbox.add_child(_create_separator())

	var buttons_title := Label.new()
	buttons_title.text = "Actions"
	buttons_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	vbox.add_child(buttons_title)

	_reload_button       = _create_button("Reload Network")
	_reset_camera_button = _create_button("Reset Camera")
	vbox.add_child(_reload_button)
	vbox.add_child(_reset_camera_button)

	add_child(_panel)

	# ── Slide positions ────────────────────────────────────────────────────
	_pos_panel_open   = margin
	_pos_panel_closed = -(width + margin)
	_pos_tab_open     = margin + width
	_pos_tab_closed   = 0.0

	# ── Toggle tab ────────────────────────────────────────────────────────
	_toggle_tab = Button.new()
	_toggle_tab.text = "◀"
	_toggle_tab.tooltip_text = "Ocultar panel"
	_toggle_tab.anchors_preset = Control.PRESET_TOP_LEFT
	_toggle_tab.position = Vector2(_pos_tab_open, _TAB_Y)
	_toggle_tab.custom_minimum_size = Vector2(_TAB_W, _TAB_H)

	var tab_style := StyleBoxFlat.new()
	tab_style.bg_color                   = Config.UI.BACKGROUND_COLOR
	tab_style.corner_radius_top_right    = Config.UI.PANEL_CORNER_RADIUS
	tab_style.corner_radius_bottom_right = Config.UI.PANEL_CORNER_RADIUS
	_toggle_tab.add_theme_stylebox_override("normal",  tab_style)

	var tab_hover := StyleBoxFlat.new()
	tab_hover.bg_color                   = Config.UI.BUTTON_HOVER_COLOR
	tab_hover.corner_radius_top_right    = Config.UI.PANEL_CORNER_RADIUS
	tab_hover.corner_radius_bottom_right = Config.UI.PANEL_CORNER_RADIUS
	_toggle_tab.add_theme_stylebox_override("hover",   tab_hover)

	var tab_pressed := StyleBoxFlat.new()
	tab_pressed.bg_color                   = Config.UI.BUTTON_PRESSED_COLOR
	tab_pressed.corner_radius_top_right    = Config.UI.PANEL_CORNER_RADIUS
	tab_pressed.corner_radius_bottom_right = Config.UI.PANEL_CORNER_RADIUS
	_toggle_tab.add_theme_stylebox_override("pressed", tab_pressed)

	_toggle_tab.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	_toggle_tab.add_theme_font_size_override("font_size", 10)
	_toggle_tab.pressed.connect(_on_toggle_tab_pressed)
	add_child(_toggle_tab)


func _create_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_color_override("separator", Config.UI.SEPARATOR_COLOR)
	return sep


func _create_checkbox(text: String, checked: bool) -> CheckBox:
	var checkbox := CheckBox.new()
	checkbox.text           = text
	checkbox.button_pressed = checked
	checkbox.add_theme_color_override("font_color",         Config.UI.TEXT_MUTED_COLOR)
	checkbox.add_theme_color_override("font_pressed_color", Config.UI.TEXT_COLOR)
	return checkbox


func _create_button(text: String) -> Button:
	var button := Button.new()
	button.text               = text
	button.custom_minimum_size = Vector2(0, Config.UI.BUTTON_HEIGHT)

	var style_normal := StyleBoxFlat.new()
	style_normal.bg_color                   = Config.UI.BUTTON_NORMAL_COLOR
	style_normal.corner_radius_top_left     = Config.UI.BUTTON_CORNER_RADIUS
	style_normal.corner_radius_top_right    = Config.UI.BUTTON_CORNER_RADIUS
	style_normal.corner_radius_bottom_left  = Config.UI.BUTTON_CORNER_RADIUS
	style_normal.corner_radius_bottom_right = Config.UI.BUTTON_CORNER_RADIUS
	button.add_theme_stylebox_override("normal", style_normal)

	var style_hover := StyleBoxFlat.new()
	style_hover.bg_color                   = Config.UI.BUTTON_HOVER_COLOR
	style_hover.corner_radius_top_left     = Config.UI.BUTTON_CORNER_RADIUS
	style_hover.corner_radius_top_right    = Config.UI.BUTTON_CORNER_RADIUS
	style_hover.corner_radius_bottom_left  = Config.UI.BUTTON_CORNER_RADIUS
	style_hover.corner_radius_bottom_right = Config.UI.BUTTON_CORNER_RADIUS
	button.add_theme_stylebox_override("hover", style_hover)

	var style_pressed := StyleBoxFlat.new()
	style_pressed.bg_color                   = Config.UI.BUTTON_PRESSED_COLOR
	style_pressed.corner_radius_top_left     = Config.UI.BUTTON_CORNER_RADIUS
	style_pressed.corner_radius_top_right    = Config.UI.BUTTON_CORNER_RADIUS
	style_pressed.corner_radius_bottom_left  = Config.UI.BUTTON_CORNER_RADIUS
	style_pressed.corner_radius_bottom_right = Config.UI.BUTTON_CORNER_RADIUS
	button.add_theme_stylebox_override("pressed", style_pressed)

	return button


func _connect_signals() -> void:
	_nodes_toggle.toggled.connect(_on_nodes_toggled)
	_edges_toggle.toggled.connect(_on_edges_toggled)
	_arrows_toggle.toggled.connect(_on_arrows_toggled)
	_reload_button.pressed.connect(_on_reload_pressed)
	_reset_camera_button.pressed.connect(_on_reset_camera_pressed)


# ── Slide animation ───────────────────────────────────────────────────────

func _on_toggle_tab_pressed() -> void:
	if _is_open:
		_slide_out()
	else:
		_slide_in()


func _slide_in() -> void:
	_is_open = true
	_toggle_tab.text         = "◀"
	_toggle_tab.tooltip_text = "Ocultar panel"
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_ease(Tween.EASE_OUT)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_panel,      "position:x", _pos_panel_open, _ANIM_DUR)
	_tween.tween_property(_toggle_tab, "position:x", _pos_tab_open,   _ANIM_DUR)


func _slide_out() -> void:
	_is_open = false
	_toggle_tab.text         = "▶"
	_toggle_tab.tooltip_text = "Mostrar panel"
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_ease(Tween.EASE_OUT)
	_tween.set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_panel,      "position:x", _pos_panel_closed, _ANIM_DUR)
	_tween.tween_property(_toggle_tab, "position:x", _pos_tab_closed,   _ANIM_DUR)


# ── Per-frame updates ─────────────────────────────────────────────────────

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


func _update_fps_display() -> void:
	var color := Config.UI.SUCCESS_COLOR
	if _current_fps < 30:
		color = Config.UI.ERROR_COLOR
	elif _current_fps < 50:
		color = Config.UI.WARNING_COLOR

	_fps_label.text = "FPS: %.0f" % _current_fps
	_fps_label.add_theme_color_override("font_color", color)


func _update_stats_display() -> void:
	var text := "[color=#%s]Nodes:[/color] %d\n" % [Config.UI.TEXT_COLOR.to_html(false), _node_count]
	text += "[color=#%s]Edges:[/color] %d\n" % [Config.UI.TEXT_COLOR.to_html(false), _edge_count]
	text += "[color=#%s]Length:[/color] %.1f km" % [Config.UI.TEXT_COLOR.to_html(false), _total_road_length_km]
	_stats_label.text = text


# ── Public API ────────────────────────────────────────────────────────────

func set_network_stats(nodes: int, edges: int, length_km: float) -> void:
	_node_count           = nodes
	_edge_count           = edges
	_total_road_length_km = length_km
	_update_stats_display()


func update_from_renderers() -> void:
	if node_renderer:
		var stats := node_renderer.get_stats()
		_node_count = stats.get("total_nodes", 0)

	if edge_renderer:
		var stats := edge_renderer.get_stats()
		_edge_count           = stats.get("total_edges", 0)
		_total_road_length_km = stats.get("total_length_km", 0.0)

	_update_stats_display()


func set_nodes_visible(visible: bool) -> void:
	_nodes_toggle.button_pressed = visible


func set_edges_visible(visible: bool) -> void:
	_edges_toggle.button_pressed = visible


func set_arrows_visible(visible: bool) -> void:
	_arrows_toggle.button_pressed = visible


func are_nodes_visible() -> bool:
	return _nodes_toggle.button_pressed


func are_edges_visible() -> bool:
	return _edges_toggle.button_pressed


func are_arrows_visible() -> bool:
	return _arrows_toggle.button_pressed


## Show/hide the panel (with slide animation).
func set_panel_visible(visible: bool) -> void:
	if visible:
		_slide_in()
	else:
		_slide_out()


func is_panel_visible() -> bool:
	return _is_open


func toggle_panel() -> void:
	if _is_open:
		_slide_out()
	else:
		_slide_in()


# ── Signal handlers ───────────────────────────────────────────────────────

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


func _on_reload_pressed() -> void:
	reload_requested.emit()


func _on_reset_camera_pressed() -> void:
	reset_camera_requested.emit()
	if camera_controller:
		camera_controller.reset_camera()
