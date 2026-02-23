## VehicleInfoPopup — floating info panel that appears when a vehicle is clicked.
##
## Builds its UI programmatically (no .tscn required).
## Rendered as a CanvasLayer (layer 126) so it always appears above 3D content
## but just below the ConnectionIndicator (127).
##
## Usage in a scene script:
##   var popup: VehicleInfoPopup = ...
##   vehicle_renderer.vehicle_selected.connect(
##       func(vid, state): popup.show_vehicle(vid, get_viewport().get_mouse_position()))
##
## The popup auto-dismisses when the displayed vehicle finishes / is removed,
## or when the WebSocket disconnects.  A close button (×) also dismisses it.
class_name VehicleInfoPopup
extends CanvasLayer


## Fixed width of the popup panel (px)
const POPUP_WIDTH: float = 230.0

## Minimum gap between panel edge and viewport boundary (px)
const SCREEN_MARGIN: float = 10.0


## UI nodes built in _build_ui()
var _panel       : PanelContainer
var _title_label : Label
var _body_label  : RichTextLabel
var _close_btn   : Button

## ID of the currently displayed vehicle, or "" when hidden
var _current_id: String = ""

## Whether the popup is visible
var _is_showing: bool = false


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 126  # Just below ConnectionIndicator (127)
	_build_ui()
	hide_popup()

	VehicleManager.vehicle_removed.connect(_on_vehicle_removed)
	SimulationClient.disconnected.connect(_on_disconnected)


# ── Public API ───────────────────────────────────────────────────────────────

## Display info for vehicle_id, anchored near screen_pos.
func show_vehicle(vehicle_id: String, screen_pos: Vector2) -> void:
	_current_id = vehicle_id
	_is_showing  = true
	_update_content(vehicle_id)
	_panel.visible = true
	# Defer repositioning one frame so PanelContainer has computed its size
	call_deferred("_reposition", screen_pos)


## Hide and clear the popup.
func hide_popup() -> void:
	_current_id = ""
	_is_showing  = false
	_panel.visible = false


## Refresh the displayed info (e.g. called on vehicle_updated).
func refresh() -> void:
	if _is_showing and not _current_id.is_empty():
		_update_content(_current_id)


func is_showing() -> bool:
	return _is_showing


func get_current_id() -> String:
	return _current_id


# ── UI construction ──────────────────────────────────────────────────────────

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(POPUP_WIDTH, 0)
	add_child(_panel)

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left",   10)
	outer.add_theme_constant_override("margin_right",  10)
	outer.add_theme_constant_override("margin_top",     8)
	outer.add_theme_constant_override("margin_bottom",  8)
	_panel.add_child(outer)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	outer.add_child(vbox)

	# ── Header row: title + close button ─────────────────────────────────
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	vbox.add_child(header)

	_title_label = Label.new()
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_color_override("font_color", Config.UI.TEXT_COLOR)
	_title_label.add_theme_font_size_override("font_size", 13)
	header.add_child(_title_label)

	_close_btn = Button.new()
	_close_btn.text = "×"
	_close_btn.flat = true
	_close_btn.custom_minimum_size = Vector2(22, 22)
	_close_btn.add_theme_color_override("font_color", Config.UI.TEXT_SECONDARY_COLOR)
	_close_btn.pressed.connect(hide_popup)
	header.add_child(_close_btn)

	# ── Separator ─────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())

	# ── Body label ────────────────────────────────────────────────────────
	_body_label = RichTextLabel.new()
	_body_label.bbcode_enabled  = true
	_body_label.fit_content     = true
	_body_label.scroll_active   = false
	_body_label.custom_minimum_size = Vector2(POPUP_WIDTH - 20, 0)
	_body_label.add_theme_color_override("default_color",
		Config.UI.TEXT_SECONDARY_COLOR)
	_body_label.add_theme_font_size_override("normal_font_size", 11)
	vbox.add_child(_body_label)


# ── Content ──────────────────────────────────────────────────────────────────

func _update_content(vehicle_id: String) -> void:
	var state := VehicleManager.get_vehicle(vehicle_id)

	_title_label.text = "Vehicle  %s" % vehicle_id

	var velocity : float  = state.get("v",        0.0)
	var heading  : float  = state.get("h",        0.0)
	var status   : String = state.get("status",   "unknown")
	var edge_idx : int    = state.get("edge_idx", -1)
	var progress : float  = state.get("progress", 0.0)
	var lon      : float  = state.get("lon",      0.0)
	var lat      : float  = state.get("lat",      0.0)

	var kmh    := velocity * 3.6
	var card   := _heading_to_cardinal(heading)

	var t := "[color=#aaaaaa]Status:[/color]  %s\n" % status
	t     += "[color=#aaaaaa]Speed:[/color]   %.1f km/h\n" % kmh
	t     += "[color=#aaaaaa]Heading:[/color] %.0f° %s\n" % [heading, card]
	t     += "[color=#aaaaaa]Edge:[/color]    %d  (%.0f%%)\n" % [edge_idx, progress * 100.0]
	t     += "[color=#aaaaaa]GPS:[/color]     %.5f, %.5f" % [lon, lat]

	_body_label.text = t


## Converts a compass heading in degrees to an 8-point cardinal label.
func _heading_to_cardinal(deg: float) -> String:
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW", "N"]
	var idx  := int(round(fmod(deg, 360.0) / 45.0))
	return dirs[clampi(idx, 0, 8)]


# ── Positioning ──────────────────────────────────────────────────────────────

func _reposition(screen_pos: Vector2) -> void:
	var vp_size   := get_viewport().get_visible_rect().size
	var panel_w   := POPUP_WIDTH
	# Use the actual computed height if available, otherwise fall back to 130 px
	var panel_h   := _panel.size.y if _panel.size.y > 10 else 130.0

	var x := screen_pos.x + 14.0
	var y := screen_pos.y - panel_h * 0.5

	x = clampf(x, SCREEN_MARGIN, vp_size.x - panel_w - SCREEN_MARGIN)
	y = clampf(y, SCREEN_MARGIN, vp_size.y - panel_h - SCREEN_MARGIN)

	_panel.position = Vector2(x, y)


# ── Signal handlers ──────────────────────────────────────────────────────────

func _on_vehicle_removed(vehicle_id: String) -> void:
	if vehicle_id == _current_id:
		hide_popup()


func _on_disconnected() -> void:
	hide_popup()
