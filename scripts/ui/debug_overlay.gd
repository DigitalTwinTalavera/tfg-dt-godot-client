## DebugOverlay
## Overlay alternable con F3 que pinta las métricas de PerfMonitor en la
## esquina superior izquierda. Construye su UI en _ready (sin .tscn).
##
## Diseño:
##   • CanvasLayer en layer 200 (encima del HUD que está en 125).
##   • PanelContainer con VBox de Labels monoespaciadas.
##   • Visible = false al arrancar — DemoController hace toggle con F3.
##   • Se refresca por signal `PerfMonitor.sample_ready`, NO por _process,
##     para no contaminar la métrica TIME_PROCESS que estamos midiendo.
class_name DebugOverlay
extends CanvasLayer


const _FONT_SIZE: int = 13


var _panel: PanelContainer
var _labels: Dictionary = {}  # key: String → Label


func _ready() -> void:
	layer = 200
	visible = false
	_build_ui()
	PerfMonitor.sample_ready.connect(_on_sample_ready)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 0.0
	_panel.anchor_top = 0.0
	_panel.offset_left = 12
	_panel.offset_top = 12
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  # no robar clicks al HUD

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.85)
	sb.border_color = Color(0.30, 0.50, 0.80, 1.0)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	_panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	_panel.add_child(vbox)

	_add_title(vbox, "DEBUG OVERLAY  (F3 to toggle)")
	_add_separator(vbox)
	_add_row(vbox, "fps")
	_add_row(vbox, "process")
	_add_row(vbox, "draw")
	_add_row(vbox, "vehicles")
	_add_separator(vbox)
	_add_row(vbox, "ws")
	_add_row(vbox, "tick_apply")
	_add_row(vbox, "parse")
	_add_row(vbox, "latency")
	_add_separator(vbox)
	_add_row(vbox, "memory")
	_add_row(vbox, "nodes")
	_add_row(vbox, "render")
	_add_separator(vbox)
	_add_row(vbox, "csv")

	add_child(_panel)


func _add_title(parent: Node, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
	lbl.add_theme_font_size_override("font_size", _FONT_SIZE)
	parent.add_child(lbl)


func _add_separator(parent: Node) -> void:
	var sep := HSeparator.new()
	parent.add_child(sep)


func _add_row(parent: Node, key: String) -> void:
	var lbl := Label.new()
	lbl.text = "%s:" % key
	lbl.add_theme_color_override("font_color", Color(0.92, 0.94, 0.96))
	lbl.add_theme_font_size_override("font_size", _FONT_SIZE)
	parent.add_child(lbl)
	_labels[key] = lbl


func _on_sample_ready(s: Dictionary) -> void:
	if not visible:
		return  # si está oculto no formateamos nada
	_labels["fps"].text = "FPS:        %5.1f   (frame %.1f ms)" % [
		s["fps"], 1000.0 / max(s["fps"], 1.0),
	]
	_labels["process"].text = "_process:   %5.2f ms     _physics: %5.2f ms" % [
		s["process_ms"], s["physics_ms"],
	]
	_labels["draw"].text = "Draw calls: %5d        Primitives: %d k" % [
		s["draw_calls"], int(s["primitives"] / 1000),
	]
	_labels["vehicles"].text = "Vehicles:   %5d" % [s["vehicles"]]
	_labels["ws"].text = "WS:         %5.0f msg/s   %.1f KB/s" % [
		s["ws_msgs_per_s"], s["ws_kb_per_s"],
	]
	_labels["tick_apply"].text = "Tick apply: avg %.2f ms / max %.2f ms" % [
		s["tick_apply_avg_ms"], s["tick_apply_max_ms"],
	]
	_labels["parse"].text = "WS parse:   avg %.2f ms / max %.2f ms" % [
		s["parse_avg_ms"], s["parse_max_ms"],
	]
	_labels["latency"].text = "Latency:    avg %.1f ms (sim → wall)" % [
		s["latency_avg_ms"],
	]
	_labels["memory"].text = "Memory:     %.0f MB" % [s["mem_static_mb"]]
	_labels["nodes"].text = "Nodes:      %d  (orphans %d)" % [
		s["nodes"], s["orphans"],
	]
	_labels["render"].text = "Renderer:   wait %.2f ms  upload %.2f ms  worker_wall %.2f ms" % [
		s["render_wait_avg_ms"], s["gpu_upload_avg_ms"], s["worker_wall_avg_ms"],
	]
	var csv: String = s.get("csv_path", "")
	_labels["csv"].text = "CSV:        %s" % (csv if csv != "" else "<disabled>")
