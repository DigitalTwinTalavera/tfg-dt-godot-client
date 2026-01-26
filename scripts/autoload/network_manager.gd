## NetworkManager autoload singleton
## Handles loading and caching road network data from the backend API
extends Node


## Emitted when loading starts
signal loading_started()

## Emitted during loading with progress percentage (0.0 to 1.0)
signal loading_progress(progress: float, message: String)

## Emitted when loading completes successfully
signal loading_completed(network: RoadNetwork)

## Emitted when loading fails
signal loading_failed(error: String)

## Emitted when network data is cleared
signal network_cleared()


## Loading state enumeration
enum LoadingState {
	IDLE,
	LOADING_NODES,
	LOADING_EDGES,
	COMPLETED,
	FAILED
}


## Current loading state
var state: LoadingState = LoadingState.IDLE

## Cached road network data
var network: RoadNetwork = RoadNetwork.new()

## Whether data has been loaded
var is_loaded: bool = false

## Last loading error message
var last_error: String = ""

## Loading configuration (initialized from Config)
var _page_size: int = Config.NETWORK_PAGE_SIZE
var _max_retries: int = Config.NETWORK_MAX_RETRIES
var _retry_delay: float = Config.NETWORK_RETRY_DELAY

## Loading progress tracking
var _total_nodes: int = 0
var _loaded_nodes: int = 0
var _total_edges: int = 0
var _loaded_edges: int = 0
var _is_loading: bool = false


func _ready() -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[NetworkManager] Initialized")


## Load the complete road network from the backend
func load_network(clear_existing: bool = true) -> bool:
	if _is_loading:
		push_warning("[NetworkManager] Loading already in progress")
		return false

	_is_loading = true
	state = LoadingState.LOADING_NODES
	last_error = ""

	if clear_existing:
		network.clear()
		is_loaded = false

	loading_started.emit()
	_log_info("Starting network load...")

	# Load nodes first
	var nodes_success := await _load_all_nodes()
	if not nodes_success:
		_handle_load_failure("Failed to load nodes: " + last_error)
		return false

	# Then load edges
	state = LoadingState.LOADING_EDGES
	var edges_success := await _load_all_edges()
	if not edges_success:
		_handle_load_failure("Failed to load edges: " + last_error)
		return false

	# Validate the loaded data
	var validation := network.validate()
	if not validation.valid:
		_log_warning("Network validation issues: %s" % str(validation.issues))

	# Complete
	state = LoadingState.COMPLETED
	is_loaded = true
	_is_loading = false

	var stats := network.get_stats()
	_log_info("Network loaded: %d nodes, %d edges, %.2f km total" % [
		stats.node_count,
		stats.edge_count,
		stats.total_length_km
	])

	loading_completed.emit(network)
	return true


## Load all nodes with pagination
func _load_all_nodes() -> bool:
	_total_nodes = 0
	_loaded_nodes = 0

	# First request to get total count
	var first_result := await _fetch_nodes_page(0, _page_size)
	if not first_result.success:
		last_error = first_result.error_message
		return false

	_total_nodes = JsonUtils.get_int(first_result.data, "total", 0)
	_process_nodes_response(first_result.data)

	_log_info("Loading %d nodes..." % _total_nodes)

	# Load remaining pages
	var skip := _page_size
	while skip < _total_nodes:
		var result := await _fetch_nodes_page(skip, _page_size)
		if not result.success:
			last_error = result.error_message
			return false

		_process_nodes_response(result.data)
		skip += _page_size

		# Report progress (nodes are first portion of total progress)
		var progress := float(_loaded_nodes) / float(_total_nodes) * Config.NETWORK_PROGRESS_NODES_WEIGHT
		loading_progress.emit(progress, "Loading nodes: %d/%d" % [_loaded_nodes, _total_nodes])

		# Small delay to prevent overwhelming the server
		await get_tree().create_timer(Config.NETWORK_PAGINATION_DELAY).timeout

	return true


## Load all edges with pagination
func _load_all_edges() -> bool:
	_total_edges = 0
	_loaded_edges = 0

	# First request to get total count
	var first_result := await _fetch_edges_page(0, _page_size)
	if not first_result.success:
		last_error = first_result.error_message
		return false

	_total_edges = JsonUtils.get_int(first_result.data, "total", 0)
	_process_edges_response(first_result.data)

	_log_info("Loading %d edges..." % _total_edges)

	# Load remaining pages
	var skip := _page_size
	while skip < _total_edges:
		var result := await _fetch_edges_page(skip, _page_size)
		if not result.success:
			last_error = result.error_message
			return false

		_process_edges_response(result.data)
		skip += _page_size

		# Report progress (edges are second portion of total progress)
		var progress := Config.NETWORK_PROGRESS_NODES_WEIGHT + float(_loaded_edges) / float(_total_edges) * Config.NETWORK_PROGRESS_EDGES_WEIGHT
		loading_progress.emit(progress, "Loading edges: %d/%d" % [_loaded_edges, _total_edges])

		# Small delay to prevent overwhelming the server
		await get_tree().create_timer(Config.NETWORK_PAGINATION_DELAY).timeout

	return true


## Fetch a page of nodes with retry logic
func _fetch_nodes_page(skip: int, limit: int) -> HTTPResult:
	var endpoint := "%s?skip=%d&limit=%d" % [Config.Endpoints.MAP_NODES, skip, limit]
	return await _fetch_with_retry(endpoint)


## Fetch a page of edges with retry logic
func _fetch_edges_page(skip: int, limit: int) -> HTTPResult:
	var endpoint := "%s?skip=%d&limit=%d" % [Config.Endpoints.MAP_EDGES, skip, limit]
	return await _fetch_with_retry(endpoint)


## Fetch with automatic retry on failure
func _fetch_with_retry(endpoint: String) -> HTTPResult:
	var attempts := 0
	var result: HTTPResult

	while attempts < _max_retries:
		result = await HTTPManager.get_request(endpoint)

		if result.success:
			return result

		attempts += 1
		if attempts < _max_retries:
			_log_warning("Request failed (attempt %d/%d): %s - Retrying..." % [
				attempts, _max_retries, result.error_message
			])
			await get_tree().create_timer(_retry_delay).timeout

	_log_error("Request failed after %d attempts: %s" % [_max_retries, result.error_message])
	return result


## Process nodes response and add to network
func _process_nodes_response(data: Variant) -> void:
	if data == null or not data is Dictionary:
		return

	var items := JsonUtils.get_array(data, "items", [])
	for item in items:
		if item is Dictionary:
			var node := NodeData.from_dict(item)
			network.add_node(node)
			_loaded_nodes += 1


## Process edges response and add to network
func _process_edges_response(data: Variant) -> void:
	if data == null or not data is Dictionary:
		return

	var items := JsonUtils.get_array(data, "items", [])
	for item in items:
		if item is Dictionary:
			var edge := EdgeData.from_dict(item)
			network.add_edge(edge)
			_loaded_edges += 1


## Handle loading failure
func _handle_load_failure(error: String) -> void:
	state = LoadingState.FAILED
	last_error = error
	_is_loading = false
	_log_error(error)
	loading_failed.emit(error)


## Clear the cached network data
func clear_network() -> void:
	network.clear()
	is_loaded = false
	state = LoadingState.IDLE
	last_error = ""
	_total_nodes = 0
	_loaded_nodes = 0
	_total_edges = 0
	_loaded_edges = 0
	network_cleared.emit()
	_log_info("Network data cleared")


## Get loading progress as percentage (0.0 to 1.0)
func get_loading_progress() -> float:
	if not _is_loading:
		return 1.0 if is_loaded else 0.0

	var total := _total_nodes + _total_edges
	if total == 0:
		return 0.0

	var loaded := _loaded_nodes + _loaded_edges
	return float(loaded) / float(total)


## Check if currently loading
func is_loading() -> bool:
	return _is_loading


## Get a network node by ID (convenience method)
func get_network_node(id: int) -> NodeData:
	return network.get_node(id)


## Get a network edge by ID (convenience method)
func get_network_edge(id: int) -> EdgeData:
	return network.get_edge(id)


## Get network statistics
func get_network_stats() -> Dictionary:
	return network.get_stats()


## Set page size for pagination
func set_page_size(size: int) -> void:
	_page_size = clampi(size, 100, 5000)


## Set maximum retry attempts
func set_max_retries(retries: int) -> void:
	_max_retries = clampi(retries, 1, 10)


func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[NetworkManager] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[NetworkManager] %s" % message)


func _log_error(message: String) -> void:
	if Config.should_log(Config.LogLevel.ERROR):
		push_error("[NetworkManager] %s" % message)
