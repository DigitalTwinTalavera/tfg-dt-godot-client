## Main scene script
## Entry point for the Digital Twin Traffic Client application
extends Control


@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel
@onready var backend_url_label: Label = $MarginContainer/VBoxContainer/BackendUrlLabel
@onready var check_health_button: Button = $MarginContainer/VBoxContainer/CheckHealthButton
@onready var open_test_scene_button: Button = $MarginContainer/VBoxContainer/OpenTestSceneButton
@onready var open_network_test_button: Button = $MarginContainer/VBoxContainer/OpenNetworkTestButton
@onready var open_coordinate_test_button: Button = $MarginContainer/VBoxContainer/OpenCoordinateTestButton
@onready var open_node_renderer_button: Button = $MarginContainer/VBoxContainer/OpenNodeRendererButton
@onready var result_text: RichTextLabel = $MarginContainer/VBoxContainer/ResultText


func _ready() -> void:
	_setup_ui()
	_connect_signals()
	_display_config()


func _setup_ui() -> void:
	status_label.text = "Status: Not connected"
	result_text.text = ""


func _connect_signals() -> void:
	check_health_button.pressed.connect(_on_check_health_pressed)
	open_test_scene_button.pressed.connect(_on_open_test_scene_pressed)
	open_network_test_button.pressed.connect(_on_open_network_test_pressed)
	open_coordinate_test_button.pressed.connect(_on_open_coordinate_test_pressed)
	open_node_renderer_button.pressed.connect(_on_open_node_renderer_pressed)
	HTTPManager.connection_status_changed.connect(_on_connection_status_changed)


func _display_config() -> void:
	backend_url_label.text = "Backend: %s" % Config.base_url


func _on_check_health_pressed() -> void:
	status_label.text = "Status: Checking..."
	check_health_button.disabled = true

	var result := await HTTPManager.health_check_detailed()

	check_health_button.disabled = false

	if result.success:
		status_label.text = "Status: Connected"
		_display_health_result(result.data)
	else:
		status_label.text = "Status: Error - %s" % result.error_message
		result_text.text = "[color=red]Error:[/color] %s" % result.error_message


func _display_health_result(data: Variant) -> void:
	if data == null:
		result_text.text = "[color=green]Health check passed[/color]"
		return

	var text := "[color=green]Health Check Response:[/color]\n\n"

	if data is Dictionary:
		text += JsonUtils.stringify(data, true)
	else:
		text += str(data)

	result_text.text = text


func _on_open_test_scene_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/test_scenes/test_connection.tscn")


func _on_open_network_test_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/test_scenes/test_load_network.tscn")


func _on_open_coordinate_test_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/test_scenes/test_coordinates.tscn")


func _on_open_node_renderer_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/test_scenes/test_node_renderer.tscn")


func _on_connection_status_changed(connected: bool) -> void:
	if connected:
		status_label.text = "Status: Connected"
	else:
		status_label.text = "Status: Disconnected"
