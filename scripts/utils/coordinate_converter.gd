## Coordinate Converter for GPS to Godot 3D space transformation
## Converts lat/lon (EPSG:4326) to local meters centered at origin
##
## Mathematical Foundation:
## - Uses simplified Web Mercator projection
## - METERS_PER_DEGREE_LAT ≈ 111,320 meters (constant)
## - METERS_PER_DEGREE_LON ≈ 111,320 * cos(latitude) meters (varies with latitude)
##
## Coordinate Systems:
## - GPS: (longitude, latitude) in degrees, WGS84 EPSG:4326
## - Godot: (x, y, z) in meters where:
##   - X = East-West (positive = East)
##   - Y = Up (elevation, default 0)
##   - Z = North-South (positive = South, Godot's -Z is forward/North)
##
## Usage:
##   var converter = CoordinateConverter.new()
##   converter.set_bounds(min_lon, min_lat, max_lon, max_lat)
##   # or
##   converter.set_center(center_lon, center_lat)
##   var godot_pos = converter.gps_to_godot(longitude, latitude)
##   var gps_pos = converter.godot_to_gps(godot_pos)
class_name CoordinateConverter
extends RefCounted


## Meters per degree of latitude (approximately constant)
const METERS_PER_DEGREE_LAT: float = 111320.0

## Earth's radius in meters (for more precise calculations)
const EARTH_RADIUS_METERS: float = 6371000.0

## Degrees to radians conversion factor
const DEG_TO_RAD: float = PI / 180.0

## Radians to degrees conversion factor
const RAD_TO_DEG: float = 180.0 / PI


## Center point in GPS coordinates (used as origin)
var center_longitude: float = 0.0
var center_latitude: float = 0.0

## Bounding box in GPS coordinates
var bounds_min: Vector2 = Vector2.ZERO  # (min_lon, min_lat)
var bounds_max: Vector2 = Vector2.ZERO  # (max_lon, max_lat)

## Cached meters per degree at center latitude
var _meters_per_degree_lon: float = METERS_PER_DEGREE_LAT

## Whether the converter has been initialized
var _is_initialized: bool = false


## Initialize with a center point
## The center becomes (0, 0, 0) in Godot space
func set_center(longitude: float, latitude: float) -> void:
	center_longitude = longitude
	center_latitude = latitude
	_update_scale_factor()
	_is_initialized = true


## Initialize with bounding box
## Automatically calculates center and sets up conversion
func set_bounds(min_lon: float, min_lat: float, max_lon: float, max_lat: float) -> void:
	bounds_min = Vector2(min_lon, min_lat)
	bounds_max = Vector2(max_lon, max_lat)

	# Calculate center
	center_longitude = (min_lon + max_lon) / 2.0
	center_latitude = (min_lat + max_lat) / 2.0

	_update_scale_factor()
	_is_initialized = true


## Initialize from a RoadNetwork's bounds
func set_bounds_from_network(network: RoadNetwork) -> void:
	if network.bounds_min == Vector2.INF or network.bounds_max == -Vector2.INF:
		push_warning("CoordinateConverter: Network has no valid bounds")
		return

	set_bounds(
		network.bounds_min.x,  # min_lon
		network.bounds_min.y,  # min_lat
		network.bounds_max.x,  # max_lon
		network.bounds_max.y   # max_lat
	)


## Update the longitude scale factor based on center latitude
func _update_scale_factor() -> void:
	# At the equator, 1 degree lon = 1 degree lat in meters
	# At higher latitudes, longitude degrees become "smaller"
	_meters_per_degree_lon = METERS_PER_DEGREE_LAT * cos(center_latitude * DEG_TO_RAD)


## Convert GPS coordinates (lon, lat) to Godot 3D position
## Returns Vector3 where:
## - X = meters East of center (positive = East)
## - Y = elevation (always 0 unless specified)
## - Z = meters South of center (positive = South, -Z = North)
func gps_to_godot(longitude: float, latitude: float, elevation: float = 0.0) -> Vector3:
	if not _is_initialized:
		push_warning("CoordinateConverter: Not initialized. Call set_center() or set_bounds() first.")
		return Vector3.ZERO

	# Calculate offset from center in degrees
	var delta_lon := longitude - center_longitude
	var delta_lat := latitude - center_latitude

	# Convert to meters
	var x := delta_lon * _meters_per_degree_lon  # East-West
	var z := -delta_lat * METERS_PER_DEGREE_LAT  # North-South (inverted for Godot)

	return Vector3(x, elevation, z)


## Convert GPS coordinates from Vector2(lon, lat) to Godot Vector3
func gps_to_godot_v2(gps_coords: Vector2, elevation: float = 0.0) -> Vector3:
	return gps_to_godot(gps_coords.x, gps_coords.y, elevation)


## Convert Godot 3D position to GPS coordinates
## Returns Vector2(longitude, latitude)
func godot_to_gps(position: Vector3) -> Vector2:
	if not _is_initialized:
		push_warning("CoordinateConverter: Not initialized. Call set_center() or set_bounds() first.")
		return Vector2.ZERO

	# Convert from meters to degrees
	var delta_lon := position.x / _meters_per_degree_lon
	var delta_lat := -position.z / METERS_PER_DEGREE_LAT  # Inverted back

	return Vector2(
		center_longitude + delta_lon,
		center_latitude + delta_lat
	)


## Convert Godot 3D position to GPS coordinates with elevation
## Returns Vector3(longitude, latitude, elevation)
func godot_to_gps_with_elevation(position: Vector3) -> Vector3:
	var gps := godot_to_gps(position)
	return Vector3(gps.x, gps.y, position.y)


## Batch convert GPS coordinates to Godot positions
## Input: Array of Vector2(lon, lat) or Array of [lon, lat]
## Output: Array of Vector3
func batch_gps_to_godot(gps_coords: Array, elevation: float = 0.0) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.resize(gps_coords.size())

	for i in range(gps_coords.size()):
		var coord = gps_coords[i]
		if coord is Vector2:
			result[i] = gps_to_godot_v2(coord, elevation)
		elif coord is Array and coord.size() >= 2:
			result[i] = gps_to_godot(float(coord[0]), float(coord[1]), elevation)
		else:
			result[i] = Vector3.ZERO

	return result


## Batch convert Godot positions to GPS coordinates
## Input: Array of Vector3
## Output: Array of Vector2(lon, lat)
func batch_godot_to_gps(positions: Array[Vector3]) -> Array[Vector2]:
	var result: Array[Vector2] = []
	result.resize(positions.size())

	for i in range(positions.size()):
		result[i] = godot_to_gps(positions[i])

	return result


## Get the size of the bounding box in meters
## Returns Vector2(width_meters, height_meters)
func get_bounds_size_meters() -> Vector2:
	if bounds_min == Vector2.ZERO and bounds_max == Vector2.ZERO:
		return Vector2.ZERO

	var width := (bounds_max.x - bounds_min.x) * _meters_per_degree_lon
	var height := (bounds_max.y - bounds_min.y) * METERS_PER_DEGREE_LAT

	return Vector2(width, height)


## Get the network extent in Godot coordinates
## Returns Dictionary with min, max, size as Vector3
func get_godot_bounds() -> Dictionary:
	if not _is_initialized:
		return {"min": Vector3.ZERO, "max": Vector3.ZERO, "size": Vector3.ZERO}

	var min_pos := gps_to_godot(bounds_min.x, bounds_min.y)
	var max_pos := gps_to_godot(bounds_max.x, bounds_max.y)

	# Ensure min/max are correct (Z is inverted)
	var actual_min := Vector3(
		min(min_pos.x, max_pos.x),
		0,
		min(min_pos.z, max_pos.z)
	)
	var actual_max := Vector3(
		max(min_pos.x, max_pos.x),
		0,
		max(min_pos.z, max_pos.z)
	)

	return {
		"min": actual_min,
		"max": actual_max,
		"size": actual_max - actual_min
	}


## Calculate distance between two GPS points in meters (Haversine formula)
func gps_distance_meters(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
	var lat1_rad := lat1 * DEG_TO_RAD
	var lat2_rad := lat2 * DEG_TO_RAD
	var delta_lat := (lat2 - lat1) * DEG_TO_RAD
	var delta_lon := (lon2 - lon1) * DEG_TO_RAD

	var a := sin(delta_lat / 2.0) * sin(delta_lat / 2.0) + \
			 cos(lat1_rad) * cos(lat2_rad) * \
			 sin(delta_lon / 2.0) * sin(delta_lon / 2.0)
	var c := 2.0 * atan2(sqrt(a), sqrt(1.0 - a))

	return EARTH_RADIUS_METERS * c


## Calculate distance between two GPS points given as Vector2(lon, lat)
func gps_distance_meters_v2(point1: Vector2, point2: Vector2) -> float:
	return gps_distance_meters(point1.x, point1.y, point2.x, point2.y)


## Get the current scale factor (meters per degree longitude at center)
func get_meters_per_degree_lon() -> float:
	return _meters_per_degree_lon


## Get the constant meters per degree latitude
func get_meters_per_degree_lat() -> float:
	return METERS_PER_DEGREE_LAT


## Check if converter is initialized
func is_initialized() -> bool:
	return _is_initialized


## Get center as Vector2(lon, lat)
func get_center_gps() -> Vector2:
	return Vector2(center_longitude, center_latitude)


## Get center in Godot space (always origin if properly initialized)
func get_center_godot() -> Vector3:
	return Vector3.ZERO


## String representation for debugging
func _to_string() -> String:
	if not _is_initialized:
		return "CoordinateConverter(not initialized)"

	return "CoordinateConverter(center=[%.6f, %.6f], meters_per_deg_lon=%.2f)" % [
		center_longitude,
		center_latitude,
		_meters_per_degree_lon
	]
