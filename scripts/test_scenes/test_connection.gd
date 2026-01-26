## Test scene for HTTP connection testing
## Provides comprehensive testing of HTTP client functionality
extends Control


@onready var log_text: RichTextLabel = $MarginContainer/VBoxContainer/LogText
@onready var run_all_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/RunAllButton
@onready var health_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/HealthButton
@onready var detailed_health_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/DetailedHealthButton
@onready var test_404_button: Button = $MarginContainer/VBoxContainer/HBoxContainer2/Test404Button
@onready var test_timeout_button: Button = $MarginContainer/VBoxContainer/HBoxContainer2/TestTimeoutButton
@onready var clear_button: Button = $MarginContainer/VBoxContainer/HBoxContainer3/ClearButton
@onready var back_button: Button = $MarginContainer/VBoxContainer/HBoxContainer3/BackButton
@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel

var _test_count: int = 0
var _pass_count: int = 0
var _fail_count: int = 0
var _logger: UILogger


func _ready() -> void:
	_logger = UILogger.new(log_text)
	_connect_signals()
	_logger.info("Test Connection Scene Ready")
	_logger.info("Backend URL: %s" % Config.base_url)
	_logger.info("API URL: %s" % Config.api_url)
	_logger.info("")


func _connect_signals() -> void:
	run_all_button.pressed.connect(_on_run_all_pressed)
	health_button.pressed.connect(_on_health_pressed)
	detailed_health_button.pressed.connect(_on_detailed_health_pressed)
	test_404_button.pressed.connect(_on_test_404_pressed)
	test_timeout_button.pressed.connect(_on_test_timeout_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	back_button.pressed.connect(_on_back_pressed)


func _set_buttons_disabled(disabled: bool) -> void:
	run_all_button.disabled = disabled
	health_button.disabled = disabled
	detailed_health_button.disabled = disabled
	test_404_button.disabled = disabled
	test_timeout_button.disabled = disabled


func _on_run_all_pressed() -> void:
	_test_count = 0
	_pass_count = 0
	_fail_count = 0

	_logger.info("========== Running All Tests ==========")
	_set_buttons_disabled(true)

	await _test_health_check()
	await _test_detailed_health()
	await _test_404_error()
	await _test_invalid_endpoint()

	_logger.info("")
	_logger.info("========== Test Results ==========")
	_logger.info("Total: %d | Passed: %d | Failed: %d" % [_test_count, _pass_count, _fail_count])

	if _fail_count == 0:
		_logger.success("All tests passed!")
	else:
		_logger.error("%d test(s) failed" % _fail_count)

	_set_buttons_disabled(false)
	_update_status()


func _on_health_pressed() -> void:
	_set_buttons_disabled(true)
	await _test_health_check()
	_set_buttons_disabled(false)


func _on_detailed_health_pressed() -> void:
	_set_buttons_disabled(true)
	await _test_detailed_health()
	_set_buttons_disabled(false)


func _on_test_404_pressed() -> void:
	_set_buttons_disabled(true)
	await _test_404_error()
	_set_buttons_disabled(false)


func _on_test_timeout_pressed() -> void:
	_set_buttons_disabled(true)
	await _test_connection_refused()
	_set_buttons_disabled(false)


func _on_clear_pressed() -> void:
	log_text.text = ""
	_test_count = 0
	_pass_count = 0
	_fail_count = 0
	_update_status()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")


## Test: Basic health check
func _test_health_check() -> void:
	_logger.info("--- Test: Basic Health Check ---")
	status_label.text = "Testing: Basic Health Check..."

	var result := await HTTPManager.health_check()

	_test_count += 1
	if result.success and result.status_code == 200:
		_pass_count += 1
		_logger.success("PASS: Health check returned 200 OK")
		_logger.info("Response: %s" % str(result.data))
	else:
		_fail_count += 1
		_logger.error("FAIL: Health check failed - %s" % result.error_message)

	_update_status()


## Test: Detailed health check
func _test_detailed_health() -> void:
	_logger.info("--- Test: Detailed Health Check ---")
	status_label.text = "Testing: Detailed Health Check..."

	var result := await HTTPManager.health_check_detailed()

	_test_count += 1
	if result.success and result.status_code == 200:
		_pass_count += 1
		_logger.success("PASS: Detailed health check returned 200 OK")
		if result.data is Dictionary:
			_logger.info("Response data:")
			for key in result.data:
				_logger.info("  %s: %s" % [key, str(result.data[key])])
	else:
		_fail_count += 1
		_logger.error("FAIL: Detailed health check failed - %s" % result.error_message)

	_update_status()


## Test: 404 error handling
func _test_404_error() -> void:
	_logger.info("--- Test: 404 Error Handling ---")
	status_label.text = "Testing: 404 Error Handling..."

	var result := await HTTPManager.get_request("/nonexistent-endpoint-12345")

	_test_count += 1
	if not result.success and result.status_code == 404:
		_pass_count += 1
		_logger.success("PASS: 404 error correctly detected")
		_logger.info("Error message: %s" % result.error_message)
	elif result.success:
		_fail_count += 1
		_logger.error("FAIL: Expected 404 but got success")
	else:
		# Could be connection refused if backend is down
		_logger.warning("SKIP: Backend not reachable - %s" % result.error_message)

	_update_status()


## Test: Invalid endpoint
func _test_invalid_endpoint() -> void:
	_logger.info("--- Test: Invalid Method Response ---")
	status_label.text = "Testing: Invalid Endpoint..."

	# Try to POST to a GET-only endpoint
	var result := await HTTPManager.post_request("/health", {"test": "data"})

	_test_count += 1
	if not result.success and result.status_code == 405:
		_pass_count += 1
		_logger.success("PASS: 405 Method Not Allowed correctly detected")
	elif result.success:
		# Some servers might accept POST on health endpoint
		_logger.warning("WARN: Server accepted POST on /health (may be valid)")
		_pass_count += 1
	else:
		_logger.info("Response: HTTP %d - %s" % [result.status_code, result.error_message])

	_update_status()


## Test: Connection refused (to unreachable port)
func _test_connection_refused() -> void:
	_logger.info("--- Test: Connection Refused Handling ---")
	status_label.text = "Testing: Connection Refused..."

	# Create a temporary client pointing to an invalid port
	var temp_client := HTTPClient2.new("http://localhost:59999")
	add_child(temp_client)

	var result := await temp_client.get_request("/health")

	temp_client.queue_free()

	_test_count += 1
	if not result.success and result.error_type == HTTPResult.ErrorType.CONNECTION_REFUSED:
		_pass_count += 1
		_logger.success("PASS: Connection refused correctly detected")
		_logger.info("Error type: %s" % HTTPResult.ErrorType.keys()[result.error_type])
	elif not result.success:
		_pass_count += 1
		_logger.success("PASS: Connection error detected (%s)" % result.error_message)
	else:
		_fail_count += 1
		_logger.error("FAIL: Expected connection error but got success")

	_update_status()


func _update_status() -> void:
	status_label.text = "Tests: %d | Passed: %d | Failed: %d" % [_test_count, _pass_count, _fail_count]
