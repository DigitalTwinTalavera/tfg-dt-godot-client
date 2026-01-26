## Data class representing a road network node
## Maps to NodeModel from the backend
class_name NodeData
extends RefCounted


## Node type enumeration matching backend NodeType
enum NodeType {
	INTERSECTION,
	TRAFFIC_LIGHT,
	ROUNDABOUT,
	DEAD_END,
	ENTRY_POINT,
	EXIT_POINT,
	UNKNOWN
}


## Unique identifier from database
var id: int = 0

## Optional name of the node
var name: String = ""

## Type of node (intersection, traffic_light, etc.)
var node_type: NodeType = NodeType.INTERSECTION

## Geographic position (longitude, latitude)
var longitude: float = 0.0
var latitude: float = 0.0

## Whether the node is active in simulation
var is_active: bool = true

## Additional metadata from OSM
var metadata: Dictionary = {}


## Create NodeData from API response dictionary
static func from_dict(data: Dictionary) -> NodeData:
	var node := NodeData.new()

	node.id = JsonUtils.get_int(data, "id", 0)
	node.name = JsonUtils.get_string(data, "name", "")
	node.node_type = _parse_node_type(JsonUtils.get_string(data, "node_type", "intersection"))
	node.is_active = JsonUtils.get_bool(data, "is_active", true)

	# Parse GeoJSON position
	var position := JsonUtils.get_dict(data, "position", {})
	var coordinates := JsonUtils.get_array(position, "coordinates", [])
	if coordinates.size() >= 2:
		node.longitude = float(coordinates[0])
		node.latitude = float(coordinates[1])

	# Parse metadata if present
	var metadata_json := JsonUtils.get_string(data, "metadata_json", "")
	if not metadata_json.is_empty():
		var parse_result := JsonUtils.parse(metadata_json)
		if parse_result.success:
			node.metadata = parse_result.data

	return node


## Convert to dictionary for debugging/serialization
func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"node_type": NodeType.keys()[node_type],
		"longitude": longitude,
		"latitude": latitude,
		"is_active": is_active,
		"metadata": metadata
	}


## Get position as Vector2 (lon, lat)
func get_position_vector2() -> Vector2:
	return Vector2(longitude, latitude)


## Get human-readable node type string
func get_type_string() -> String:
	return NodeType.keys()[node_type].capitalize().replace("_", " ")


## Check if this node has valid coordinates
func has_valid_position() -> bool:
	return longitude != 0.0 or latitude != 0.0


## Parse node type string from backend to enum
static func _parse_node_type(node_type_str: String) -> NodeType:
	match node_type_str.to_lower():
		"intersection":
			return NodeType.INTERSECTION
		"traffic_light":
			return NodeType.TRAFFIC_LIGHT
		"roundabout":
			return NodeType.ROUNDABOUT
		"dead_end":
			return NodeType.DEAD_END
		"entry_point":
			return NodeType.ENTRY_POINT
		"exit_point":
			return NodeType.EXIT_POINT
		_:
			return NodeType.UNKNOWN


## String representation for debugging
func _to_string() -> String:
	return "NodeData(id=%d, type=%s, pos=[%.6f, %.6f])" % [
		id,
		NodeType.keys()[node_type],
		longitude,
		latitude
	]
