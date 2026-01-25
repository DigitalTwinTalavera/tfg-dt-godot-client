## Utility class for JSON parsing and manipulation
## Provides safe parsing methods with error handling
class_name JsonUtils
extends RefCounted


## Result of a JSON parse operation
class ParseResult:
	var success: bool = false
	var data: Variant = null
	var error: String = ""
	var error_line: int = -1

	static func ok(parsed_data: Variant) -> ParseResult:
		var result := ParseResult.new()
		result.success = true
		result.data = parsed_data
		return result

	static func fail(error_msg: String, line: int = -1) -> ParseResult:
		var result := ParseResult.new()
		result.success = false
		result.error = error_msg
		result.error_line = line
		return result


## Parse JSON string safely with error handling
static func parse(json_string: String) -> ParseResult:
	if json_string.is_empty():
		return ParseResult.fail("Empty JSON string")

	var json := JSON.new()
	var error := json.parse(json_string)

	if error != OK:
		return ParseResult.fail(
			"Parse error: %s" % json.get_error_message(),
			json.get_error_line()
		)

	return ParseResult.ok(json.data)


## Parse JSON and return data directly, or default value on failure
static func parse_or_default(json_string: String, default: Variant = null) -> Variant:
	var result := parse(json_string)
	return result.data if result.success else default


## Stringify data to JSON with optional pretty print
static func stringify(data: Variant, pretty: bool = false) -> String:
	if pretty:
		return JSON.stringify(data, "\t")
	return JSON.stringify(data)


## Safely get a value from a dictionary with a default
static func get_value(dict: Dictionary, key: String, default: Variant = null) -> Variant:
	return dict.get(key, default)


## Safely get a nested value using dot notation (e.g., "user.profile.name")
static func get_nested(dict: Dictionary, path: String, default: Variant = null) -> Variant:
	var keys := path.split(".")
	var current: Variant = dict

	for key in keys:
		if current is Dictionary and current.has(key):
			current = current[key]
		else:
			return default

	return current


## Check if dictionary has a key with non-null value
static func has_value(dict: Dictionary, key: String) -> bool:
	return dict.has(key) and dict[key] != null


## Safely get string value
static func get_string(dict: Dictionary, key: String, default: String = "") -> String:
	var value = dict.get(key, default)
	return str(value) if value != null else default


## Safely get int value
static func get_int(dict: Dictionary, key: String, default: int = 0) -> int:
	var value = dict.get(key, default)
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String and value.is_valid_int():
		return value.to_int()
	return default


## Safely get float value
static func get_float(dict: Dictionary, key: String, default: float = 0.0) -> float:
	var value = dict.get(key, default)
	if value is float:
		return value
	if value is int:
		return float(value)
	if value is String and value.is_valid_float():
		return value.to_float()
	return default


## Safely get bool value
static func get_bool(dict: Dictionary, key: String, default: bool = false) -> bool:
	var value = dict.get(key, default)
	if value is bool:
		return value
	if value is String:
		return value.to_lower() in ["true", "1", "yes"]
	if value is int:
		return value != 0
	return default


## Safely get array value
static func get_array(dict: Dictionary, key: String, default: Array = []) -> Array:
	var value = dict.get(key, default)
	return value if value is Array else default


## Safely get dictionary value
static func get_dict(dict: Dictionary, key: String, default: Dictionary = {}) -> Dictionary:
	var value = dict.get(key, default)
	return value if value is Dictionary else default


## Merge two dictionaries (second overwrites first)
static func merge(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for key in overlay:
		result[key] = overlay[key]
	return result


## Deep merge dictionaries (recursive)
static func deep_merge(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var result := base.duplicate(true)
	for key in overlay:
		if result.has(key) and result[key] is Dictionary and overlay[key] is Dictionary:
			result[key] = deep_merge(result[key], overlay[key])
		else:
			result[key] = overlay[key]
	return result


## Convert dictionary keys from snake_case to camelCase
static func to_camel_case(dict: Dictionary) -> Dictionary:
	var result := {}
	for key in dict:
		var new_key := _snake_to_camel(str(key))
		var value = dict[key]
		if value is Dictionary:
			result[new_key] = to_camel_case(value)
		elif value is Array:
			result[new_key] = _convert_array_keys(value, true)
		else:
			result[new_key] = value
	return result


## Convert dictionary keys from camelCase to snake_case
static func to_snake_case(dict: Dictionary) -> Dictionary:
	var result := {}
	for key in dict:
		var new_key := _camel_to_snake(str(key))
		var value = dict[key]
		if value is Dictionary:
			result[new_key] = to_snake_case(value)
		elif value is Array:
			result[new_key] = _convert_array_keys(value, false)
		else:
			result[new_key] = value
	return result


static func _snake_to_camel(snake: String) -> String:
	var parts := snake.split("_")
	var result := parts[0]
	for i in range(1, parts.size()):
		result += parts[i].capitalize()
	return result


static func _camel_to_snake(camel: String) -> String:
	var result := ""
	for i in range(camel.length()):
		var c := camel[i]
		if c == c.to_upper() and i > 0:
			result += "_"
		result += c.to_lower()
	return result


static func _convert_array_keys(arr: Array, to_camel: bool) -> Array:
	var result := []
	for item in arr:
		if item is Dictionary:
			result.append(to_camel_case(item) if to_camel else to_snake_case(item))
		elif item is Array:
			result.append(_convert_array_keys(item, to_camel))
		else:
			result.append(item)
	return result
