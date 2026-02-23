## ConnectionIndicator — UI overlay widget
## Shows the WebSocket connection status as a colored dot + text label
## pinned to the top-right corner of the screen.
##
## Add this node (or its scene) to any scene that needs the indicator.
## It is a CanvasLayer so it always renders on top.
##
## States and colors:
##   Connected     →  green  dot  +  "Connected"
##   Connecting    →  yellow dot  +  "Connecting..."
##   Reconnecting  →  yellow dot  +  "Reconnecting (N)..."
##   Disconnected  →  red    dot  +  "Disconnected"
extends CanvasLayer


## Colour palette (matches Config.UI colours)
const COLOR_CONNECTED: Color = Color(0.2, 0.85, 0.3)       # green
const COLOR_CONNECTING: Color = Color(1.0, 0.75, 0.1)      # yellow/amber
const COLOR_DISCONNECTED: Color = Color(0.95, 0.25, 0.25)  # red

## Dot size in pixels
const DOT_SIZE: int = 12

## Refresh interval (seconds) — keeps the timer label and tick-rate current
const REFRESH_INTERVAL: float = 0.5


var _panel: PanelContainer
var _dot: ColorRect
var _label: Label
var _stats_label: Label
var _refresh_timer: float = 0.0


func _ready() -> void:
	layer = 127  # render above all other CanvasLayers
	_build_ui()
	_connect_signals()
	_refresh_display()
	_log_info("ConnectionIndicator ready")


func _process(delta: float) -> void:
	_refresh_timer += delta
	if _refresh_timer >= REFRESH_INTERVAL:
		_refresh_timer = 0.0
		_refresh_display()


## Build UI nodes programmatically so no .tscn file is needed -------------

func _build_ui() -> void:
	# Outer margin container — pins to top-right
	var margin := MarginContainer.new()
	margin.anchor_left = 1.0
	margin.anchor_top = 0.0
	margin.anchor_right = 1.0
	margin.anchor_bottom = 0.0
	margin.offset_left = -200.0
	margin.offset_bottom = 80.0
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	add_child(margin)

	# Background panel
	_panel = PanelContainer.new()
	margin.add_child(_panel)

	# Vertical layout: connection row + stats row
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	_panel.add_child(vbox)

	# — Row 1: dot + status text —
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	vbox.add_child(hbox)

	# Coloured dot
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2i(DOT_SIZE, DOT_SIZE)
	_dot.color = COLOR_DISCONNECTED
	# Centre dot vertically relative to label
	var dot_margin := MarginContainer.new()
	dot_margin.add_theme_constant_override("margin_top", 3)
	dot_margin.add_child(_dot)
	hbox.add_child(dot_margin)

	# Status label
	_label = Label.new()
	_label.text = "Disconnected"
	_label.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	hbox.add_child(_label)

	# — Row 2: stats (tick rate + vehicle count) —
	_stats_label = Label.new()
	_stats_label.text = ""
	_stats_label.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	_stats_label.add_theme_font_size_override("font_size", 11)
	vbox.add_child(_stats_label)


## Connect to SimulationClient signals ------------------------------------

func _connect_signals() -> void:
	SimulationClient.connected.connect(_on_connected)
	SimulationClient.disconnected.connect(_on_disconnected)
	SimulationClient.connection_failed.connect(_on_connection_failed)


## Signal handlers --------------------------------------------------------

func _on_connected() -> void:
	_set_status(COLOR_CONNECTED, "Connected")
	_log_info("Status: Connected")


func _on_disconnected() -> void:
	_set_status(COLOR_DISCONNECTED, "Disconnected")


func _on_connection_failed(_reason: String) -> void:
	_set_status(COLOR_DISCONNECTED, "Connection failed")


## Periodic refresh -------------------------------------------------------

func _refresh_display() -> void:
	match SimulationClient.connection_state:
		SimulationClient.ConnectionState.CONNECTED:
			_set_status(COLOR_CONNECTED, "Connected")
			var tick_rate := snappedf(SimulationClient.measured_tick_rate, 0.1)
			var vehicle_count := VehicleManager.get_vehicle_count()
			_stats_label.text = "%.1f tick/s  •  %d vehicles" % [tick_rate, vehicle_count]
			if vehicle_count >= 25:
				_log_info_once(
					"At least 25 vehicles active (%d)" % vehicle_count
				)

		SimulationClient.ConnectionState.CONNECTING:
			_set_status(COLOR_CONNECTING, "Connecting...")
			_stats_label.text = ""

		SimulationClient.ConnectionState.RECONNECTING:
			var attempt := SimulationClient._reconnect_attempts
			_set_status(COLOR_CONNECTING, "Reconnecting (%d)..." % attempt)
			_stats_label.text = ""

		SimulationClient.ConnectionState.DISCONNECTED:
			_set_status(COLOR_DISCONNECTED, "Disconnected")
			_stats_label.text = ""


func _set_status(color: Color, text: String) -> void:
	_dot.color = color
	_label.text = text


## Avoid spamming the log with the same message --------------------------

var _logged_25_vehicles: bool = false

func _log_info_once(message: String) -> void:
	if not _logged_25_vehicles:
		_logged_25_vehicles = true
		_log_info(message)


## Logging ----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[ConnectionIndicator] %s" % message)
