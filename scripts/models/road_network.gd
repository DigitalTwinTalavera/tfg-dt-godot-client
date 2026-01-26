## Container class for the complete road network
## Manages collections of nodes and edges with indexing
class_name RoadNetwork
extends RefCounted


## All nodes indexed by ID
var nodes: Dictionary = {}  # int -> NodeData

## All edges indexed by ID
var edges: Dictionary = {}  # int -> EdgeData

## Edges indexed by start node for quick lookup
var edges_by_start_node: Dictionary = {}  # int -> Array[EdgeData]

## Edges indexed by end node for quick lookup
var edges_by_end_node: Dictionary = {}  # int -> Array[EdgeData]

## Bounding box of the network
var bounds_min: Vector2 = Vector2.INF
var bounds_max: Vector2 = -Vector2.INF

## Statistics
var _stats: Dictionary = {}


## Clear all data
func clear() -> void:
	nodes.clear()
	edges.clear()
	edges_by_start_node.clear()
	edges_by_end_node.clear()
	bounds_min = Vector2.INF
	bounds_max = -Vector2.INF
	_stats.clear()


## Add a node to the network
func add_node(node: NodeData) -> void:
	nodes[node.id] = node
	_update_bounds_for_point(node.longitude, node.latitude)


## Add multiple nodes at once
func add_nodes(node_list: Array) -> void:
	for node in node_list:
		if node is NodeData:
			add_node(node)


## Add an edge to the network
func add_edge(edge: EdgeData) -> void:
	edges[edge.id] = edge

	# Index by start node
	if not edges_by_start_node.has(edge.start_node_id):
		edges_by_start_node[edge.start_node_id] = []
	edges_by_start_node[edge.start_node_id].append(edge)

	# Index by end node
	if not edges_by_end_node.has(edge.end_node_id):
		edges_by_end_node[edge.end_node_id] = []
	edges_by_end_node[edge.end_node_id].append(edge)

	# Update bounds from geometry
	for coord in edge.geometry:
		if coord is Array and coord.size() >= 2:
			_update_bounds_for_point(float(coord[0]), float(coord[1]))


## Add multiple edges at once
func add_edges(edge_list: Array) -> void:
	for edge in edge_list:
		if edge is EdgeData:
			add_edge(edge)


## Get a node by ID
func get_node(id: int) -> NodeData:
	return nodes.get(id, null)


## Get an edge by ID
func get_edge(id: int) -> EdgeData:
	return edges.get(id, null)


## Get all edges starting from a node
func get_outgoing_edges(node_id: int) -> Array:
	return edges_by_start_node.get(node_id, [])


## Get all edges ending at a node
func get_incoming_edges(node_id: int) -> Array:
	return edges_by_end_node.get(node_id, [])


## Get all edges connected to a node (both directions)
func get_connected_edges(node_id: int) -> Array:
	var result := []
	result.append_array(get_outgoing_edges(node_id))
	result.append_array(get_incoming_edges(node_id))
	return result


## Get number of nodes
func get_node_count() -> int:
	return nodes.size()


## Get number of edges
func get_edge_count() -> int:
	return edges.size()


## Check if network is empty
func is_empty() -> bool:
	return nodes.is_empty() and edges.is_empty()


## Check if network has data
func has_data() -> bool:
	return not is_empty()


## Get the center point of the network
func get_center() -> Vector2:
	if bounds_min == Vector2.INF or bounds_max == -Vector2.INF:
		return Vector2.ZERO
	return (bounds_min + bounds_max) / 2.0


## Get the geographic extent (width, height in degrees)
func get_extent() -> Vector2:
	if bounds_min == Vector2.INF or bounds_max == -Vector2.INF:
		return Vector2.ZERO
	return bounds_max - bounds_min


## Get network statistics
func get_stats() -> Dictionary:
	if _stats.is_empty():
		_calculate_stats()
	return _stats


## Get all node IDs
func get_node_ids() -> Array:
	return nodes.keys()


## Get all edge IDs
func get_edge_ids() -> Array:
	return edges.keys()


## Get nodes by type
func get_nodes_by_type(node_type: NodeData.NodeType) -> Array[NodeData]:
	var result: Array[NodeData] = []
	for node_id in nodes.keys():
		var node: NodeData = nodes[node_id]
		if node.node_type == node_type:
			result.append(node)
	return result


## Get edges by type
func get_edges_by_type(road_type: EdgeData.RoadType) -> Array[EdgeData]:
	var result: Array[EdgeData] = []
	for edge_id in edges.keys():
		var edge: EdgeData = edges[edge_id]
		if edge.road_type == road_type:
			result.append(edge)
	return result


## Find nodes within a bounding box
func find_nodes_in_bounds(min_pos: Vector2, max_pos: Vector2) -> Array[NodeData]:
	var result: Array[NodeData] = []
	for node_id in nodes.keys():
		var node: NodeData = nodes[node_id]
		var pos: Vector2 = node.get_position_vector2()
		if pos.x >= min_pos.x and pos.x <= max_pos.x and pos.y >= min_pos.y and pos.y <= max_pos.y:
			result.append(node)
	return result


## Validate network integrity
func validate() -> Dictionary:
	var issues := []
	var valid := true

	# Check for edges referencing non-existent nodes
	for edge_id in edges.keys():
		var edge: EdgeData = edges[edge_id]
		if not nodes.has(edge.start_node_id):
			issues.append("Edge %d references missing start node %d" % [edge.id, edge.start_node_id])
			valid = false
		if not nodes.has(edge.end_node_id):
			issues.append("Edge %d references missing end node %d" % [edge.id, edge.end_node_id])
			valid = false

	# Check for nodes with no edges
	var connected_nodes := {}
	for edge_id in edges.keys():
		var edge: EdgeData = edges[edge_id]
		connected_nodes[edge.start_node_id] = true
		connected_nodes[edge.end_node_id] = true

	var orphan_count := 0
	for node_id in nodes.keys():
		if not connected_nodes.has(node_id):
			orphan_count += 1

	if orphan_count > 0:
		issues.append("%d orphan nodes (no connected edges)" % orphan_count)

	return {
		"valid": valid,
		"issues": issues,
		"orphan_nodes": orphan_count
	}


## Update bounds for a single point
func _update_bounds_for_point(lon: float, lat: float) -> void:
	bounds_min.x = min(bounds_min.x, lon)
	bounds_min.y = min(bounds_min.y, lat)
	bounds_max.x = max(bounds_max.x, lon)
	bounds_max.y = max(bounds_max.y, lat)


## Calculate network statistics
func _calculate_stats() -> void:
	_stats = {
		"node_count": nodes.size(),
		"edge_count": edges.size(),
		"bounds_min": bounds_min,
		"bounds_max": bounds_max,
		"center": get_center(),
		"extent": get_extent()
	}

	# Count node types
	var node_types := {}
	for node_id in nodes.keys():
		var node: NodeData = nodes[node_id]
		var type_name: String = NodeData.NodeType.keys()[node.node_type]
		node_types[type_name] = node_types.get(type_name, 0) + 1
	_stats["node_types"] = node_types

	# Count road types
	var road_types := {}
	for edge_id in edges.keys():
		var edge: EdgeData = edges[edge_id]
		var type_name: String = EdgeData.RoadType.keys()[edge.road_type]
		road_types[type_name] = road_types.get(type_name, 0) + 1
	_stats["road_types"] = road_types

	# Calculate total road length
	var total_length := 0.0
	for edge_id in edges.keys():
		var edge: EdgeData = edges[edge_id]
		total_length += edge.length
	_stats["total_length_meters"] = total_length
	_stats["total_length_km"] = total_length / 1000.0


## String representation
func _to_string() -> String:
	return "RoadNetwork(nodes=%d, edges=%d, bounds=[%.4f,%.4f]-[%.4f,%.4f])" % [
		nodes.size(),
		edges.size(),
		bounds_min.x, bounds_min.y,
		bounds_max.x, bounds_max.y
	]
