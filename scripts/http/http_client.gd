## HTTP client wrapper providing async/await pattern for HTTP requests
## Handles timeouts, retries, JSON parsing, and error handling
class_name HTTPClient2
extends Node


## Signal emitted when a request completes
signal request_completed(result: HTTPResult)


## The underlying HTTPRequest node
var _http_request: HTTPRequest

## Base URL for all requests
var _base_url: String

## Request timeout in seconds
var _timeout: float

## Timer for timeout handling
var _timeout_timer: Timer

## Whether a request is currently in progress
var _is_requesting: bool = false


func _init(base_url: String = "", timeout: float = Config.HTTP_TIMEOUT_SECONDS) -> void:
	_base_url = base_url
	_timeout = timeout


func _ready() -> void:
	_setup_http_request()
	_setup_timeout_timer()


func _setup_http_request() -> void:
	_http_request = HTTPRequest.new()
	_http_request.timeout = _timeout
	_http_request.request_completed.connect(_on_request_completed)
	add_child(_http_request)


func _setup_timeout_timer() -> void:
	_timeout_timer = Timer.new()
	_timeout_timer.one_shot = true
	_timeout_timer.timeout.connect(_on_timeout)
	add_child(_timeout_timer)


## Perform a GET request
func get_request(endpoint: String, headers: PackedStringArray = []) -> HTTPResult:
	return await _make_request(HTTPClient.METHOD_GET, endpoint, "", headers)


## Perform a POST request with JSON body
func post_request(endpoint: String, data: Dictionary = {}, headers: PackedStringArray = []) -> HTTPResult:
	var body := JSON.stringify(data) if not data.is_empty() else ""
	var request_headers := _ensure_json_headers(headers)
	return await _make_request(HTTPClient.METHOD_POST, endpoint, body, request_headers)


## Perform a PUT request with JSON body
func put_request(endpoint: String, data: Dictionary = {}, headers: PackedStringArray = []) -> HTTPResult:
	var body := JSON.stringify(data) if not data.is_empty() else ""
	var request_headers := _ensure_json_headers(headers)
	return await _make_request(HTTPClient.METHOD_PUT, endpoint, body, request_headers)


## Perform a DELETE request
func delete_request(endpoint: String, headers: PackedStringArray = []) -> HTTPResult:
	return await _make_request(HTTPClient.METHOD_DELETE, endpoint, "", headers)


## Perform a PATCH request with JSON body
func patch_request(endpoint: String, data: Dictionary = {}, headers: PackedStringArray = []) -> HTTPResult:
	var body := JSON.stringify(data) if not data.is_empty() else ""
	var request_headers := _ensure_json_headers(headers)
	return await _make_request(HTTPClient.METHOD_PATCH, endpoint, body, request_headers)


## Internal method to make HTTP requests
func _make_request(method: int, endpoint: String, body: String, headers: PackedStringArray) -> HTTPResult:
	if _is_requesting:
		return HTTPResult.error("Request already in progress", HTTPResult.ErrorType.UNKNOWN)

	_is_requesting = true
	var url := _build_url(endpoint)

	_log_request(method, url, body)

	var error := _http_request.request(url, headers, method, body)
	if error != OK:
		_is_requesting = false
		return HTTPResult.error("Failed to initiate request (error code: %d)" % error, HTTPResult.ErrorType.UNKNOWN)

	# Start timeout timer as backup (HTTPRequest has its own timeout but this is extra safety)
	_timeout_timer.start(_timeout + 1.0)

	# Wait for completion
	var result: HTTPResult = await request_completed

	_timeout_timer.stop()
	_is_requesting = false

	return result


## Build full URL from endpoint
func _build_url(endpoint: String) -> String:
	if endpoint.begins_with("http://") or endpoint.begins_with("https://"):
		return endpoint
	return _base_url + endpoint


## Ensure Content-Type header is set for JSON requests
func _ensure_json_headers(headers: PackedStringArray) -> PackedStringArray:
	var has_content_type := false
	for header in headers:
		if header.to_lower().begins_with("content-type:"):
			has_content_type = true
			break

	if not has_content_type:
		var new_headers := headers.duplicate()
		new_headers.append("Content-Type: application/json")
		return new_headers

	return headers


## Handle HTTP request completion
func _on_request_completed(http_result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	var result: HTTPResult

	if http_result != HTTPRequest.RESULT_SUCCESS:
		result = HTTPResult.from_http_error(http_result)
	else:
		var body_string := body.get_string_from_utf8()
		var parsed_data: Variant = null
		var parse_error := ""

		# Try to parse JSON if body is not empty
		if not body_string.is_empty():
			var json := JSON.new()
			var json_error := json.parse(body_string)
			if json_error == OK:
				parsed_data = json.data
			else:
				parse_error = "JSON parse error at line %d" % json.get_error_line()

		# Check if status code indicates success (2xx)
		if response_code >= 200 and response_code < 300:
			var response_headers := _parse_headers(headers)
			result = HTTPResult.ok(response_code, parsed_data, body_string, response_headers)
		else:
			# HTTP error (4xx, 5xx, etc.)
			var error_msg := "HTTP %d" % response_code
			if parsed_data is Dictionary and parsed_data.has("detail"):
				error_msg += ": " + str(parsed_data.detail)
			result = HTTPResult.error(error_msg, HTTPResult.ErrorType.HTTP_ERROR, response_code)
			result.data = parsed_data
			result.body = body_string

	_log_response(result)
	request_completed.emit(result)


## Handle timeout
func _on_timeout() -> void:
	if _is_requesting:
		_http_request.cancel_request()
		var result := HTTPResult.error("Request timed out", HTTPResult.ErrorType.TIMEOUT)
		request_completed.emit(result)


## Parse response headers into dictionary
func _parse_headers(headers: PackedStringArray) -> Dictionary:
	var result := {}
	for header in headers:
		var parts := header.split(":", true, 1)
		if parts.size() == 2:
			result[parts[0].strip_edges()] = parts[1].strip_edges()
	return result


## Log request for debugging
func _log_request(method: int, url: String, body: String) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		var method_name := _get_method_name(method)
		print("[HTTPClient] %s %s" % [method_name, url])
		if not body.is_empty() and body.length() < 500:
			print("[HTTPClient] Body: %s" % body)


## Log response for debugging
func _log_response(result: HTTPResult) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		if result.success:
			print("[HTTPClient] Response: %d OK" % result.status_code)
		else:
			print("[HTTPClient] Response: %s" % result.get_description())


## Get HTTP method name from constant
func _get_method_name(method: int) -> String:
	match method:
		HTTPClient.METHOD_GET:
			return "GET"
		HTTPClient.METHOD_POST:
			return "POST"
		HTTPClient.METHOD_PUT:
			return "PUT"
		HTTPClient.METHOD_DELETE:
			return "DELETE"
		HTTPClient.METHOD_PATCH:
			return "PATCH"
		_:
			return "UNKNOWN"


## Check if a request is currently in progress
func is_busy() -> bool:
	return _is_requesting


## Cancel any ongoing request
func cancel() -> void:
	if _is_requesting:
		_http_request.cancel_request()
		_timeout_timer.stop()
		_is_requesting = false


## Set the base URL
func set_base_url(url: String) -> void:
	_base_url = url


## Get the current base URL
func get_base_url() -> String:
	return _base_url
