## SimControlPanel — Simulation control overlay panel.
##
## Provides Start / Stop / Pause-Resume buttons (HTTP POST to API),
## a manual vehicle spawn control, and a live stats display fed by
## the analytics_update WebSocket messages, VehicleManager, and
## SimulationStateManager.
##
## Add this node (or its scene) to any 3D simulation scene.
## It is a CanvasLayer so it always renders above the 3D content.
##
## HTTP: uses its own private HTTPClient2 instance so it never blocks
##       NetworkManager's map-loading requests.
##
## Layer 125  (below VehicleInfoPopup=126, below ConnectionIndicator=127)
class_name SimControlPanel
extends CanvasLayer


## Fixed panel width in pixels
const PANEL_WIDTH: float = 210.0

## Seconds between stats / sim-time refresh
const REFRESH_INTERVAL: float = 0.5


# ── Private HTTP client ───────────────────────────────────────────────────
## Owns its own HTTPClient2 so requests never queue behind NetworkManager.
var _http: HTTPClient2


# ── UI nodes ─────────────────────────────────────────────────────────────
var _panel        : PanelContainer
var _body         : VBoxContainer   # collapsible body content
var _state_dot    : ColorRect
var _state_label  : Label
var _time_label   : Label
var _start_btn    : Button
var _stop_btn     : Button
var _pause_btn    : Button          # doubles as Resume
var _spawn_count  : SpinBox
var _spawn_btn    : Button
var _stats_label  : Label
var _chrome_min   : Button          # minimize (collapse body)
var _chrome_max   : Button          # maximize  (restore body)
var _chrome_close : Button          # close (hide panel)
var _reopener     : Button          # shown when panel is closed


# ── Runtime state ─────────────────────────────────────────────────────────
var _request_in_flight: bool = false
var _refresh_timer    : float = 0.0
var _is_minimized     : bool = false


# ── Lifecycle ─────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 125

	_http = HTTPClient2.new(Config.api_url)
	add_child(_http)

	_build_ui()
	_connect_signals()

	# Initialise display from current autoload state
	var s := SimulationStateManager.current_state
	_update_state_indicator(s)
	_update_button_states(s)
	_update_sim_time()
	_update_stats()

	_log_info("SimControlPanel ready")


# ── Per-frame refresh ─────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_refresh_timer += delta
	if _refresh_timer >= REFRESH_INTERVAL:
		_refresh_timer = 0.0
		_update_sim_time()
		_update_stats()


# ── Build UI ─────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# ── Main panel ────────────────────────────────────────────────────────
	_panel = PanelContainer.new()
	_panel.anchor_left   = 1.0
	_panel.anchor_right  = 1.0
	_panel.anchor_top    = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left   = -(PANEL_WIDTH + 8.0)
	_panel.offset_right  = -8.0
	_panel.offset_top    = 8.0
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	add_child(_panel)

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left",   10)
	outer.add_theme_constant_override("margin_right",  10)
	outer.add_theme_constant_override("margin_top",     6)
	outer.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(outer)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	outer.add_child(vbox)

	# ── Title bar with chrome buttons ─────────────────────────────────────
	var title_bar := HBoxContainer.new()
	title_bar.add_theme_constant_override("separation", 2)
	vbox.add_child(title_bar)

	var title := Label.new()
	title.text = "Simulation Control"
	title.add_theme_color_override("font_color",    Config.UI.TEXT_COLOR)
	title.add_theme_font_size_override("font_size", 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(title)

	_chrome_min = _make_chrome_btn("─")
	_chrome_min.tooltip_text = "Minimizar"
	_chrome_min.pressed.connect(_on_chrome_minimize)
	title_bar.add_child(_chrome_min)

	_chrome_max = _make_chrome_btn("□")
	_chrome_max.tooltip_text = "Restaurar"
	_chrome_max.disabled = true
	_chrome_max.pressed.connect(_on_chrome_maximize)
	title_bar.add_child(_chrome_max)

	_chrome_close = _make_chrome_btn("×")
	_chrome_close.tooltip_text = "Cerrar"
	_chrome_close.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	_chrome_close.pressed.connect(_on_chrome_close)
	title_bar.add_child(_chrome_close)

	vbox.add_child(HSeparator.new())

	# ── Collapsible body ──────────────────────────────────────────────────
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 5)
	vbox.add_child(_body)

	# ── State indicator ────────────────────────────────────────────────────
	var state_row := HBoxContainer.new()
	state_row.add_theme_constant_override("separation", 6)
	_body.add_child(state_row)

	var dot_wrap := MarginContainer.new()
	dot_wrap.add_theme_constant_override("margin_top", 3)
	state_row.add_child(dot_wrap)

	_state_dot = ColorRect.new()
	_state_dot.custom_minimum_size = Vector2(12, 12)
	_state_dot.color = Color(0.5, 0.5, 0.5)
	dot_wrap.add_child(_state_dot)

	_state_label = Label.new()
	_state_label.text = "Unknown"
	_state_label.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	state_row.add_child(_state_label)

	# ── Simulation time ────────────────────────────────────────────────────
	_time_label = Label.new()
	_time_label.text = "Time: --:--"
	_time_label.add_theme_color_override("font_color",   Config.UI.TEXT_SECONDARY_COLOR)
	_time_label.add_theme_font_size_override("font_size", 11)
	_body.add_child(_time_label)

	_body.add_child(HSeparator.new())

	# ── Control buttons ────────────────────────────────────────────────────
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 4)
	_body.add_child(row1)

	_start_btn = _make_btn("Start", Config.UI.SUCCESS_COLOR)
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_btn.pressed.connect(_on_start_pressed)
	row1.add_child(_start_btn)

	_stop_btn = _make_btn("Stop", Config.UI.ERROR_COLOR)
	_stop_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stop_btn.pressed.connect(_on_stop_pressed)
	row1.add_child(_stop_btn)

	_pause_btn = _make_btn("Pause", Config.UI.WARNING_COLOR)
	_pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pause_btn.pressed.connect(_on_pause_pressed)
	_body.add_child(_pause_btn)

	_body.add_child(HSeparator.new())

	# ── Spawn section ──────────────────────────────────────────────────────
	var spawn_hdr := Label.new()
	spawn_hdr.text = "Manual Spawn"
	spawn_hdr.add_theme_color_override("font_color",   Config.UI.TEXT_SECONDARY_COLOR)
	spawn_hdr.add_theme_font_size_override("font_size", 11)
	_body.add_child(spawn_hdr)

	var spawn_row := HBoxContainer.new()
	spawn_row.add_theme_constant_override("separation", 4)
	_body.add_child(spawn_row)

	var count_lbl := Label.new()
	count_lbl.text = "Count:"
	count_lbl.add_theme_color_override("font_color",   Config.UI.TEXT_SECONDARY_COLOR)
	count_lbl.add_theme_font_size_override("font_size", 11)
	spawn_row.add_child(count_lbl)

	_spawn_count = SpinBox.new()
	_spawn_count.min_value             = 1
	_spawn_count.max_value             = 10000
	_spawn_count.value                 = 100
	_spawn_count.step                  = 1
	_spawn_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spawn_row.add_child(_spawn_count)

	_spawn_btn = _make_btn("Spawn", Config.UI.ACCENT_COLOR)
	_spawn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spawn_btn.pressed.connect(_on_spawn_pressed)
	_body.add_child(_spawn_btn)

	_body.add_child(HSeparator.new())

	# ── Stats section ──────────────────────────────────────────────────────
	var stats_hdr := Label.new()
	stats_hdr.text = "Stats"
	stats_hdr.add_theme_color_override("font_color",   Config.UI.TEXT_SECONDARY_COLOR)
	stats_hdr.add_theme_font_size_override("font_size", 11)
	_body.add_child(stats_hdr)

	_stats_label = Label.new()
	_stats_label.text          = "—"
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_label.custom_minimum_size = Vector2(PANEL_WIDTH - 20.0, 0.0)
	_stats_label.add_theme_color_override("font_color",   Config.UI.TEXT_SECONDARY_COLOR)
	_stats_label.add_theme_font_size_override("font_size", 11)
	_body.add_child(_stats_label)

	# ── Reopener button (shown when panel is closed) ───────────────────────
	_reopener = Button.new()
	_reopener.text         = "⚙"
	_reopener.tooltip_text = "Abrir panel de simulación"
	_reopener.anchor_left   = 1.0
	_reopener.anchor_right  = 1.0
	_reopener.anchor_top    = 0.0
	_reopener.anchor_bottom = 0.0
	_reopener.offset_left   = -36.0
	_reopener.offset_right  = -8.0
	_reopener.offset_top    = 8.0
	_reopener.offset_bottom = 36.0
	_reopener.visible = false
	_reopener.pressed.connect(_on_chrome_reopen)
	add_child(_reopener)


## Create a small flat button for the window chrome.
func _make_chrome_btn(icon: String) -> Button:
	var btn := Button.new()
	btn.text = icon
	btn.flat = true
	btn.custom_minimum_size = Vector2(22, 20)
	btn.add_theme_font_size_override("font_size", 12)
	btn.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	return btn


## Helper: create a flat Button with a coloured label.
func _make_btn(label: String, font_color: Color) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(0, 26)
	btn.add_theme_color_override("font_color", font_color)
	return btn


# ── Chrome button handlers ────────────────────────────────────────────────

func _on_chrome_minimize() -> void:
	_is_minimized = true
	_body.visible = false
	_chrome_min.disabled = true
	_chrome_max.disabled = false


func _on_chrome_maximize() -> void:
	_is_minimized = false
	_body.visible = true
	_chrome_min.disabled = false
	_chrome_max.disabled = true


func _on_chrome_close() -> void:
	_panel.visible  = false
	_reopener.visible = true


func _on_chrome_reopen() -> void:
	_panel.visible  = true
	_reopener.visible = false
	# Always restore body when reopening
	if _is_minimized:
		_is_minimized = false
		_body.visible = true
		_chrome_min.disabled = false
		_chrome_max.disabled = true


# ── Signal wiring ─────────────────────────────────────────────────────────

func _connect_signals() -> void:
	SimulationStateManager.state_changed.connect(_on_state_changed)
	SimulationClient.connected.connect(_on_ws_connected)
	SimulationClient.disconnected.connect(_on_ws_disconnected)
	AnalyticsManager.analytics_updated.connect(_on_analytics_updated)


# ── Signal handlers ───────────────────────────────────────────────────────

func _on_state_changed(new_state: String, _old: String) -> void:
	_update_state_indicator(new_state)
	if not _request_in_flight:
		_update_button_states(new_state)


func _on_ws_connected() -> void:
	_update_button_states(SimulationStateManager.current_state)


func _on_ws_disconnected() -> void:
	_update_state_indicator(SimulationStateManager.STATE_UNKNOWN)
	_update_button_states(SimulationStateManager.STATE_UNKNOWN)


func _on_analytics_updated(_data: Dictionary) -> void:
	_update_stats()


# ── Display helpers ───────────────────────────────────────────────────────

func _update_state_indicator(state: String) -> void:
	match state:
		SimulationStateManager.STATE_RUNNING:
			_state_dot.color = Config.UI.SUCCESS_COLOR
			_state_label.text = "Running"
		SimulationStateManager.STATE_PAUSED:
			_state_dot.color = Config.UI.WARNING_COLOR
			_state_label.text = "Paused"
		SimulationStateManager.STATE_STOPPED:
			_state_dot.color = Config.UI.ERROR_COLOR
			_state_label.text = "Stopped"
		SimulationStateManager.STATE_IDLE:
			_state_dot.color = Config.UI.ERROR_COLOR
			_state_label.text = "Idle"
		_:
			var ws_ok := SimulationClient.connection_state == SimulationClient.ConnectionState.CONNECTED
			_state_dot.color = Color(0.5, 0.5, 0.5)
			_state_label.text = "Unknown" if ws_ok else "No WS"


func _update_button_states(state: String) -> void:
	if _request_in_flight:
		return
	var ws      := SimulationClient.connection_state == SimulationClient.ConnectionState.CONNECTED
	var running := state == SimulationStateManager.STATE_RUNNING
	var paused  := state == SimulationStateManager.STATE_PAUSED
	var active  := running or paused

	_start_btn.disabled = not (ws and SimulationStateManager.is_stopped())
	_stop_btn.disabled  = not (ws and active)
	_pause_btn.disabled = not (ws and active)
	_pause_btn.text     = "Resume" if paused else "Pause"
	_spawn_btn.disabled = not (ws and active)


func _update_sim_time() -> void:
	if SimulationStateManager.is_active():
		var s    := int(SimulationStateManager.simulation_time)
		var mins := s / 60
		var secs := s % 60
		_time_label.text = "Time: %02d:%02d" % [mins, secs]
	else:
		_time_label.text = "Time: --:--"


func _update_stats() -> void:
	var lines := PackedStringArray()

	lines.append("Vehicles: %d" % VehicleManager.get_vehicle_count())

	var tick_rate := SimulationClient.measured_tick_rate
	if tick_rate > 0.0:
		lines.append("Tick: %.1f/s" % tick_rate)

	# Append numeric analytics values reported by the backend
	var analytics := AnalyticsManager.latest
	for key: String in analytics:
		var val: Variant = analytics[key]
		if val is float:
			lines.append("%s: %.2f" % [key, val])
		elif val is int:
			lines.append("%s: %d" % [key, val])

	_stats_label.text = "\n".join(lines) if lines.size() > 0 else "—"


# ── Button handlers ───────────────────────────────────────────────────────

func _on_start_pressed() -> void:
	await _sim_command(Config.SimEndpoints.START)


func _on_stop_pressed() -> void:
	await _sim_command(Config.SimEndpoints.STOP)


func _on_pause_pressed() -> void:
	var ep := Config.SimEndpoints.RESUME \
		if SimulationStateManager.is_paused() \
		else Config.SimEndpoints.PAUSE
	await _sim_command(ep)


func _on_spawn_pressed() -> void:
	if _request_in_flight:
		return
	_request_in_flight = true
	_set_all_disabled(true)

	var count := int(_spawn_count.value)
	var result: HTTPResult = await _http.post_request(
		Config.SimEndpoints.VEHICLES_SPAWN, {"count": count})

	_request_in_flight = false
	_update_button_states(SimulationStateManager.current_state)

	if result.success:
		var requested: int = result.data.get("requested", count)
		_log_info("Spawning %d vehicles (background)..." % requested)
	else:
		_log_warning("Spawn failed: %s" % result.get_description())


## Send a simulation control command (start / stop / pause / resume).
func _sim_command(endpoint: String) -> void:
	if _request_in_flight:
		return
	_request_in_flight = true
	_set_all_disabled(true)

	var result: HTTPResult = await _http.post_request(endpoint)

	_request_in_flight = false
	_update_button_states(SimulationStateManager.current_state)

	if not result.success:
		_log_warning("Command '%s' failed: %s" % [endpoint, result.get_description()])


## Disable / enable all interactive buttons at once.
func _set_all_disabled(disabled: bool) -> void:
	_start_btn.disabled = disabled
	_stop_btn.disabled  = disabled
	_pause_btn.disabled = disabled
	_spawn_btn.disabled = disabled


# ── Logging ───────────────────────────────────────────────────────────────

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[SimControlPanel] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[SimControlPanel] %s" % message)
