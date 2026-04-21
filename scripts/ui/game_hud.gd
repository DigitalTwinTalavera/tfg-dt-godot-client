## GameHUD — Cities Skylines-style simulation HUD.
##
## Replaces the five separate panels (SimControlPanel, TrafficLightPanel,
## VehicleInfoPopup, DebugPanel, ConnectionIndicator) with a single unified
## layout:
##
##   ┌──────────────────────────────────────────────┐  ← TopBar (30px)
##   │  ● RUNNING  T:00:23  🚗 47  60 FPS           │
##   │                                              │
##   │  (3D viewport)         ┌──────────────────┐  │
##   │                        │  RightPanel      │  │
##   │                        │  (260px, slides) │  │
##   │  ┌────────────────────┴──────────────────┐│  │
##   │  │  TabContent (expands upward)          ││  │
##   ├──┴───────────────────────────────────────┴┴──┤
##   │  [▶ Sim] [🚦 TL] [🗺 Mapa] [⚙ Config]       │  ← TabButtons (40px)
##   └──────────────────────────────────────────────┘
##
## Signals:
##   follow_vehicle_requested(vehicle_id)  — Camera should start following
##   unfollow_requested()                  — Camera should stop following
##
## Layer 125.
class_name GameHUD
extends CanvasLayer


# ── Signals ──────────────────────────────────────────────────────────────────
signal follow_vehicle_requested(vehicle_id: String)
signal unfollow_requested()
signal reset_camera_requested()
signal reload_map_requested()
signal arrows_visibility_changed(visible_flag: bool)
signal camera_speed_changed(speed: float)
signal camera_smooth_changed(enabled: bool)


# ── Constants ─────────────────────────────────────────────────────────────────
const TOP_BAR_HEIGHT:    float = 30.0
const TAB_BAR_HEIGHT:    float = 40.0
const RIGHT_PANEL_WIDTH: float = 260.0
const TAB_COUNT:         int   = 5
const RIGHT_ANIM_TIME:   float = 0.2


# ── Injected references ───────────────────────────────────────────────────────
var _camera: Camera3D
var _converter: CoordinateConverter
var _node_renderer: Node            # NodeRenderer (duck-typed)
var _edge_renderer: Node            # EdgeRenderer (duck-typed)
var _vehicle_renderer: Node         # VehicleRenderer (duck-typed)


# ── HTTP client ───────────────────────────────────────────────────────────────
var _http: HTTPClient2


# ── TopBar nodes ──────────────────────────────────────────────────────────────
var _top_bar:        Control
var _dot:            ColorRect
var _state_lbl:      Label
var _simtime_lbl:    Label
var _vcount_lbl:     Label
var _fps_lbl:        Label


# ── BottomBar nodes ───────────────────────────────────────────────────────────
var _tab_bar:        Control
var _tab_content:    PanelContainer   ## Expands upward from the tab bar
var _tab_btns:       Array[Button] = []
var _tab_panels:     Array[Control] = []   ## One VBoxContainer per tab
var _active_tab:     int = -1   ## -1 = all closed


# ── RightPanel nodes ──────────────────────────────────────────────────────────
var _right_panel:    PanelContainer
var _vehicle_panel:  Control
var _tl_panel_right: Control

# VehiclePanel labels
var _vp_title:       Label
var _vp_status:      Label
var _vp_speed:       Label
var _vp_heading:     Label
var _vp_gps:         Label
var _vp_edge:        Label
var _vp_follow_btn:  Button
var _vp_pause_btn:   Button
var _vp_speed_slider:HSlider
var _vp_speed_val:   Label
var _vp_delete_btn:  Button

# TLPanel labels
var _tlp_title:      Label
var _tlp_state:      Label
var _tlp_override_green: Button
var _tlp_override_yellow: Button
var _tlp_override_red:   Button
var _tlp_override_auto:  Button

# TabSim widgets
var _sim_state_lbl:  Label
var _spawn_count:    SpinBox
var _auto_spawn_btn: Button
var _auto_spawn_rate:SpinBox
var _start_btn:      Button
var _stop_btn:       Button
var _pause_btn:      Button   # doubles as Resume

# TabTL widgets
var _tl_summary_lbl: Label
var _tl_list_vbox:   VBoxContainer
var _tl_indicators:  Dictionary = {}   ## node_id → ColorRect

# TabMap widgets
var _lbl_map_status:  Label   ## "Cargando red..." / "Mapa cargado ✓" / "Error: ..."
var _lbl_net_stats:   Label   ## "Nodos: N | Aristas: N | Long.: N km"
var _lbl_node_types:  Label   ## type breakdown from NodeRenderer stats
var _lbl_road_types:  Label   ## type breakdown from EdgeRenderer stats
var _lbl_cam_pos:     Label   ## "X: ...  Y: ...  Z: ..."
var _reload_map_btn:  Button
var _map_tab_open:    bool = false

# TabSettings widgets
var _cam_speed_slider: HSlider
var _cam_speed_lbl:    Label

# TabCollisions widgets
var _coll_summary_lbl: Label
var _coll_list_vbox:   VBoxContainer
var _coll_rows:        Dictionary = {}   ## vehicle_id → row Control

# Collision registry (client-side cache). Rebuilt from the /simulation/collisions
# endpoint after map load, and updated live from MSG_TYPE_VEHICLE_COLLISION.
## vehicle_id → {partner_id: String, edge: Array[int], sim_time: float}
var _collisions: Dictionary = {}

# Network stats cache
var _net_nodes:   int   = 0
var _net_edges:   int   = 0
var _net_road_km: float = 0.0

# Runtime
var _fps_timer:        float = 0.0
var _selected_vehicle: String = ""
var _selected_node:    int    = -1
var _following:        bool   = false
var _reroute_mode:     bool   = false
var _request_in_flight: bool  = false
var _right_visible:    bool   = false
var _right_tween:      Tween


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 125
	_http = HTTPClient2.new(Config.api_url)
	add_child(_http)

	_build_ui()
	_connect_signals()


func _process(delta: float) -> void:
	_fps_timer += delta
	if _fps_timer >= Config.UI.FPS_UPDATE_INTERVAL:
		_fps_timer = 0.0
		_refresh_topbar()

	if _selected_vehicle != "" and VehicleManager.vehicles.has(_selected_vehicle):
		_refresh_vehicle_panel(VehicleManager.get_vehicle(_selected_vehicle))

	# Refresh camera position label when map tab is open
	if _map_tab_open and is_instance_valid(_lbl_cam_pos) and is_instance_valid(_camera):
		var p := _camera.global_position
		_lbl_cam_pos.text = "X: %.0f  Y: %.0f  Z: %.0f" % [p.x, p.y, p.z]


# ── Dependency injection ──────────────────────────────────────────────────────

func set_camera(camera: Camera3D) -> void:
	_camera = camera


func set_converter(converter: CoordinateConverter) -> void:
	_converter = converter


func set_renderers(node_renderer: Node, edge_renderer: Node, vehicle_renderer: Node) -> void:
	_node_renderer    = node_renderer
	_edge_renderer    = edge_renderer
	_vehicle_renderer = vehicle_renderer


func update_network_stats(node_count: int, edge_count: int, road_km: float) -> void:
	_net_nodes   = node_count
	_net_edges   = edge_count
	_net_road_km = road_km
	if is_instance_valid(_lbl_net_stats):
		_lbl_net_stats.text = "Nodos: %d | Aristas: %d | Long.: %.1f km" % [
			node_count, edge_count, road_km
		]


func update_render_stats(node_stats: Dictionary, edge_stats: Dictionary) -> void:
	## Populates the node-type and road-type breakdown labels in the Mapa tab.
	## Called by test_node_renderer after rendering completes.
	if is_instance_valid(_lbl_node_types):
		var type_counts: Dictionary = node_stats.get("type_counts", {})
		var lines: PackedStringArray = []
		for type_name: String in type_counts:
			lines.append("%s: %d" % [type_name.capitalize(), type_counts[type_name]])
		_lbl_node_types.text = "\n".join(lines) if lines.size() > 0 else "--"

	if is_instance_valid(_lbl_road_types):
		var road_counts: Dictionary = edge_stats.get("type_counts", {})
		var lines: PackedStringArray = []
		for road_name: String in road_counts:
			lines.append("%s: %d" % [road_name.capitalize(), road_counts[road_name]])
		_lbl_road_types.text = "\n".join(lines) if lines.size() > 0 else "--"


# ── Public API ────────────────────────────────────────────────────────────────

func show_vehicle_info(vehicle_id: String, state: Dictionary) -> void:
	_selected_vehicle = vehicle_id
	_selected_node    = -1
	_vehicle_panel.visible  = true
	_tl_panel_right.visible = false
	_vp_title.text = "Vehículo %s" % vehicle_id
	_refresh_vehicle_panel(state)
	_show_right_panel(true)


func show_node_info(node_id: int, node_type: String) -> void:
	if node_type != "traffic_light":
		return
	_selected_node    = node_id
	_selected_vehicle = ""
	_vehicle_panel.visible  = false
	_tl_panel_right.visible = true
	_tlp_title.text = "Semáforo #%d" % node_id
	var phase: String = TrafficLightManager.traffic_lights.get(node_id, "desconocido")
	_tlp_state.text = "Fase: %s" % phase
	_show_right_panel(true)


func close_right_panel() -> void:
	_selected_vehicle = ""
	_selected_node    = -1
	_show_right_panel(false)
	if _following:
		_stop_following()


# ── Build UI ──────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_build_topbar()
	_build_bottombar()
	_build_right_panel()


func _build_topbar() -> void:
	_top_bar = PanelContainer.new()
	_top_bar.anchor_left   = 0.0
	_top_bar.anchor_right  = 1.0
	_top_bar.anchor_top    = 0.0
	_top_bar.anchor_bottom = 0.0
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_apply_panel_style(_top_bar)
	add_child(_top_bar)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	_top_bar.add_child(hbox)

	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(10, 10)
	_dot.color = Config.UI.TEXT_SECONDARY_COLOR
	var dot_wrap := MarginContainer.new()
	dot_wrap.add_theme_constant_override("margin_top", 10)
	dot_wrap.add_child(_dot)
	hbox.add_child(dot_wrap)

	_state_lbl   = _make_top_label("DESCONECTADO")
	_simtime_lbl = _make_top_label("T: --:--")
	_vcount_lbl  = _make_top_label("Veh: 0")
	_fps_lbl     = _make_top_label("-- FPS")

	for lbl in [_state_lbl, _simtime_lbl, _vcount_lbl, _fps_lbl]:
		hbox.add_child(lbl)
		var sep := VSeparator.new()
		hbox.add_child(sep)


func _build_bottombar() -> void:
	# ── Tab content (expands upward from the tab buttons) ──────────────────
	_tab_content = PanelContainer.new()
	_tab_content.anchor_left   = 0.0
	_tab_content.anchor_right  = 1.0
	_tab_content.anchor_top    = 1.0
	_tab_content.anchor_bottom = 1.0
	_tab_content.offset_top    = -(TAB_BAR_HEIGHT + 300.0)
	_tab_content.offset_bottom = -TAB_BAR_HEIGHT
	_tab_content.visible       = false
	_apply_panel_style(_tab_content)
	add_child(_tab_content)

	var content_margin := MarginContainer.new()
	content_margin.add_theme_constant_override("margin_left",  8)
	content_margin.add_theme_constant_override("margin_right", 8)
	content_margin.add_theme_constant_override("margin_top",   6)
	content_margin.add_theme_constant_override("margin_bottom",6)
	_tab_content.add_child(content_margin)

	var content_stack := VBoxContainer.new()
	content_margin.add_child(content_stack)

	_tab_panels.resize(TAB_COUNT)
	_tab_panels[0] = _build_tab_sim()
	_tab_panels[1] = _build_tab_tl()
	_tab_panels[2] = _build_tab_map()
	_tab_panels[3] = _build_tab_settings()
	_tab_panels[4] = _build_tab_collisions()
	for p in _tab_panels:
		p.visible = false
		content_stack.add_child(p)

	# ── Tab button bar ─────────────────────────────────────────────────────
	_tab_bar = PanelContainer.new()
	_tab_bar.anchor_left   = 0.0
	_tab_bar.anchor_right  = 1.0
	_tab_bar.anchor_top    = 1.0
	_tab_bar.anchor_bottom = 1.0
	_tab_bar.offset_top    = -TAB_BAR_HEIGHT
	_tab_bar.offset_bottom = 0.0
	_apply_panel_style(_tab_bar)
	add_child(_tab_bar)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 2)
	_tab_bar.add_child(hbox)

	var tab_labels := ["▶  Simulación", "🚦 Semáforos", "🗺 Mapa", "⚙ Ajustes", "🚨 Colisiones"]
	var tab_tooltips := [
		"Controlar la simulación (iniciar, pausar, detener, generar vehículos)",
		"Estado y control global de los semáforos",
		"Capas visibles, estadísticas de la red y recargar el mapa",
		"Configuración de cámara, depuración e información de la aplicación",
		"Vehículos colisionados — requieren retirada manual (gemelo digital)",
	]
	_tab_btns.resize(TAB_COUNT)
	for i in range(TAB_COUNT):
		var btn := Button.new()
		btn.text = tab_labels[i]
		btn.tooltip_text = tab_tooltips[i]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 12)
		_apply_tab_button_style(btn, false)
		btn.pressed.connect(_on_tab_pressed.bind(i))
		hbox.add_child(btn)
		_tab_btns[i] = btn


func _build_tab_sim() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)

	var ctrl_row := HBoxContainer.new()
	ctrl_row.add_theme_constant_override("separation", 4)
	vbox.add_child(ctrl_row)

	_start_btn = _make_btn("▶ Iniciar",
		"Arranca la simulación de tráfico en el backend", true)
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_btn.pressed.connect(func() -> void: _sim_post("/simulation/start"))
	ctrl_row.add_child(_start_btn)

	_pause_btn = _make_btn("⏸ Pausar", "Pausa o reanuda la simulación")
	_pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pause_btn.pressed.connect(_on_pause_resume)
	ctrl_row.add_child(_pause_btn)

	_stop_btn = _make_btn("⏹ Detener", "Detiene la simulación y limpia los vehículos")
	_stop_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stop_btn.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	_stop_btn.pressed.connect(func() -> void: _sim_post("/simulation/stop"))
	ctrl_row.add_child(_stop_btn)

	_sim_state_lbl = Label.new()
	_sim_state_lbl.text = "Estado: desconocido"
	_sim_state_lbl.add_theme_font_size_override("font_size", 11)
	_sim_state_lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	vbox.add_child(_sim_state_lbl)

	vbox.add_child(HSeparator.new())

	var spawn_row := HBoxContainer.new()
	spawn_row.add_theme_constant_override("separation", 4)
	vbox.add_child(spawn_row)

	var spawn_lbl := Label.new()
	spawn_lbl.text = "Spawn:"
	spawn_lbl.add_theme_font_size_override("font_size", 11)
	spawn_row.add_child(spawn_lbl)

	_spawn_count = SpinBox.new()
	_spawn_count.min_value = 1
	_spawn_count.max_value = 1_000_000
	_spawn_count.step = 1
	_spawn_count.rounded = true
	_spawn_count.value = 10
	_spawn_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spawn_row.add_child(_spawn_count)

	var spawn_btn := _make_btn("Generar")
	spawn_btn.pressed.connect(_on_spawn_vehicles)
	spawn_row.add_child(spawn_btn)

	var auto_row := HBoxContainer.new()
	auto_row.add_theme_constant_override("separation", 4)
	vbox.add_child(auto_row)

	_auto_spawn_btn = CheckButton.new()
	_auto_spawn_btn.text = "Auto-spawn"
	_auto_spawn_btn.add_theme_font_size_override("font_size", 11)
	_auto_spawn_btn.toggled.connect(_on_auto_spawn_toggled)
	auto_row.add_child(_auto_spawn_btn)

	_auto_spawn_rate = SpinBox.new()
	_auto_spawn_rate.min_value = 1
	_auto_spawn_rate.max_value = 60
	_auto_spawn_rate.value = 5
	_auto_spawn_rate.suffix = "/min"
	_auto_spawn_rate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	auto_row.add_child(_auto_spawn_rate)

	return vbox


func _build_tab_tl() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)

	var global_lbl := Label.new()
	global_lbl.text = "Control global:"
	global_lbl.add_theme_font_size_override("font_size", 11)
	global_lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	vbox.add_child(global_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	vbox.add_child(btn_row)

	var btn_green := _make_btn("🟢 Verde")
	btn_green.add_theme_color_override("font_color", Config.TLColors.GREEN)
	btn_green.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_green.pressed.connect(func() -> void: _tl_post("all-green"))
	btn_row.add_child(btn_green)

	var btn_red := _make_btn("🔴 Rojo")
	btn_red.add_theme_color_override("font_color", Config.TLColors.RED)
	btn_red.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_red.pressed.connect(func() -> void: _tl_post("all-red"))
	btn_row.add_child(btn_red)

	var btn_norm := _make_btn("🔄 Normal")
	btn_norm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_norm.pressed.connect(func() -> void: _tl_post("normal"))
	btn_row.add_child(btn_norm)

	_tl_summary_lbl = Label.new()
	_tl_summary_lbl.text = "G:0  Y:0  R:0"
	_tl_summary_lbl.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_tl_summary_lbl)

	vbox.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.custom_minimum_size    = Vector2(0.0, 100.0)
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_tl_list_vbox = VBoxContainer.new()
	_tl_list_vbox.add_theme_constant_override("separation", 2)
	_tl_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_tl_list_vbox)

	var empty_lbl := Label.new()
	empty_lbl.name = "EmptyLabel"
	empty_lbl.text = "Sin datos (¿simulación iniciada?)"
	empty_lbl.add_theme_font_size_override("font_size", 10)
	empty_lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	_tl_list_vbox.add_child(empty_lbl)

	return vbox


func _build_tab_map() -> VBoxContainer:
	# Outer container returned to the tab system
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 0)
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# ScrollContainer so all content is reachable regardless of panel height
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# ── Estado del mapa (visibilidad IPO #1) ─────────────────────────────────
	vbox.add_child(_make_section_label("Estado"))

	_lbl_map_status = Label.new()
	_lbl_map_status.text = "Inicializando…"
	_lbl_map_status.add_theme_font_size_override("font_size", 11)
	_lbl_map_status.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	_lbl_map_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_lbl_map_status)

	vbox.add_child(HSeparator.new())

	# ── Visibilidad ───────────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Capas visibles"))

	var chk_row := HBoxContainer.new()
	chk_row.add_theme_constant_override("separation", 6)
	vbox.add_child(chk_row)

	var chk_roads := CheckBox.new()
	chk_roads.text = "Carreteras"
	chk_roads.button_pressed = true
	chk_roads.tooltip_text = "Mostrar u ocultar las carreteras en el mapa"
	chk_roads.add_theme_font_size_override("font_size", 11)
	chk_roads.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	chk_roads.toggled.connect(func(v: bool) -> void:
		if _edge_renderer and _edge_renderer.has_method("set_roads_visible"):
			_edge_renderer.set_roads_visible(v)
	)
	chk_row.add_child(chk_roads)

	var chk_nodes := CheckBox.new()
	chk_nodes.text = "Nodos"
	chk_nodes.button_pressed = true
	chk_nodes.tooltip_text = "Mostrar u ocultar las intersecciones"
	chk_nodes.add_theme_font_size_override("font_size", 11)
	chk_nodes.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	chk_nodes.toggled.connect(func(v: bool) -> void:
		if _node_renderer and _node_renderer.has_method("set_nodes_visible"):
			_node_renderer.set_nodes_visible(v)
	)
	chk_row.add_child(chk_nodes)

	var chk_tl := CheckBox.new()
	chk_tl.text = "Semáforos"
	chk_tl.button_pressed = true
	chk_tl.tooltip_text = "Mostrar u ocultar los semáforos"
	chk_tl.add_theme_font_size_override("font_size", 11)
	chk_tl.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	chk_tl.toggled.connect(func(v: bool) -> void:
		if _node_renderer and _node_renderer.has_method("set_traffic_lights_visible"):
			_node_renderer.set_traffic_lights_visible(v)
	)
	chk_row.add_child(chk_tl)

	var chk_arrows := CheckBox.new()
	chk_arrows.text = "Flechas"
	chk_arrows.button_pressed = true
	chk_arrows.tooltip_text = "Mostrar u ocultar las flechas de sentido único"
	chk_arrows.add_theme_font_size_override("font_size", 11)
	chk_arrows.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	chk_arrows.toggled.connect(func(v: bool) -> void:
		if _edge_renderer and _edge_renderer.has_method("set_arrows_visible"):
			_edge_renderer.set_arrows_visible(v)
	)
	chk_row.add_child(chk_arrows)

	vbox.add_child(HSeparator.new())

	# ── Red de transporte ─────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Red de transporte"))

	_lbl_net_stats = Label.new()
	_lbl_net_stats.text = "Nodos: -- | Aristas: -- | Long.: -- km"
	_lbl_net_stats.add_theme_font_size_override("font_size", 11)
	_lbl_net_stats.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	_lbl_net_stats.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_lbl_net_stats)

	# ── Tipos de nodo ─────────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Tipos de nodo"))

	_lbl_node_types = Label.new()
	_lbl_node_types.text = "--"
	_lbl_node_types.add_theme_font_size_override("font_size", 11)
	_lbl_node_types.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	_lbl_node_types.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_lbl_node_types)

	# ── Tipos de vía ─────────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Tipos de vía"))

	_lbl_road_types = Label.new()
	_lbl_road_types.text = "--"
	_lbl_road_types.add_theme_font_size_override("font_size", 11)
	_lbl_road_types.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	_lbl_road_types.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_lbl_road_types)

	vbox.add_child(HSeparator.new())

	# ── Cámara ────────────────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Cámara"))

	_lbl_cam_pos = Label.new()
	_lbl_cam_pos.text = "X: --  Y: --  Z: --"
	_lbl_cam_pos.add_theme_font_size_override("font_size", 11)
	_lbl_cam_pos.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	vbox.add_child(_lbl_cam_pos)

	var reset_btn := _make_btn(
		"🔄 Reset cámara",
		"Restablece la cámara a la vista por defecto (atajo: fuera de la pestaña, rueda del ratón para zoom; clic derecho para rotar)"
	)
	reset_btn.pressed.connect(func() -> void: reset_camera_requested.emit())
	vbox.add_child(reset_btn)

	vbox.add_child(HSeparator.new())

	# ── Acciones ──────────────────────────────────────────────────────────────
	_reload_map_btn = _make_btn(
		"🗺  Recargar mapa",
		"Descarga de nuevo la red desde el backend y la vuelve a renderizar",
		true  # primary → estilo azul
	)
	_reload_map_btn.pressed.connect(func() -> void: reload_map_requested.emit())
	vbox.add_child(_reload_map_btn)

	return outer


func _build_tab_settings() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)

	# ── Cámara ────────────────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Cámara"))

	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 6)
	vbox.add_child(speed_row)

	var speed_lbl_fixed := Label.new()
	speed_lbl_fixed.text = "Vel. teclado:"
	speed_lbl_fixed.add_theme_font_size_override("font_size", 11)
	speed_lbl_fixed.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	speed_row.add_child(speed_lbl_fixed)

	_cam_speed_lbl = Label.new()
	_cam_speed_lbl.text = "%d m/s" % int(Config.Camera.KEYBOARD_MOVE_SPEED)
	_cam_speed_lbl.add_theme_font_size_override("font_size", 11)
	_cam_speed_lbl.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	_cam_speed_lbl.custom_minimum_size = Vector2(60, 0)
	speed_row.add_child(_cam_speed_lbl)

	_cam_speed_slider = HSlider.new()
	_cam_speed_slider.min_value = 50.0
	_cam_speed_slider.max_value = 1000.0
	_cam_speed_slider.step = 50.0
	_cam_speed_slider.value = Config.Camera.KEYBOARD_MOVE_SPEED
	_cam_speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cam_speed_slider.value_changed.connect(func(val: float) -> void:
		_cam_speed_lbl.text = "%d m/s" % int(val)
		camera_speed_changed.emit(val)
	)
	vbox.add_child(_cam_speed_slider)

	var smooth_row := HBoxContainer.new()
	smooth_row.add_theme_constant_override("separation", 6)
	vbox.add_child(smooth_row)

	var smooth_lbl := Label.new()
	smooth_lbl.text = "Suavizado:"
	smooth_lbl.add_theme_font_size_override("font_size", 11)
	smooth_lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	smooth_row.add_child(smooth_lbl)

	var smooth_chk := CheckButton.new()
	smooth_chk.button_pressed = Config.Camera.SMOOTH_ENABLED
	smooth_chk.add_theme_font_size_override("font_size", 11)
	smooth_chk.toggled.connect(func(v: bool) -> void: camera_smooth_changed.emit(v))
	smooth_row.add_child(smooth_chk)

	vbox.add_child(HSeparator.new())

	# ── Depuración ────────────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Depuración"))

	var debug_chk := CheckBox.new()
	debug_chk.text = "Debug info"
	debug_chk.button_pressed = Config.DEBUG_MODE
	debug_chk.add_theme_font_size_override("font_size", 11)
	vbox.add_child(debug_chk)

	vbox.add_child(HSeparator.new())

	# ── Aplicación ────────────────────────────────────────────────────────────
	vbox.add_child(_make_section_label("Aplicación"))

	var ver_lbl := Label.new()
	ver_lbl.text = "Versión: %s" % Config.APP_VERSION
	ver_lbl.add_theme_font_size_override("font_size", 11)
	ver_lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	vbox.add_child(ver_lbl)

	return vbox


func _build_tab_collisions() -> VBoxContainer:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 5)
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_coll_summary_lbl = Label.new()
	_coll_summary_lbl.text = "Colisiones activas: 0"
	_coll_summary_lbl.add_theme_font_size_override("font_size", 12)
	_coll_summary_lbl.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	outer.add_child(_coll_summary_lbl)

	var refresh_btn := _make_btn(
		"🔄 Refrescar",
		"Consulta el endpoint GET /simulation/collisions para resincronizar la lista",
	)
	refresh_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh_btn.pressed.connect(_refresh_collisions)
	outer.add_child(refresh_btn)

	outer.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	scroll.custom_minimum_size    = Vector2(0.0, 180.0)
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	_coll_list_vbox = VBoxContainer.new()
	_coll_list_vbox.add_theme_constant_override("separation", 3)
	_coll_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_coll_list_vbox)

	var empty_lbl := Label.new()
	empty_lbl.name = "EmptyLabel"
	empty_lbl.text = "Sin colisiones activas."
	empty_lbl.add_theme_font_size_override("font_size", 10)
	empty_lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	_coll_list_vbox.add_child(empty_lbl)

	return outer


func _build_right_panel() -> void:
	_right_panel = PanelContainer.new()
	_right_panel.anchor_left   = 1.0
	_right_panel.anchor_right  = 1.0
	_right_panel.anchor_top    = 0.0
	_right_panel.anchor_bottom = 1.0
	_right_panel.offset_left   = 0.0   # starts off-screen (panel hidden)
	_right_panel.offset_right  = RIGHT_PANEL_WIDTH
	_right_panel.offset_top    = TOP_BAR_HEIGHT
	_right_panel.offset_bottom = -TAB_BAR_HEIGHT
	_right_panel.custom_minimum_size = Vector2(RIGHT_PANEL_WIDTH, 0.0)
	_right_panel.visible = false
	_apply_panel_style(_right_panel)
	add_child(_right_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   8)
	margin.add_theme_constant_override("margin_right",  8)
	margin.add_theme_constant_override("margin_top",    6)
	margin.add_theme_constant_override("margin_bottom", 8)
	_right_panel.add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	margin.add_child(outer)

	_vehicle_panel  = _build_vehicle_panel_content(outer)
	_tl_panel_right = _build_tl_panel_content(outer)

	_vehicle_panel.visible  = false
	_tl_panel_right.visible = false


func _build_vehicle_panel_content(parent: VBoxContainer) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	parent.add_child(vbox)

	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	_vp_title = Label.new()
	_vp_title.text = "Vehículo --"
	_vp_title.add_theme_font_size_override("font_size", 13)
	_vp_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	_vp_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_vp_title)

	var close_btn := _make_chrome_btn("×")
	close_btn.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	close_btn.pressed.connect(close_right_panel)
	title_row.add_child(close_btn)

	_vp_status  = _make_info_label("")
	_vp_speed   = _make_info_label("")
	_vp_heading = _make_info_label("")
	_vp_gps     = _make_info_label("")
	_vp_edge    = _make_info_label("")
	for lbl in [_vp_status, _vp_speed, _vp_heading, _vp_gps, _vp_edge]:
		vbox.add_child(lbl)

	vbox.add_child(HSeparator.new())

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 4)
	vbox.add_child(action_row)

	_vp_follow_btn = _make_btn("📷 Seguir")
	_vp_follow_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_follow_btn.pressed.connect(_on_follow_toggle)
	action_row.add_child(_vp_follow_btn)

	_vp_pause_btn = _make_btn("✋ Parar")
	_vp_pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_pause_btn.pressed.connect(_on_vehicle_pause_toggle)
	action_row.add_child(_vp_pause_btn)

	vbox.add_child(HSeparator.new())

	var speed_lbl := Label.new()
	speed_lbl.text = "Vel. deseada:"
	speed_lbl.add_theme_font_size_override("font_size", 11)
	speed_lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	vbox.add_child(speed_lbl)

	_vp_speed_slider = HSlider.new()
	_vp_speed_slider.min_value = 0.0
	_vp_speed_slider.max_value = 130.0
	_vp_speed_slider.step = 1.0
	_vp_speed_slider.value = 50.0
	_vp_speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_speed_slider.value_changed.connect(_on_vehicle_speed_changed)
	vbox.add_child(_vp_speed_slider)

	_vp_speed_val = Label.new()
	_vp_speed_val.text = "50 km/h"
	_vp_speed_val.add_theme_font_size_override("font_size", 11)
	_vp_speed_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_vp_speed_val)

	vbox.add_child(HSeparator.new())

	var reroute_btn := _make_btn("🗺 Reasignar destino")
	reroute_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reroute_btn.pressed.connect(_on_reroute_start)
	vbox.add_child(reroute_btn)

	_vp_delete_btn = _make_btn("🗑 Eliminar vehículo")
	_vp_delete_btn.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	_vp_delete_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_delete_btn.pressed.connect(_on_delete_vehicle)
	vbox.add_child(_vp_delete_btn)

	return vbox


func _build_tl_panel_content(parent: VBoxContainer) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	parent.add_child(vbox)

	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	_tlp_title = Label.new()
	_tlp_title.text = "Semáforo --"
	_tlp_title.add_theme_font_size_override("font_size", 13)
	_tlp_title.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	_tlp_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_tlp_title)

	var close_btn := _make_chrome_btn("×")
	close_btn.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	close_btn.pressed.connect(close_right_panel)
	title_row.add_child(close_btn)

	_tlp_state = Label.new()
	_tlp_state.text = "Fase: --"
	_tlp_state.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_tlp_state)

	vbox.add_child(HSeparator.new())

	var override_lbl := Label.new()
	override_lbl.text = "Override:"
	override_lbl.add_theme_font_size_override("font_size", 11)
	override_lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	vbox.add_child(override_lbl)

	var ov_row := HBoxContainer.new()
	ov_row.add_theme_constant_override("separation", 3)
	vbox.add_child(ov_row)

	_tlp_override_green = _make_btn("🟢")
	_tlp_override_green.add_theme_color_override("font_color", Config.TLColors.GREEN)
	_tlp_override_green.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tlp_override_green.pressed.connect(func() -> void: _tl_node_override("green"))
	ov_row.add_child(_tlp_override_green)

	_tlp_override_yellow = _make_btn("🟡")
	_tlp_override_yellow.add_theme_color_override("font_color", Config.TLColors.YELLOW)
	_tlp_override_yellow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tlp_override_yellow.pressed.connect(func() -> void: _tl_node_override("yellow"))
	ov_row.add_child(_tlp_override_yellow)

	_tlp_override_red = _make_btn("🔴")
	_tlp_override_red.add_theme_color_override("font_color", Config.TLColors.RED)
	_tlp_override_red.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tlp_override_red.pressed.connect(func() -> void: _tl_node_override("red"))
	ov_row.add_child(_tlp_override_red)

	_tlp_override_auto = _make_btn("🔄")
	_tlp_override_auto.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tlp_override_auto.pressed.connect(func() -> void: _tl_node_override("auto"))
	ov_row.add_child(_tlp_override_auto)

	return vbox


# ── Signal connections ────────────────────────────────────────────────────────

func _connect_signals() -> void:
	SimulationStateManager.state_changed.connect(_on_sim_state_changed)
	VehicleManager.vehicle_removed.connect(_on_vehicle_removed)
	TrafficLightManager.traffic_light_updated.connect(_on_tl_updated)

	# Map loading feedback (IPO #1: visibility of system status)
	NetworkManager.loading_started.connect(_on_map_loading_started)
	NetworkManager.loading_progress.connect(_on_map_loading_progress)
	NetworkManager.loading_completed.connect(_on_map_loading_completed)
	NetworkManager.loading_failed.connect(_on_map_loading_failed)

	# Collision live updates (Phase 3 TFG): the backend broadcasts
	# MSG_TYPE_VEHICLE_COLLISION on impact; we surface it in the "Colisiones"
	# tab and let the operator retire the vehicle via a per-row button.
	SimulationClient.vehicle_collision.connect(_on_vehicle_collision)
	SimulationClient.vehicle_finished.connect(_on_collision_cleared)


# ── Map loading status ────────────────────────────────────────────────────────

func _on_map_loading_started() -> void:
	if is_instance_valid(_lbl_map_status):
		_lbl_map_status.text = "Cargando red desde el backend…"
		_lbl_map_status.add_theme_color_override("font_color", Config.UI.WARNING_COLOR)
	if is_instance_valid(_reload_map_btn):
		_reload_map_btn.disabled = true
		_reload_map_btn.text = "⏳  Cargando…"
	_dot.color = Config.UI.WARNING_COLOR


func _on_map_loading_progress(progress: float, message: String) -> void:
	if is_instance_valid(_lbl_map_status):
		_lbl_map_status.text = "Cargando %.0f%% — %s" % [progress * 100.0, message]


func _on_map_loading_completed(_network: RoadNetwork) -> void:
	if is_instance_valid(_lbl_map_status):
		_lbl_map_status.text = "Mapa cargado ✓"
		_lbl_map_status.add_theme_color_override("font_color", Config.UI.SUCCESS_COLOR)
	if is_instance_valid(_reload_map_btn):
		_reload_map_btn.disabled = false
		_reload_map_btn.text = "🗺  Recargar mapa"


func _on_map_loading_failed(error: String) -> void:
	if is_instance_valid(_lbl_map_status):
		_lbl_map_status.text = "Error: %s\n(¿backend arrancado en %s?)" % [error, Config.base_url]
		_lbl_map_status.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	if is_instance_valid(_reload_map_btn):
		_reload_map_btn.disabled = false
		_reload_map_btn.text = "🔁  Reintentar"
	_dot.color = Config.UI.ERROR_COLOR


# ── TopBar refresh ────────────────────────────────────────────────────────────

func _refresh_topbar() -> void:
	var state := SimulationStateManager.current_state
	_state_lbl.text = state.to_upper()

	match state:
		"running": _dot.color = Config.UI.SUCCESS_COLOR
		"paused":  _dot.color = Config.UI.WARNING_COLOR
		_:         _dot.color = Config.UI.TEXT_SECONDARY_COLOR

	var sim_s := SimulationStateManager.simulation_time
	var mm := int(sim_s / 60.0)
	var ss := int(sim_s) % 60
	_simtime_lbl.text = "T: %02d:%02d" % [mm, ss]
	_vcount_lbl.text  = "Veh: %d" % VehicleManager.get_vehicle_count()
	_fps_lbl.text     = "%d FPS" % int(Engine.get_frames_per_second())


# ── VehiclePanel refresh ──────────────────────────────────────────────────────

func _refresh_vehicle_panel(state: Dictionary) -> void:
	if state.is_empty():
		return
	var status: String = state.get("status", "")
	var speed_ms: float = state.get("v", 0.0)
	var heading: float = state.get("h", 0.0)
	var lon: float = state.get("lon", 0.0)
	var lat: float = state.get("lat", 0.0)
	var edge_idx: int = state.get("edge_idx", 0)
	var progress: float = state.get("progress", 0.0)

	_vp_status.text  = "Estado: %s" % status
	_vp_speed.text   = "Vel: %.1f km/h" % (speed_ms * Config.Physics.MS_TO_KMH)
	_vp_heading.text = "Dir: %.0f°" % heading
	_vp_gps.text     = "GPS: %.4f°N, %.4f°E" % [lat, lon]
	_vp_edge.text    = "Arista: %d  Prog: %.0f%%" % [edge_idx, progress * 100.0]

	match status:
		"paused":
			_vp_pause_btn.text = "▶ Reanudar"
		_:
			_vp_pause_btn.text = "✋ Parar"


# ── Tab logic ─────────────────────────────────────────────────────────────────

func _on_tab_pressed(idx: int) -> void:
	if _active_tab == idx:
		# Toggle off: close
		_set_tab(-1)
	else:
		_set_tab(idx)


func _set_tab(idx: int) -> void:
	_active_tab = idx
	_map_tab_open = (idx == 2)   # tab index 2 = Mapa
	for i in range(TAB_COUNT):
		_tab_panels[i].visible = (i == idx)
		_apply_tab_button_style(_tab_btns[i], i == idx)

	_tab_content.visible = (idx >= 0)
	if idx >= 0:
		# Adaptive height: Mapa needs more room (stats), others are compact
		var tab_h: float = 360.0 if idx == 2 else 240.0
		_tab_content.offset_top = -(TAB_BAR_HEIGHT + tab_h)


# ── Right panel slide ─────────────────────────────────────────────────────────

func _show_right_panel(visible_flag: bool) -> void:
	if visible_flag == _right_visible:
		return
	_right_visible = visible_flag
	_right_panel.visible = true

	if _right_tween:
		_right_tween.kill()

	var target_left: float
	var target_right: float
	if visible_flag:
		target_left  = -(RIGHT_PANEL_WIDTH + 8.0)
		target_right = -8.0
	else:
		target_left  = 0.0
		target_right = RIGHT_PANEL_WIDTH

	_right_tween = create_tween()
	_right_tween.set_ease(Tween.EASE_OUT)
	_right_tween.set_trans(Tween.TRANS_CUBIC)
	_right_tween.tween_property(_right_panel, "offset_left",  target_left,  RIGHT_ANIM_TIME)
	_right_tween.parallel().tween_property(_right_panel, "offset_right", target_right, RIGHT_ANIM_TIME)
	if not visible_flag:
		_right_tween.tween_callback(func() -> void: _right_panel.visible = false)


# ── Simulation control ────────────────────────────────────────────────────────

func _sim_post(endpoint: String) -> void:
	if _request_in_flight:
		return
	_request_in_flight = true
	var _result := await _http.post_request(endpoint, {})
	_request_in_flight = false


func _on_pause_resume() -> void:
	if SimulationStateManager.is_paused():
		_sim_post("/simulation/resume")
		_pause_btn.text = "⏸ Pausar"
	else:
		_sim_post("/simulation/pause")
		_pause_btn.text = "▶ Reanudar"


func _on_spawn_vehicles() -> void:
	var count := int(_spawn_count.value)
	var _r := await _http.post_request("/simulation/vehicles/spawn", {"count": count})


func _on_auto_spawn_toggled(pressed: bool) -> void:
	var rate := float(_auto_spawn_rate.value)
	var body: Dictionary = {"auto_spawn": pressed}
	if pressed:
		body["spawn_rate"] = rate
	var _r := await _http.put_request("/simulation/config", body)


# ── TL control ────────────────────────────────────────────────────────────────

func _tl_post(endpoint: String) -> void:
	if _request_in_flight:
		return
	_request_in_flight = true
	var result: HTTPResult = await _http.post_request(
		"/simulation/traffic-lights/" + endpoint, {}
	)
	_request_in_flight = false
	if result.success and result.data.has("mode"):
		pass  # mode visible via sim state


func _tl_node_override(phase: String) -> void:
	if _selected_node < 0:
		return
	if phase == "auto":
		# clear individual override — not yet in API, use per-node future endpoint
		return
	var ep := "/simulation/traffic-lights/node/%d/%s" % [_selected_node, phase]
	var _r := await _http.post_request(ep, {})


# ── Vehicle control ───────────────────────────────────────────────────────────

func _on_follow_toggle() -> void:
	if _following:
		_stop_following()
	else:
		_start_following()


func _start_following() -> void:
	if _selected_vehicle.is_empty():
		return
	_following = true
	_vp_follow_btn.text = "🛑 Dejar seguir"
	follow_vehicle_requested.emit(_selected_vehicle)


func _stop_following() -> void:
	_following = false
	_vp_follow_btn.text = "📷 Seguir"
	unfollow_requested.emit()


func _on_vehicle_pause_toggle() -> void:
	if _selected_vehicle.is_empty():
		return
	var state := VehicleManager.get_vehicle(_selected_vehicle)
	if state.is_empty():
		return
	if state.get("status", "") == "paused":
		var _r := await _http.post_request(
			"/simulation/vehicles/%s/resume" % _selected_vehicle, {}
		)
	else:
		var _r := await _http.post_request(
			"/simulation/vehicles/%s/pause" % _selected_vehicle, {}
		)


func _on_vehicle_speed_changed(value: float) -> void:
	_vp_speed_val.text = "%.0f km/h" % value
	if _selected_vehicle.is_empty():
		return
	var _r := await _http.post_request(
		"/simulation/vehicles/%s/speed" % _selected_vehicle,
		{"desired_speed_kmh": value}
	)


func _on_reroute_start() -> void:
	_reroute_mode = true
	# The next click on the map (handled by test_node_renderer) will call
	# set_reroute_target(node_id) on this HUD.


func set_reroute_target(node_id: int) -> void:
	if not _reroute_mode or _selected_vehicle.is_empty():
		return
	_reroute_mode = false
	var _r := await _http.post_request(
		"/simulation/vehicles/%s/reroute" % _selected_vehicle,
		{"end_node_id": node_id}
	)


func _on_delete_vehicle() -> void:
	if _selected_vehicle.is_empty():
		return
	var vid := _selected_vehicle
	close_right_panel()
	var _r := await _http.delete_request(
		"/simulation/vehicles/%s" % vid
	)


# ── TL tab management ─────────────────────────────────────────────────────────

func _on_tl_updated(node_id: int, phase: String) -> void:
	_update_tl_indicator(node_id, phase)
	_update_tl_summary()
	if _selected_node == node_id:
		_tlp_state.text = "Fase: %s" % phase


func _update_tl_indicator(node_id: int, phase: String) -> void:
	var empty := _tl_list_vbox.get_node_or_null("EmptyLabel")
	if empty:
		_tl_list_vbox.remove_child(empty)
		empty.queue_free()

	if _tl_indicators.has(node_id):
		(_tl_indicators[node_id] as ColorRect).color = _tl_color(phase)
		return

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)

	var dot_wrap := MarginContainer.new()
	dot_wrap.add_theme_constant_override("margin_top", 3)
	row.add_child(dot_wrap)

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.color = _tl_color(phase)
	dot_wrap.add_child(dot)

	var lbl := Label.new()
	lbl.text = "#%d" % node_id
	lbl.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	# Click to select this TL in the right panel
	var btn := Button.new()
	btn.text = "ℹ"
	btn.flat = true
	btn.custom_minimum_size = Vector2(20, 18)
	btn.pressed.connect(func() -> void: show_node_info(node_id, "traffic_light"))
	row.add_child(btn)

	_tl_list_vbox.add_child(row)
	_tl_indicators[node_id] = dot


func _update_tl_summary() -> void:
	# Estructura nueva: {node_id: {edge_key: phase}} — contamos POR ARISTA,
	# así un cruce con N-S verde y E-O rojo aporta 2 verdes y 2 rojos al total.
	var lights: Dictionary = TrafficLightManager.traffic_lights
	var g := 0; var y := 0; var r := 0
	for edges_dict in lights.values():
		if typeof(edges_dict) != TYPE_DICTIONARY:
			continue
		for phase in edges_dict.values():
			match String(phase):
				"green":  g += 1
				"yellow": y += 1
				"red":    r += 1
	_tl_summary_lbl.text = "G:%d  Y:%d  R:%d" % [g, y, r]


func _tl_color(phase: String) -> Color:
	match phase:
		"green":  return Config.TLColors.GREEN
		"yellow": return Config.TLColors.YELLOW
		"red":    return Config.TLColors.RED
	return Config.TLColors.UNKNOWN


# ── Simulation state changes ──────────────────────────────────────────────────

func _on_sim_state_changed(new_state: String, _old_state: String) -> void:
	if _sim_state_lbl:
		_sim_state_lbl.text = "Estado: %s" % new_state
	if new_state == "paused" and _pause_btn:
		_pause_btn.text = "▶ Reanudar"
	elif _pause_btn:
		_pause_btn.text = "⏸ Pausar"


func _on_vehicle_removed(vehicle_id: String) -> void:
	if _selected_vehicle == vehicle_id:
		close_right_panel()


# ── Collision management (Phase 3 TFG) ────────────────────────────────────────

func _on_vehicle_collision(vid1: String, vid2: String, edge: Array) -> void:
	var partners := {vid1: vid2, vid2: vid1}
	for vid in partners.keys():
		if _collisions.has(vid):
			continue
		_collisions[vid] = {
			"partner_id": partners[vid],
			"edge": edge.duplicate(),
			"sim_time": SimulationStateManager.simulation_time,
		}
		_add_collision_row(vid)
	_refresh_collision_summary()


func _on_collision_cleared(vehicle_id: String) -> void:
	# Called when the backend finally removes a vehicle. Mirrors the
	# collision dict so the Colisiones tab stays in sync even when a clear
	# was initiated from an API call we did not originate (e.g. another
	# operator session).
	if not _collisions.has(vehicle_id):
		return
	_collisions.erase(vehicle_id)
	var row: Control = _coll_rows.get(vehicle_id)
	if row:
		row.queue_free()
		_coll_rows.erase(vehicle_id)
	if _coll_list_vbox.get_child_count() == 0:
		var empty := Label.new()
		empty.name = "EmptyLabel"
		empty.text = "Sin colisiones activas."
		empty.add_theme_font_size_override("font_size", 10)
		empty.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
		_coll_list_vbox.add_child(empty)
	_refresh_collision_summary()


func _add_collision_row(vehicle_id: String) -> void:
	var empty := _coll_list_vbox.get_node_or_null("EmptyLabel")
	if empty:
		_coll_list_vbox.remove_child(empty)
		empty.queue_free()

	var info: Dictionary = _collisions.get(vehicle_id, {})
	var edge: Array = info.get("edge", [])
	var partner: String = info.get("partner_id", "")

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)

	var lbl := Label.new()
	var edge_txt: String = "--"
	if edge.size() >= 2:
		edge_txt = "%d→%d" % [int(edge[0]), int(edge[1])]
	lbl.text = "🚨 %s  (con %s) en %s" % [vehicle_id, partner, edge_txt]
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	row.add_child(lbl)

	var focus_btn := Button.new()
	focus_btn.text = "📷"
	focus_btn.tooltip_text = "Seleccionar y seguir el vehículo colisionado"
	focus_btn.flat = true
	focus_btn.custom_minimum_size = Vector2(24, 20)
	focus_btn.pressed.connect(func() -> void:
		var state := VehicleManager.get_vehicle(vehicle_id)
		if not state.is_empty():
			show_vehicle_info(vehicle_id, state)
			_start_following()
	)
	row.add_child(focus_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Retirar"
	clear_btn.tooltip_text = "Llamar POST /simulation/vehicles/%s/clear-collision" % vehicle_id
	clear_btn.add_theme_font_size_override("font_size", 10)
	clear_btn.pressed.connect(_clear_collision.bind(vehicle_id))
	row.add_child(clear_btn)

	_coll_list_vbox.add_child(row)
	_coll_rows[vehicle_id] = row


func _clear_collision(vehicle_id: String) -> void:
	var _r: HTTPResult = await _http.post_request(
		"/simulation/vehicles/%s/clear-collision" % vehicle_id, {}
	)
	# Optimistic removal — if the call fails (e.g. the backend already cleared
	# it) we'll resync on the next vehicle_finished broadcast.
	_on_collision_cleared(vehicle_id)


func _refresh_collision_summary() -> void:
	if not is_instance_valid(_coll_summary_lbl):
		return
	var n := _collisions.size()
	_coll_summary_lbl.text = "Colisiones activas: %d" % n
	var color := Config.UI.ERROR_COLOR if n > 0 else Config.UI.TEXT_SECONDARY_COLOR
	_coll_summary_lbl.add_theme_color_override("font_color", color)


func _refresh_collisions() -> void:
	# Resync from the server: GET /simulation/collisions. Replaces the local
	# cache so late-joining operators see everything.
	var result: HTTPResult = await _http.get_request("/simulation/collisions")
	if not result.success:
		return
	# Wipe current rows
	for vid in _collisions.keys():
		var row: Control = _coll_rows.get(vid)
		if row:
			row.queue_free()
	_collisions.clear()
	_coll_rows.clear()

	var items: Array = []
	if typeof(result.data) == TYPE_DICTIONARY and result.data.has("collisions"):
		items = result.data["collisions"]
	elif typeof(result.data) == TYPE_ARRAY:
		items = result.data

	for item: Dictionary in items:
		var vid := JsonUtils.get_string(item, "vehicle_id", "")
		if vid.is_empty():
			continue
		_collisions[vid] = {
			"partner_id": JsonUtils.get_string(item, "partner_id", ""),
			"edge": JsonUtils.get_array(item, "edge", []),
			"sim_time": JsonUtils.get_float(item, "sim_time", 0.0),
		}
		_add_collision_row(vid)
	_refresh_collision_summary()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_top_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


func _make_info_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	return lbl


func _make_btn(text: String, tooltip: String = "", primary: bool = false) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(0, Config.UI.BUTTON_HEIGHT)
	btn.add_theme_font_size_override("font_size", 11)
	_apply_button_style(btn, primary)
	return btn


func _make_section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	return lbl


func _make_chrome_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = true
	btn.custom_minimum_size = Vector2(22, 20)
	btn.add_theme_font_size_override("font_size", 12)
	return btn


# ── StyleBox factories (light theme) ─────────────────────────────────────────

func _make_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Config.UI.BACKGROUND_COLOR
	sb.border_color = Config.UI.PANEL_BORDER_COLOR
	sb.border_width_left   = 1
	sb.border_width_right  = 1
	sb.border_width_top    = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left     = Config.UI.PANEL_CORNER_RADIUS
	sb.corner_radius_top_right    = Config.UI.PANEL_CORNER_RADIUS
	sb.corner_radius_bottom_left  = Config.UI.PANEL_CORNER_RADIUS
	sb.corner_radius_bottom_right = Config.UI.PANEL_CORNER_RADIUS
	sb.shadow_color = Config.UI.PANEL_SHADOW_COLOR
	sb.shadow_size = 4
	sb.content_margin_left   = Config.UI.PANEL_CONTENT_MARGIN
	sb.content_margin_right  = Config.UI.PANEL_CONTENT_MARGIN
	sb.content_margin_top    = Config.UI.PANEL_VERTICAL_MARGIN
	sb.content_margin_bottom = Config.UI.PANEL_VERTICAL_MARGIN
	return sb


func _apply_panel_style(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", _make_panel_style())


func _make_button_stylebox(bg: Color, border: Color, border_width: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left   = border_width
	sb.border_width_right  = border_width
	sb.border_width_top    = border_width
	sb.border_width_bottom = border_width
	sb.corner_radius_top_left     = Config.UI.BUTTON_CORNER_RADIUS
	sb.corner_radius_top_right    = Config.UI.BUTTON_CORNER_RADIUS
	sb.corner_radius_bottom_left  = Config.UI.BUTTON_CORNER_RADIUS
	sb.corner_radius_bottom_right = Config.UI.BUTTON_CORNER_RADIUS
	sb.content_margin_left   = 10
	sb.content_margin_right  = 10
	sb.content_margin_top    = 4
	sb.content_margin_bottom = 4
	return sb


func _apply_button_style(btn: Button, primary: bool = false) -> void:
	var normal: StyleBoxFlat
	var hover: StyleBoxFlat
	var pressed: StyleBoxFlat
	var disabled: StyleBoxFlat
	var text_normal: Color
	var text_hover: Color
	var text_pressed: Color

	if primary:
		normal   = _make_button_stylebox(Config.UI.ACCENT_COLOR,   Config.UI.ACCENT_PRESSED)
		hover    = _make_button_stylebox(Config.UI.ACCENT_HOVER,   Config.UI.ACCENT_PRESSED)
		pressed  = _make_button_stylebox(Config.UI.ACCENT_PRESSED, Config.UI.ACCENT_PRESSED)
		disabled = _make_button_stylebox(Config.UI.BUTTON_DISABLED_COLOR, Config.UI.SEPARATOR_COLOR)
		text_normal  = Color.WHITE
		text_hover   = Color.WHITE
		text_pressed = Color.WHITE
	else:
		normal   = _make_button_stylebox(Config.UI.BUTTON_NORMAL_COLOR,   Config.UI.PANEL_BORDER_COLOR)
		hover    = _make_button_stylebox(Config.UI.BUTTON_HOVER_COLOR,    Config.UI.ACCENT_COLOR)
		pressed  = _make_button_stylebox(Config.UI.BUTTON_PRESSED_COLOR,  Config.UI.ACCENT_PRESSED)
		disabled = _make_button_stylebox(Config.UI.BUTTON_DISABLED_COLOR, Config.UI.SEPARATOR_COLOR)
		text_normal  = Config.UI.TEXT_COLOR
		text_hover   = Config.UI.ACCENT_PRESSED
		text_pressed = Config.UI.ACCENT_PRESSED

	btn.add_theme_stylebox_override("normal",   normal)
	btn.add_theme_stylebox_override("hover",    hover)
	btn.add_theme_stylebox_override("pressed",  pressed)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_color_override("font_color",          text_normal)
	btn.add_theme_color_override("font_hover_color",    text_hover)
	btn.add_theme_color_override("font_pressed_color",  text_pressed)
	btn.add_theme_color_override("font_disabled_color", Config.UI.TEXT_MUTED_COLOR)


func _apply_tab_button_style(btn: Button, active: bool) -> void:
	var bg := Config.UI.BACKGROUND_COLOR if active else Config.UI.BUTTON_NORMAL_COLOR
	var border_color := Config.UI.ACCENT_COLOR if active else Config.UI.PANEL_BORDER_COLOR
	var normal := StyleBoxFlat.new()
	normal.bg_color = bg
	normal.border_color = border_color
	normal.border_width_bottom = 3 if active else 1
	normal.border_width_top = 0
	normal.border_width_left = 0
	normal.border_width_right = 0
	normal.content_margin_left   = 8
	normal.content_margin_right  = 8
	normal.content_margin_top    = 6
	normal.content_margin_bottom = 6

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Config.UI.BUTTON_HOVER_COLOR
	hover.border_color = Config.UI.ACCENT_COLOR
	hover.border_width_bottom = 3

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Config.UI.BUTTON_PRESSED_COLOR
	pressed.border_color = Config.UI.ACCENT_PRESSED
	pressed.border_width_bottom = 3

	btn.add_theme_stylebox_override("normal",  normal)
	btn.add_theme_stylebox_override("hover",   hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_color_override("font_color",         Config.UI.ACCENT_COLOR if active else Config.UI.TEXT_SECONDARY_COLOR)
	btn.add_theme_color_override("font_hover_color",   Config.UI.ACCENT_PRESSED)
	btn.add_theme_color_override("font_pressed_color", Config.UI.ACCENT_PRESSED)


func is_reroute_mode() -> bool:
	return _reroute_mode


func cancel_reroute() -> void:
	_reroute_mode = false
