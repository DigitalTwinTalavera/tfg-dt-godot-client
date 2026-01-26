## Test scene for coordinate conversion
## Demonstrates GPS to Godot conversion and validates accuracy
extends Control


@onready var log_text: RichTextLabel = $MarginContainer/VBoxContainer/LogText
@onready var run_all_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/RunAllButton
@onready var test_known_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/TestKnownButton
@onready var test_network_button: Button = $MarginContainer/VBoxContainer/HBoxContainer2/TestNetworkButton
@onready var test_batch_button: Button = $MarginContainer/VBoxContainer/HBoxContainer2/TestBatchButton
@onready var clear_button: Button = $MarginContainer/VBoxContainer/HBoxContainer3/ClearButton
@onready var back_button: Button = $MarginContainer/VBoxContainer/HBoxContainer3/BackButton
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel

var _test_count: int = 0
var _pass_count: int = 0
var _fail_count: int = 0
var _logger: UILogger
var _converter: CoordinateConverter


## Known test coordinates (Talavera de la Reina landmarks)
const TEST_COORDS := {
	"plaza_pan": {
		"name": "Plaza del Pan",
		"lon": -4.8293,
		"lat": 39.9579
	},
	"plaza_mayor": {
		"name": "Plaza Mayor",
		"lon": -4.8315,
		"lat": 39.9589
	},
	"puente_romano": {
		"name": "Puente Romano (Roman Bridge)",
		"lon": -4.8235,
		"lat": 39.9600
	},
	"center": {
		"name": "Default Center",
		"lon": Config.Coordinates.DEFAULT_CENTER_LON,
		"lat": Config.Coordinates.DEFAULT_CENTER_LAT
	}
}


func _ready() -> void:
	_logger = UILogger.new(log_text)
	_converter = CoordinateConverter.new()
	_connect_signals()
	_logger.info("Test Coordinate Conversion Scene Ready")
	_logger.info("Default center: [%.6f, %.6f]" % [
		Config.Coordinates.DEFAULT_CENTER_LON,
		Config.Coordinates.DEFAULT_CENTER_LAT
	])
	_logger.info("")


func _connect_signals() -> void:
	run_all_button.pressed.connect(_on_run_all_pressed)
	test_known_button.pressed.connect(_on_test_known_pressed)
	test_network_button.pressed.connect(_on_test_network_pressed)
	test_batch_button.pressed.connect(_on_test_batch_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	back_button.pressed.connect(_on_back_pressed)


func _set_buttons_disabled(disabled: bool) -> void:
	run_all_button.disabled = disabled
	test_known_button.disabled = disabled
	test_network_button.disabled = disabled
	test_batch_button.disabled = disabled


func _on_run_all_pressed() -> void:
	_reset_counters()
	_logger.info("========== Running All Coordinate Tests ==========")
	_set_buttons_disabled(true)

	_test_initialization()
	_test_known_coordinates()
	_test_round_trip_accuracy()
	_test_distance_calculation()
	_test_batch_conversion()

	if NetworkManager.is_loaded:
		_test_network_bounds()
	else:
		_logger.warning("Network not loaded - skipping network bounds test")

	_logger.info("")
	_logger.info("========== Test Results ==========")
	_logger.info("Total: %d | Passed: %d | Failed: %d" % [_test_count, _pass_count, _fail_count])

	if _fail_count == 0:
		_logger.success("All tests passed!")
	else:
		_logger.error("%d test(s) failed" % _fail_count)

	_set_buttons_disabled(false)
	_update_status()


func _on_test_known_pressed() -> void:
	_set_buttons_disabled(true)
	_test_known_coordinates()
	_test_round_trip_accuracy()
	_set_buttons_disabled(false)


func _on_test_network_pressed() -> void:
	_set_buttons_disabled(true)
	if NetworkManager.is_loaded:
		_test_network_bounds()
	else:
		_logger.warning("Network not loaded. Load network data first.")
	_set_buttons_disabled(false)


func _on_test_batch_pressed() -> void:
	_set_buttons_disabled(true)
	_test_batch_conversion()
	_set_buttons_disabled(false)


func _on_clear_pressed() -> void:
	log_text.text = ""
	_reset_counters()
	_update_status()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _reset_counters() -> void:
	_test_count = 0
	_pass_count = 0
	_fail_count = 0


func _update_status() -> void:
	status_label.text = "Tests: %d | Passed: %d | Failed: %d" % [_test_count, _pass_count, _fail_count]


## Test: Converter initialization
func _test_initialization() -> void:
	_logger.info("--- Test: Initialization ---")

	# Test uninitialized state
	var uninit_converter := CoordinateConverter.new()
	_test_count += 1
	if not uninit_converter.is_initialized():
		_pass_count += 1
		_logger.success("PASS: New converter is not initialized")
	else:
		_fail_count += 1
		_logger.error("FAIL: New converter should not be initialized")

	# Test center initialization
	_converter.set_center(
		Config.Coordinates.DEFAULT_CENTER_LON,
		Config.Coordinates.DEFAULT_CENTER_LAT
	)

	_test_count += 1
	if _converter.is_initialized():
		_pass_count += 1
		_logger.success("PASS: Converter initialized with center")
		_logger.info("Center: %s" % _converter)
	else:
		_fail_count += 1
		_logger.error("FAIL: Converter should be initialized after set_center()")

	_update_status()


## Test: Known landmark coordinates
func _test_known_coordinates() -> void:
	_logger.info("--- Test: Known Coordinates ---")

	# Ensure converter is initialized
	_converter.set_center(
		Config.Coordinates.DEFAULT_CENTER_LON,
		Config.Coordinates.DEFAULT_CENTER_LAT
	)

	for key in TEST_COORDS:
		var coord: Dictionary = TEST_COORDS[key]
		var godot_pos := _converter.gps_to_godot(coord.lon, coord.lat)

		_logger.info("%s:" % coord.name)
		_logger.info("  GPS: [%.6f, %.6f]" % [coord.lon, coord.lat])
		_logger.info("  Godot: [%.2f, %.2f, %.2f]" % [godot_pos.x, godot_pos.y, godot_pos.z])

	# Test that center maps to origin
	var center_pos := _converter.gps_to_godot(
		Config.Coordinates.DEFAULT_CENTER_LON,
		Config.Coordinates.DEFAULT_CENTER_LAT
	)

	_test_count += 1
	var tolerance := 0.01  # 1cm tolerance
	if center_pos.length() < tolerance:
		_pass_count += 1
		_logger.success("PASS: Center maps to origin (%.4f m from origin)" % center_pos.length())
	else:
		_fail_count += 1
		_logger.error("FAIL: Center should map to origin, got %s" % center_pos)

	_update_status()


## Test: Round-trip conversion accuracy
func _test_round_trip_accuracy() -> void:
	_logger.info("--- Test: Round-trip Accuracy ---")

	# Test several points
	var test_points := [
		Vector2(-4.8293, 39.9579),  # Plaza del Pan
		Vector2(-4.8200, 39.9500),
		Vector2(-4.8400, 39.9700),
	]

	var max_error := 0.0
	var all_passed := true

	for gps_original in test_points:
		var godot_pos := _converter.gps_to_godot(gps_original.x, gps_original.y)
		var gps_result := _converter.godot_to_gps(godot_pos)

		var error_lon: float = absf(gps_original.x - gps_result.x)
		var error_lat: float = absf(gps_original.y - gps_result.y)
		var total_error: float = sqrt(error_lon * error_lon + error_lat * error_lat)
		max_error = maxf(max_error, total_error)

		# Should be accurate to about 0.000001 degrees (~0.1 meters)
		if total_error > Config.Coordinates.GPS_PRECISION * 10:
			all_passed = false
			_logger.error("Round-trip error too large: %.10f degrees" % total_error)

	_test_count += 1
	if all_passed:
		_pass_count += 1
		_logger.success("PASS: Round-trip accuracy (max error: %.10f degrees)" % max_error)
	else:
		_fail_count += 1
		_logger.error("FAIL: Round-trip accuracy exceeded tolerance")

	_update_status()


## Test: Distance calculation
func _test_distance_calculation() -> void:
	_logger.info("--- Test: Distance Calculation ---")

	# Calculate distance between Plaza del Pan and Plaza Mayor
	var pan := TEST_COORDS["plaza_pan"]
	var mayor := TEST_COORDS["plaza_mayor"]

	var distance_gps := _converter.gps_distance_meters(
		pan.lon, pan.lat,
		mayor.lon, mayor.lat
	)

	_logger.info("Distance from Plaza del Pan to Plaza Mayor:")
	_logger.info("  Haversine: %.2f meters" % distance_gps)

	# Also compare with Godot positions
	var pan_godot := _converter.gps_to_godot(pan.lon, pan.lat)
	var mayor_godot := _converter.gps_to_godot(mayor.lon, mayor.lat)
	var distance_godot := pan_godot.distance_to(mayor_godot)

	_logger.info("  Godot 3D: %.2f meters" % distance_godot)

	# The two distances should be similar (within 1% for small distances)
	var diff_percent: float = absf(distance_gps - distance_godot) / distance_gps * 100.0

	_test_count += 1
	if diff_percent < 1.0:
		_pass_count += 1
		_logger.success("PASS: Distance methods match (%.2f%% difference)" % diff_percent)
	else:
		_fail_count += 1
		_logger.error("FAIL: Distance methods differ by %.2f%%" % diff_percent)

	_update_status()


## Test: Batch conversion
func _test_batch_conversion() -> void:
	_logger.info("--- Test: Batch Conversion ---")

	# Create array of GPS coordinates
	var gps_coords: Array = []
	for key in TEST_COORDS:
		var coord: Dictionary = TEST_COORDS[key]
		gps_coords.append(Vector2(coord.lon, coord.lat))

	# Convert batch
	var godot_positions := _converter.batch_gps_to_godot(gps_coords)

	_test_count += 1
	if godot_positions.size() == gps_coords.size():
		_pass_count += 1
		_logger.success("PASS: Batch conversion returned %d positions" % godot_positions.size())

		# Verify each position
		for i in range(gps_coords.size()):
			var single := _converter.gps_to_godot_v2(gps_coords[i])
			var batch := godot_positions[i]
			if single.distance_to(batch) > 0.001:
				_logger.warning("Mismatch at index %d" % i)
	else:
		_fail_count += 1
		_logger.error("FAIL: Batch conversion size mismatch")

	# Test inverse batch
	var gps_back := _converter.batch_godot_to_gps(godot_positions)

	_test_count += 1
	if gps_back.size() == godot_positions.size():
		_pass_count += 1
		_logger.success("PASS: Inverse batch conversion returned %d positions" % gps_back.size())
	else:
		_fail_count += 1
		_logger.error("FAIL: Inverse batch conversion size mismatch")

	_update_status()


## Test: Network bounds integration
func _test_network_bounds() -> void:
	_logger.info("--- Test: Network Bounds Integration ---")

	if not NetworkManager.is_loaded:
		_logger.warning("Network not loaded")
		return

	var network := NetworkManager.network

	# Create new converter from network
	var net_converter := CoordinateConverter.new()
	net_converter.set_bounds_from_network(network)

	_test_count += 1
	if net_converter.is_initialized():
		_pass_count += 1
		_logger.success("PASS: Converter initialized from network")
		_logger.info("Network bounds:")
		_logger.info("  Min: [%.6f, %.6f]" % [network.bounds_min.x, network.bounds_min.y])
		_logger.info("  Max: [%.6f, %.6f]" % [network.bounds_max.x, network.bounds_max.y])
		_logger.info("  Center: %s" % net_converter)
	else:
		_fail_count += 1
		_logger.error("FAIL: Converter not initialized from network")

	# Test bounds in Godot space
	var godot_bounds := net_converter.get_godot_bounds()
	_logger.info("Godot bounds:")
	_logger.info("  Min: %s" % godot_bounds.min)
	_logger.info("  Max: %s" % godot_bounds.max)
	_logger.info("  Size: %s meters" % godot_bounds.size)

	# Test size in meters
	var size_meters := net_converter.get_bounds_size_meters()
	_logger.info("Network size: %.2f x %.2f meters" % [size_meters.x, size_meters.y])

	# Convert some network nodes
	var node_ids := network.get_node_ids()
	if node_ids.size() > 0:
		_logger.info("")
		_logger.info("Sample node conversions (first 3):")
		for i in range(min(3, node_ids.size())):
			var node := network.get_node(node_ids[i])
			var godot_pos := net_converter.gps_to_godot(node.longitude, node.latitude)
			_logger.info("  Node %d: GPS[%.6f, %.6f] -> Godot[%.2f, %.2f, %.2f]" % [
				node.id, node.longitude, node.latitude,
				godot_pos.x, godot_pos.y, godot_pos.z
			])

	_update_status()
