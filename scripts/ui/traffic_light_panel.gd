## TrafficLightPanel — Dedicated traffic light visualization and control panel.
##
## Shows the phase state (green/yellow/red) of every traffic light in the network
## as live coloured indicators, a summary counter, and the current override mode.
## Three control buttons let the user force all lights to green, all to red, or
## restore normal timed cycling via HTTP POST to the backend.
##
## Layer 124 — below SimControlPanel (125) and VehicleInfoPopup (126).
## Positioned on the right side of the screen, below SimControlPanel.
##
## Uses its own private HTTPClient2 so it never blocks NetworkManager requests.
class_name TrafficLightPanel
extends CanvasLayer


## Width of the panel in pixels
const PANEL_WIDTH: float = 210.0

## Maximum height for the scrollable list (pixels)
const LIST_MAX_HEIGHT: float = 300.0


# ── Private HTTP client ────────────────────────────────────────────────────
var _http: HTTPClient2


# ── UI nodes ──────────────────────────────────────────────────────────────
var _panel        : PanelContainer
var _body         : VBoxContainer      # collapsible content
var _mode_label   : Label              # "Mode: Normal"
var _summary_label: Label              # "G:12  Y:3  R:6"
var _list_vbox    : VBoxContainer      # rows, one per TL node
var _chrome_min   : Button
var _chrome_max   : Button
var _chrome_close : Button
var _reopener     : Button             # shown when panel is closed

# node_id (int) → ColorRect (the phase indicator dot)
var _indicators: Dictionary = {}

# Runtime
var _is_minimized: bool = false
var _request_in_flight: bool = false


# ── Lifecycle ─────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 124

	_http = HTTPClient2.new(Config.api_url)
	add_child(_http)

	_build_ui()

	# Live phase updates from the WebSocket stream
	TrafficLightManager.traffic_light_updated.connect(_on_tl_updated)


# ── Build UI ─────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# ── Reopener button (shown when panel is closed) ───────────────────────
	_reopener = Button.new()
	_reopener.text = "TL"
	_reopener.tooltip_text = "Abrir panel de semáforos"
	_reopener.anchor_left   = 1.0
	_reopener.anchor_right  = 1.0
	_reopener.anchor_top    = 0.0
	_reopener.anchor_bottom = 0.0
	# position below SimControlPanel top offset; exact offset computed at runtime
	_reopener.offset_left   = -(PANEL_WIDTH + 8.0)
	_reopener.offset_right  = -(PANEL_WIDTH - 30.0 + 8.0)
	_reopener.offset_top    = 8.0
	_reopener.offset_bottom = 32.0
	_reopener.visible = false
	_reopener.pressed.connect(_on_reopen)
	add_child(_reopener)

	# ── Main panel container ───────────────────────────────────────────────
	_panel = PanelContainer.new()
	_panel.anchor_left   = 1.0
	_panel.anchor_right  = 1.0
	_panel.anchor_top    = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left   = -(PANEL_WIDTH + 8.0)
	_panel.offset_right  = -8.0
	# Stack below SimControlPanel: start 250px from top so they don't overlap
	_panel.offset_top    = 250.0
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",    8)
	margin.add_theme_constant_override("margin_right",   8)
	margin.add_theme_constant_override("margin_top",     6)
	margin.add_theme_constant_override("margin_bottom",  8)
	_panel.add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	margin.add_child(outer)

	# ── Title bar ─────────────────────────────────────────────────────────
	var title_bar := HBoxContainer.new()
	title_bar.add_theme_constant_override("separation", 2)
	outer.add_child(title_bar)

	var title := Label.new()
	title.text = "Traffic Lights"
	title.add_theme_color_override("font_color",    Config.UI.TEXT_COLOR)
	title.add_theme_font_size_override("font_size", 13)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(title)

	_chrome_min = _make_chrome_btn("─")
	_chrome_min.tooltip_text = "Minimizar"
	_chrome_min.pressed.connect(_on_minimize)
	title_bar.add_child(_chrome_min)

	_chrome_max = _make_chrome_btn("□")
	_chrome_max.tooltip_text = "Restaurar"
	_chrome_max.disabled = true
	_chrome_max.pressed.connect(_on_maximize)
	title_bar.add_child(_chrome_max)

	_chrome_close = _make_chrome_btn("×")
	_chrome_close.tooltip_text = "Cerrar"
	_chrome_close.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	_chrome_close.pressed.connect(_on_close)
	title_bar.add_child(_chrome_close)

	outer.add_child(HSeparator.new())

	# ── Collapsible body ──────────────────────────────────────────────────
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 5)
	outer.add_child(_body)

	# ── Mode row ──────────────────────────────────────────────────────────
	_mode_label = Label.new()
	_mode_label.text = "Modo: normal"
	_mode_label.add_theme_color_override("font_color",   Config.UI.TEXT_SECONDARY_COLOR)
	_mode_label.add_theme_font_size_override("font_size", 11)
	_body.add_child(_mode_label)

	# ── Summary ───────────────────────────────────────────────────────────
	_summary_label = Label.new()
	_summary_label.text = "G:0  Y:0  R:0"
	_summary_label.add_theme_color_override("font_color",   Config.UI.TEXT_COLOR)
	_summary_label.add_theme_font_size_override("font_size", 12)
	_body.add_child(_summary_label)

	_body.add_child(HSeparator.new())

	# ── Scrollable list of individual TL indicators ───────────────────────
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode  = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode    = ScrollContainer.SCROLL_MODE_AUTO
	scroll.custom_minimum_size     = Vector2(0.0, 80.0)
	scroll.size_flags_vertical     = Control.SIZE_EXPAND_FILL
	_body.add_child(scroll)

	_list_vbox = VBoxContainer.new()
	_list_vbox.add_theme_constant_override("separation", 3)
	_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_vbox)

	var empty_lbl := Label.new()
	empty_lbl.name = "EmptyLabel"
	empty_lbl.text = "Sin datos (¿simulación iniciada?)"
	empty_lbl.add_theme_color_override("font_color",   Config.UI.TEXT_SECONDARY_COLOR)
	empty_lbl.add_theme_font_size_override("font_size", 10)
	empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	_list_vbox.add_child(empty_lbl)

	_body.add_child(HSeparator.new())

	# ── Control buttons ───────────────────────────────────────────────────
	var ctrl_lbl := Label.new()
	ctrl_lbl.text = "Control global:"
	ctrl_lbl.add_theme_color_override("font_color",   Config.UI.TEXT_SECONDARY_COLOR)
	ctrl_lbl.add_theme_font_size_override("font_size", 11)
	_body.add_child(ctrl_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	_body.add_child(btn_row)

	var btn_green := Button.new()
	btn_green.text = "Verde"
	btn_green.tooltip_text = "Forzar todos los semáforos en verde"
	btn_green.add_theme_color_override("font_color", Color(0.2, 0.9, 0.2))
	btn_green.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_green.pressed.connect(func() -> void: _post_override("all-green"))
	btn_row.add_child(btn_green)

	var btn_red := Button.new()
	btn_red.text = "Rojo"
	btn_red.tooltip_text = "Forzar todos los semáforos en rojo"
	btn_red.add_theme_color_override("font_color", Config.UI.ERROR_COLOR)
	btn_red.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_red.pressed.connect(func() -> void: _post_override("all-red"))
	btn_row.add_child(btn_red)

	var btn_normal := Button.new()
	btn_normal.text = "Normal"
	btn_normal.tooltip_text = "Volver al ciclo automático"
	btn_normal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_normal.pressed.connect(func() -> void: _post_override("normal"))
	_body.add_child(btn_normal)


# ── Signal handlers ───────────────────────────────────────────────────────

func _on_tl_updated(node_id: int, phase: String) -> void:
	_update_indicator(node_id, phase)
	_update_summary()


# ── Indicator management ──────────────────────────────────────────────────

func _update_indicator(node_id: int, phase: String) -> void:
	# Remove placeholder "empty" label once first data arrives
	var empty := _list_vbox.get_node_or_null("EmptyLabel") as Label
	if empty:
		_list_vbox.remove_child(empty)
		empty.queue_free()

	if _indicators.has(node_id):
		var dot: ColorRect = _indicators[node_id]
		dot.color = _phase_color(phase)
		return

	# Build new row: [ColorRect] [Label "#node_id  PHASE"]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var dot_wrap := MarginContainer.new()
	dot_wrap.add_theme_constant_override("margin_top", 3)
	row.add_child(dot_wrap)

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.color = _phase_color(phase)
	dot_wrap.add_child(dot)

	var lbl := Label.new()
	lbl.text = "#%d" % node_id
	lbl.add_theme_color_override("font_color",   Config.UI.TEXT_COLOR)
	lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(lbl)

	_list_vbox.add_child(row)
	_indicators[node_id] = dot


func _update_summary() -> void:
	var lights: Dictionary = TrafficLightManager.traffic_lights
	var g := 0
	var y := 0
	var r := 0
	for phase: String in lights.values():
		match phase:
			"green":  g += 1
			"yellow": y += 1
			"red":    r += 1
	_summary_label.text = "G:%d  Y:%d  R:%d" % [g, y, r]


func _phase_color(phase: String) -> Color:
	match phase:
		"green":  return Color(0.0, 0.85, 0.0)
		"yellow": return Color(1.0, 0.85, 0.0)
		"red":    return Color(0.9, 0.1, 0.1)
	return Color(0.5, 0.5, 0.5)


# ── HTTP control ──────────────────────────────────────────────────────────

func _post_override(endpoint: String) -> void:
	if _request_in_flight:
		return
	_request_in_flight = true
	var ep := "/simulation/traffic-lights/" + endpoint
	var result: HTTPResult = await _http.post_request(ep, {})
	_request_in_flight = false

	if result.success and result.data.has("mode"):
		_mode_label.text = "Modo: %s" % str(result.data["mode"])


# ── Chrome callbacks ──────────────────────────────────────────────────────

func _on_minimize() -> void:
	_is_minimized = true
	_body.visible  = false
	_chrome_min.disabled = true
	_chrome_max.disabled = false


func _on_maximize() -> void:
	_is_minimized = false
	_body.visible  = true
	_chrome_min.disabled = false
	_chrome_max.disabled = true


func _on_close() -> void:
	_panel.visible   = false
	_reopener.visible = true


func _on_reopen() -> void:
	_panel.visible   = true
	_reopener.visible = false


# ── Helpers ───────────────────────────────────────────────────────────────

func _make_chrome_btn(label_text: String) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.flat = true
	btn.custom_minimum_size = Vector2(22, 20)
	btn.add_theme_font_size_override("font_size", 12)
	return btn
