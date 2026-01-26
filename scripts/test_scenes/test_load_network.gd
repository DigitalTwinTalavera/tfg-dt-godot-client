## Test scene for loading road network from backend
## Demonstrates pagination, progress tracking, and error handling
extends Control


@onready var log_text: RichTextLabel = $MarginContainer/VBoxContainer/LogText
@onready var load_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/LoadButton
@onready var clear_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/ClearButton
@onready var stats_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/StatsButton
@onready var validate_button: Button = $MarginContainer/VBoxContainer/HBoxContainer2/ValidateButton
@onready var back_button: Button = $MarginContainer/VBoxContainer/HBoxContainer2/BackButton
@onready var progress_bar: ProgressBar = $MarginContainer/VBoxContainer/ProgressBar
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel

var _logger: UILogger


func _ready() -> void:
	_logger = UILogger.new(log_text)
	_connect_signals()
	_update_ui_state()
	_logger.info("Test Load Network Scene Ready")
	_logger.info("Backend URL: %s" % Config.base_url)
	_logger.info("")


func _connect_signals() -> void:
	load_button.pressed.connect(_on_load_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	stats_button.pressed.connect(_on_stats_pressed)
	validate_button.pressed.connect(_on_validate_pressed)
	back_button.pressed.connect(_on_back_pressed)

	NetworkManager.loading_started.connect(_on_loading_started)
	NetworkManager.loading_progress.connect(_on_loading_progress)
	NetworkManager.loading_completed.connect(_on_loading_completed)
	NetworkManager.loading_failed.connect(_on_loading_failed)
	NetworkManager.network_cleared.connect(_on_network_cleared)


func _update_ui_state() -> void:
	var is_loading := NetworkManager.is_loading()
	var is_loaded := NetworkManager.is_loaded

	load_button.disabled = is_loading
	load_button.text = "Loading..." if is_loading else "Load Network"
	clear_button.disabled = is_loading or not is_loaded
	stats_button.disabled = is_loading or not is_loaded
	validate_button.disabled = is_loading or not is_loaded

	if is_loaded:
		var stats := NetworkManager.get_network_stats()
		status_label.text = "Loaded: %d nodes, %d edges" % [stats.node_count, stats.edge_count]
	elif is_loading:
		status_label.text = "Loading..."
	else:
		status_label.text = "No data loaded"


func _on_load_pressed() -> void:
	_logger.info("========== Loading Network ==========")
	progress_bar.value = 0
	await NetworkManager.load_network(true)


func _on_clear_pressed() -> void:
	NetworkManager.clear_network()
	progress_bar.value = 0
	_logger.info("Network data cleared")


func _on_stats_pressed() -> void:
	if not NetworkManager.is_loaded:
		_logger.warning("No network loaded")
		return

	_logger.info("========== Network Statistics ==========")
	var stats := NetworkManager.get_network_stats()

	_logger.info("Nodes: %d" % stats.node_count)
	_logger.info("Edges: %d" % stats.edge_count)
	_logger.info("Total road length: %.2f km" % stats.total_length_km)
	_logger.info("")
	_logger.info("Bounds:")
	_logger.info("  Min: [%.6f, %.6f]" % [stats.bounds_min.x, stats.bounds_min.y])
	_logger.info("  Max: [%.6f, %.6f]" % [stats.bounds_max.x, stats.bounds_max.y])
	_logger.info("  Center: [%.6f, %.6f]" % [stats.center.x, stats.center.y])
	_logger.info("")

	if stats.has("node_types"):
		_logger.info("Node types:")
		for type_name in stats.node_types:
			_logger.info("  %s: %d" % [type_name, stats.node_types[type_name]])
		_logger.info("")

	if stats.has("road_types"):
		_logger.info("Road types:")
		for type_name in stats.road_types:
			_logger.info("  %s: %d" % [type_name, stats.road_types[type_name]])


func _on_validate_pressed() -> void:
	if not NetworkManager.is_loaded:
		_logger.warning("No network loaded")
		return

	_logger.info("========== Validating Network ==========")
	var validation := NetworkManager.network.validate()

	if validation.valid:
		_logger.success("Network is valid!")
	else:
		_logger.error("Network has issues:")
		for issue in validation.issues:
			_logger.error("  - %s" % issue)

	if validation.orphan_nodes > 0:
		_logger.warning("Orphan nodes (no edges): %d" % validation.orphan_nodes)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_loading_started() -> void:
	_logger.info("Loading started...")
	_update_ui_state()


func _on_loading_progress(progress: float, message: String) -> void:
	progress_bar.value = progress * 100
	status_label.text = message


func _on_loading_completed(network: RoadNetwork) -> void:
	progress_bar.value = 100
	_logger.success("Loading completed!")
	_logger.info("Loaded %d nodes and %d edges" % [network.get_node_count(), network.get_edge_count()])

	# Show sample data
	_show_sample_data(network)
	_update_ui_state()


func _on_loading_failed(error: String) -> void:
	progress_bar.value = 0
	_logger.error("Loading failed: %s" % error)
	_update_ui_state()


func _on_network_cleared() -> void:
	_logger.info("Network cleared")
	_update_ui_state()


func _show_sample_data(network: RoadNetwork) -> void:
	_logger.info("")
	_logger.info("--- Sample Nodes (first 3) ---")
	var node_ids := network.get_node_ids()
	for i in range(min(3, node_ids.size())):
		var node := network.get_node(node_ids[i])
		_logger.info("  %s" % str(node))

	_logger.info("")
	_logger.info("--- Sample Edges (first 3) ---")
	var edge_ids := network.get_edge_ids()
	for i in range(min(3, edge_ids.size())):
		var edge := network.get_edge(edge_ids[i])
		_logger.info("  %s" % str(edge))
