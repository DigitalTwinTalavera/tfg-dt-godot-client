## HTTPManager autoload singleton
## Provides global access to HTTP client functionality for communicating with the backend
extends Node


## Signal emitted when backend connection status changes
signal connection_status_changed(is_connected: bool)

## Signal emitted when health check completes
signal health_check_completed(result: HTTPResult)


## Internal HTTP client instance
var _client: HTTPClient2

## Whether the backend is currently reachable
var _is_backend_connected: bool = false

## Last successful health check timestamp
var _last_health_check: float = 0.0


func _ready() -> void:
	_setup_client()
	_log_startup()


func _setup_client() -> void:
	_client = HTTPClient2.new(Config.api_url)
	add_child(_client)


func _log_startup() -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[HTTPManager] Initialized")
		print("[HTTPManager] Backend URL: %s" % Config.base_url)
		print("[HTTPManager] API URL: %s" % Config.api_url)


## Check if backend is reachable
var is_connected: bool:
	get:
		return _is_backend_connected


## Perform a health check against the backend
func health_check() -> HTTPResult:
	var result := await _client.get_request(Config.Endpoints.HEALTH)

	var was_connected := _is_backend_connected
	_is_backend_connected = result.success

	if result.success:
		_last_health_check = Time.get_unix_time_from_system()

	if was_connected != _is_backend_connected:
		connection_status_changed.emit(_is_backend_connected)

	health_check_completed.emit(result)
	return result


## Perform a detailed health check
func health_check_detailed() -> HTTPResult:
	var result := await _client.get_request(Config.Endpoints.HEALTH_DETAILED)

	var was_connected := _is_backend_connected
	_is_backend_connected = result.success

	if result.success:
		_last_health_check = Time.get_unix_time_from_system()

	if was_connected != _is_backend_connected:
		connection_status_changed.emit(_is_backend_connected)

	return result


## GET request to an API endpoint
func get_request(endpoint: String) -> HTTPResult:
	return await _client.get_request(endpoint)


## POST request to an API endpoint with JSON data
func post_request(endpoint: String, data: Dictionary = {}) -> HTTPResult:
	return await _client.post_request(endpoint, data)


## PUT request to an API endpoint with JSON data
func put_request(endpoint: String, data: Dictionary = {}) -> HTTPResult:
	return await _client.put_request(endpoint, data)


## DELETE request to an API endpoint
func delete_request(endpoint: String) -> HTTPResult:
	return await _client.delete_request(endpoint)


## PATCH request to an API endpoint with JSON data
func patch_request(endpoint: String, data: Dictionary = {}) -> HTTPResult:
	return await _client.patch_request(endpoint, data)


## Get the import status from the backend
func get_import_status() -> HTTPResult:
	return await _client.get_request(Config.Endpoints.MAP_IMPORT_STATUS)


## Trigger an OSM import on the backend
func import_osm(filepath: String, clear_existing: bool = false) -> HTTPResult:
	var data := {
		"filepath": filepath,
		"clear_existing": clear_existing
	}
	return await _client.post_request(Config.Endpoints.MAP_IMPORT, data)


## Get time since last successful health check (in seconds)
## Returns -1 if no health check has been performed
func get_time_since_health_check() -> float:
	if _last_health_check == 0.0:
		return -1.0
	return Time.get_unix_time_from_system() - _last_health_check


## Check if the HTTP client is currently busy with a request
func is_busy() -> bool:
	return _client.is_busy()


## Cancel any ongoing request
func cancel_request() -> void:
	_client.cancel()


## Get the configured backend base URL
func get_backend_url() -> String:
	return Config.base_url


## Get the configured API URL
func get_api_url() -> String:
	return Config.api_url


## Get the configured WebSocket URL
func get_websocket_url() -> String:
	return Config.ws_url
