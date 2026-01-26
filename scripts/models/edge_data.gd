## Data class representing a road network edge (street segment)
## Maps to EdgeModel from the backend
class_name EdgeData
extends RefCounted


## Road type enumeration matching backend RoadType
enum RoadType {
	MOTORWAY,
	MOTORWAY_LINK,
	TRUNK,
	TRUNK_LINK,
	PRIMARY,
	PRIMARY_LINK,
	SECONDARY,
	SECONDARY_LINK,
	TERTIARY,
	TERTIARY_LINK,
	RESIDENTIAL,
	SERVICE,
	UNCLASSIFIED,
	LIVING_STREET,
	UNKNOWN
}


## Unique identifier from database
var id: int = 0

## Street name
var name: String = ""

## Reference to start node ID
var start_node_id: int = 0

## Reference to end node ID
var end_node_id: int = 0

## Type of road
var road_type: RoadType = RoadType.RESIDENTIAL

## Geometry as array of coordinate pairs [[lon, lat], ...]
var geometry: Array = []

## Length in meters
var length: float = 0.0

## Maximum speed in km/h
var max_speed: int = 50

## Number of lanes
var lanes: int = 1

## Whether the road is one-way
var one_way: bool = false

## Whether the edge is active in simulation
var is_active: bool = true

## Additional metadata from OSM
var metadata: Dictionary = {}


## Create EdgeData from API response dictionary
static func from_dict(data: Dictionary) -> EdgeData:
	var edge := EdgeData.new()

	edge.id = JsonUtils.get_int(data, "id", 0)
	edge.name = JsonUtils.get_string(data, "name", "")
	edge.start_node_id = JsonUtils.get_int(data, "start_node_id", 0)
	edge.end_node_id = JsonUtils.get_int(data, "end_node_id", 0)
	edge.road_type = _parse_road_type(JsonUtils.get_string(data, "road_type", "residential"))
	edge.length = JsonUtils.get_float(data, "length", 0.0)
	edge.max_speed = JsonUtils.get_int(data, "max_speed", 50)
	edge.lanes = JsonUtils.get_int(data, "lanes", 1)
	edge.one_way = JsonUtils.get_bool(data, "one_way", false)
	edge.is_active = JsonUtils.get_bool(data, "is_active", true)

	# Parse GeoJSON geometry
	var geom := JsonUtils.get_dict(data, "geometry", {})
	var coordinates := JsonUtils.get_array(geom, "coordinates", [])
	edge.geometry = coordinates

	# Parse metadata if present
	var metadata_json := JsonUtils.get_string(data, "metadata_json", "")
	if not metadata_json.is_empty():
		var parse_result := JsonUtils.parse(metadata_json)
		if parse_result.success:
			edge.metadata = parse_result.data

	return edge


## Convert to dictionary for debugging/serialization
func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"start_node_id": start_node_id,
		"end_node_id": end_node_id,
		"road_type": RoadType.keys()[road_type],
		"geometry_points": geometry.size(),
		"length": length,
		"max_speed": max_speed,
		"lanes": lanes,
		"one_way": one_way,
		"is_active": is_active
	}


## Get geometry as array of Vector2 (lon, lat)
func get_geometry_vectors() -> Array[Vector2]:
	var vectors: Array[Vector2] = []
	for coord in geometry:
		if coord is Array and coord.size() >= 2:
			vectors.append(Vector2(float(coord[0]), float(coord[1])))
	return vectors


## Get the start position (first coordinate)
func get_start_position() -> Vector2:
	if geometry.size() > 0 and geometry[0] is Array and geometry[0].size() >= 2:
		return Vector2(float(geometry[0][0]), float(geometry[0][1]))
	return Vector2.ZERO


## Get the end position (last coordinate)
func get_end_position() -> Vector2:
	if geometry.size() > 0:
		var last = geometry[geometry.size() - 1]
		if last is Array and last.size() >= 2:
			return Vector2(float(last[0]), float(last[1]))
	return Vector2.ZERO


## Get human-readable road type string
func get_type_string() -> String:
	return RoadType.keys()[road_type].capitalize().replace("_", " ")


## Check if this edge has valid geometry
func has_valid_geometry() -> bool:
	return geometry.size() >= 2


## Get approximate center point of the edge
func get_center_position() -> Vector2:
	if geometry.is_empty():
		return Vector2.ZERO

	var sum := Vector2.ZERO
	var count := 0
	for coord in geometry:
		if coord is Array and coord.size() >= 2:
			sum += Vector2(float(coord[0]), float(coord[1]))
			count += 1

	if count > 0:
		return sum / count
	return Vector2.ZERO


## Parse road type string from backend to enum
static func _parse_road_type(type_string: String) -> RoadType:
	match type_string.to_lower():
		"motorway":
			return RoadType.MOTORWAY
		"motorway_link":
			return RoadType.MOTORWAY_LINK
		"trunk":
			return RoadType.TRUNK
		"trunk_link":
			return RoadType.TRUNK_LINK
		"primary":
			return RoadType.PRIMARY
		"primary_link":
			return RoadType.PRIMARY_LINK
		"secondary":
			return RoadType.SECONDARY
		"secondary_link":
			return RoadType.SECONDARY_LINK
		"tertiary":
			return RoadType.TERTIARY
		"tertiary_link":
			return RoadType.TERTIARY_LINK
		"residential":
			return RoadType.RESIDENTIAL
		"service":
			return RoadType.SERVICE
		"unclassified":
			return RoadType.UNCLASSIFIED
		"living_street":
			return RoadType.LIVING_STREET
		_:
			return RoadType.UNKNOWN


## Get a color associated with this road type (for visualization)
func get_road_color() -> Color:
	match road_type:
		RoadType.MOTORWAY, RoadType.MOTORWAY_LINK:
			return Config.RoadColors.MOTORWAY
		RoadType.TRUNK, RoadType.TRUNK_LINK:
			return Config.RoadColors.TRUNK
		RoadType.PRIMARY, RoadType.PRIMARY_LINK:
			return Config.RoadColors.PRIMARY
		RoadType.SECONDARY, RoadType.SECONDARY_LINK:
			return Config.RoadColors.SECONDARY
		RoadType.TERTIARY, RoadType.TERTIARY_LINK:
			return Config.RoadColors.TERTIARY
		RoadType.RESIDENTIAL:
			return Config.RoadColors.RESIDENTIAL
		RoadType.SERVICE:
			return Config.RoadColors.SERVICE
		_:
			return Config.RoadColors.UNKNOWN


## String representation for debugging
func _to_string() -> String:
	return "EdgeData(id=%d, name='%s', type=%s, nodes=%d->%d, points=%d)" % [
		id,
		name,
		RoadType.keys()[road_type],
		start_node_id,
		end_node_id,
		geometry.size()
	]
