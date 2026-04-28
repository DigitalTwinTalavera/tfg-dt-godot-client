## Camera controller for 3D navigation in the Digital Twin
## Supports orbit rotation, zoom, pan, and keyboard movement
class_name CameraController
extends Node3D


## Emitted when the focal point changes
signal focal_point_changed(focal_point: Vector3)
## Emitted when camera is reset to default view
signal camera_reset()


## The camera node to control
@export var camera: Camera3D

## Enable/disable camera controls
@export var enabled: bool = true

## Enable smooth camera movement
@export var smooth_enabled: bool = Config.Camera.SMOOTH_ENABLED

## Enable keyboard movement (WASD)
@export var keyboard_enabled: bool = true


## Current focal point (orbit center)
var _focal_point: Vector3 = Vector3.ZERO

## Current distance from focal point
var _distance: float = Config.Camera.DEFAULT_DISTANCE

## Current orbit angles (in radians)
var _yaw: float = deg_to_rad(Config.Camera.DEFAULT_YAW)
var _pitch: float = deg_to_rad(Config.Camera.DEFAULT_PITCH)

## Target values for smooth interpolation
var _target_focal_point: Vector3 = Vector3.ZERO
var _target_distance: float = Config.Camera.DEFAULT_DISTANCE
var _target_yaw: float = deg_to_rad(Config.Camera.DEFAULT_YAW)
var _target_pitch: float = deg_to_rad(Config.Camera.DEFAULT_PITCH)

## Mouse state
var _is_orbiting: bool = false
var _is_panning: bool = false
var _last_mouse_pos: Vector2 = Vector2.ZERO

## Default view state (for reset)
var _default_focal_point: Vector3 = Vector3.ZERO
var _default_distance: float = Config.Camera.DEFAULT_DISTANCE
var _default_yaw: float = deg_to_rad(Config.Camera.DEFAULT_YAW)
var _default_pitch: float = deg_to_rad(Config.Camera.DEFAULT_PITCH)


func _ready() -> void:
	if not camera:
		# Try to find camera as child
		for child in get_children():
			if child is Camera3D:
				camera = child
				break

	if not camera:
		push_warning("[CameraController] No camera assigned")
		return

	# Initialize camera position
	_update_camera_transform()


func _process(delta: float) -> void:
	if not enabled or not camera:
		return

	# Handle keyboard movement
	if keyboard_enabled:
		_handle_keyboard_movement(delta)

	# Apply smoothing
	if smooth_enabled:
		_apply_smoothing(delta)
	else:
		_focal_point = _target_focal_point
		_distance = _target_distance
		_yaw = _target_yaw
		_pitch = _target_pitch

	# Update camera transform
	_update_camera_transform()


func _unhandled_input(event: InputEvent) -> void:
	if not enabled or not camera:
		return

	# Mouse button events
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)

	# Mouse motion events
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)

	# Keyboard events
	elif event is InputEventKey:
		_handle_key_event(event as InputEventKey)


## Handle mouse button input
func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				# Check if Shift is held for pan mode
				if Input.is_key_pressed(KEY_SHIFT):
					_is_panning = true
					_is_orbiting = false
				else:
					_is_orbiting = true
					_is_panning = false
				_last_mouse_pos = event.position
			else:
				_is_orbiting = false
				_is_panning = false

		MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			if event.pressed:
				_last_mouse_pos = event.position

		MOUSE_BUTTON_WHEEL_UP:
			_zoom(-Config.Camera.ZOOM_SPEED)

		MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(Config.Camera.ZOOM_SPEED)


## Handle mouse motion input
func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var delta := event.position - _last_mouse_pos
	_last_mouse_pos = event.position

	if _is_orbiting:
		_orbit(delta)
	elif _is_panning:
		_pan(delta)


## Handle key events
func _handle_key_event(event: InputEventKey) -> void:
	if event.pressed and not event.echo:
		match event.keycode:
			KEY_HOME:
				reset_camera()


## Handle keyboard movement (WASD, Q/E)
func _handle_keyboard_movement(delta: float) -> void:
	var direction := Vector3.ZERO

	if Input.is_key_pressed(KEY_W):
		direction -= camera.basis.z
	if Input.is_key_pressed(KEY_S):
		direction += camera.basis.z
	if Input.is_key_pressed(KEY_A):
		direction -= camera.basis.x
	if Input.is_key_pressed(KEY_D):
		direction += camera.basis.x
	if Input.is_key_pressed(KEY_Q):
		direction -= Vector3.UP
	if Input.is_key_pressed(KEY_E):
		direction += Vector3.UP

	if direction.length_squared() > 0:
		direction = direction.normalized()

		var speed := Config.Camera.KEYBOARD_MOVE_SPEED
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= Config.Camera.KEYBOARD_SPEED_BOOST

		var movement := direction * speed * delta
		_target_focal_point += movement


## Orbit camera around focal point
func _orbit(delta: Vector2) -> void:
	_target_yaw -= delta.x * Config.Camera.ROTATION_SPEED

	var pitch_delta := delta.y * Config.Camera.ROTATION_SPEED
	if Config.Camera.ORBIT_INVERT_Y:
		pitch_delta = -pitch_delta
	_target_pitch -= pitch_delta

	# Clamp pitch to avoid flipping
	_target_pitch = clampf(
		_target_pitch,
		deg_to_rad(Config.Camera.MIN_PITCH),
		deg_to_rad(Config.Camera.MAX_PITCH)
	)


## Pan camera (move focal point)
func _pan(delta: Vector2) -> void:
	# Calculate pan in camera space
	var right := camera.basis.x
	var up := camera.basis.y

	# Scale pan by distance for consistent feel
	var pan_scale := _target_distance * Config.Camera.PAN_SPEED * Config.Camera.PAN_SCALE_FACTOR

	_target_focal_point -= right * delta.x * pan_scale
	_target_focal_point += up * delta.y * pan_scale

	# Clamp height (focal point can be at ground level but not below)
	_target_focal_point.y = maxf(_target_focal_point.y, 0.0)


## Zoom in/out
func _zoom(amount: float) -> void:
	_target_distance += amount

	# Clamp distance
	_target_distance = clampf(
		_target_distance,
		Config.Camera.ZOOM_MIN_DISTANCE,
		Config.Camera.ZOOM_MAX_DISTANCE
	)


## Apply smooth interpolation
func _apply_smoothing(delta: float) -> void:
	var pos_weight := Config.Camera.SMOOTH_POSITION_WEIGHT * delta
	var rot_weight := Config.Camera.SMOOTH_ROTATION_WEIGHT * delta

	_focal_point = _focal_point.lerp(_target_focal_point, pos_weight)
	_distance = lerpf(_distance, _target_distance, pos_weight)
	_yaw = lerpf(_yaw, _target_yaw, rot_weight)
	_pitch = lerpf(_pitch, _target_pitch, rot_weight)


## Update camera transform based on current state
func _update_camera_transform() -> void:
	if not camera:
		return

	# Calculate camera position using spherical coordinates
	var offset := Vector3.ZERO
	offset.x = _distance * cos(_pitch) * sin(_yaw)
	offset.y = _distance * sin(-_pitch)  # Negative because pitch is negative for looking down
	offset.z = _distance * cos(_pitch) * cos(_yaw)

	var new_position := _focal_point + offset

	# Enforce minimum height
	new_position.y = maxf(new_position.y, Config.Camera.MIN_HEIGHT)

	camera.position = new_position
	camera.look_at(_focal_point)


## Set the focal point (orbit center)
func set_focal_point(point: Vector3) -> void:
	_target_focal_point = point
	if not smooth_enabled:
		_focal_point = point
		_update_camera_transform()
	focal_point_changed.emit(_target_focal_point)


## Get current focal point
func get_focal_point() -> Vector3:
	return _focal_point


## Set the camera distance from focal point
func set_distance(distance: float) -> void:
	_target_distance = clampf(
		distance,
		Config.Camera.ZOOM_MIN_DISTANCE,
		Config.Camera.ZOOM_MAX_DISTANCE
	)
	if not smooth_enabled:
		_distance = _target_distance
		_update_camera_transform()


## Get current distance from focal point
func get_distance() -> float:
	return _distance


## Set orbit angles (in degrees)
func set_orbit_angles(pitch_deg: float, yaw_deg: float) -> void:
	_target_pitch = clampf(
		deg_to_rad(pitch_deg),
		deg_to_rad(Config.Camera.MIN_PITCH),
		deg_to_rad(Config.Camera.MAX_PITCH)
	)
	_target_yaw = deg_to_rad(yaw_deg)

	if not smooth_enabled:
		_pitch = _target_pitch
		_yaw = _target_yaw
		_update_camera_transform()


## Get current orbit angles (in degrees)
func get_orbit_angles() -> Vector2:
	return Vector2(rad_to_deg(_pitch), rad_to_deg(_yaw))


## Focus on a specific position with optional distance
func focus_on(position: Vector3, distance: float = -1.0) -> void:
	set_focal_point(position)
	if distance > 0:
		set_distance(distance)


## Focus camera on network bounds
func focus_on_network(network: RoadNetwork, converter: CoordinateConverter = null) -> void:
	if network.is_empty():
		return

	var center_gps := network.get_center()
	var extent := network.get_extent()

	# Calculate 3D center
	var center_3d: Vector3
	if converter:
		center_3d = converter.gps_to_godot_v2(center_gps)
	else:
		center_3d = Vector3.ZERO

	# Calculate appropriate distance based on extent
	var extent_meters := extent * Config.Coordinates.METERS_PER_DEGREE_LAT
	var max_extent := maxf(extent_meters.x, extent_meters.y)
	var ideal_distance := maxf(max_extent * 0.75, Config.Camera.DEFAULT_DISTANCE)

	# Set as default view
	set_default_view(center_3d, ideal_distance)

	# Apply view
	focus_on(center_3d, ideal_distance)


## Focus on rendered bounds (from renderer)
func focus_on_bounds(bounds: Dictionary) -> void:
	if bounds.is_empty():
		return

	var center: Vector3 = bounds.get("center", Vector3.ZERO)
	var size: Vector3 = bounds.get("size", Vector3.ONE * Config.Camera.BOUNDS_DEFAULT_SIZE)

	var max_size := maxf(size.x, size.z)
	var ideal_distance := maxf(max_size * Config.Camera.BOUNDS_VIEW_MULTIPLIER, Config.Camera.DEFAULT_DISTANCE)

	# Set as default view
	set_default_view(center, ideal_distance)

	# Apply view
	focus_on(center, ideal_distance)


## Set the default view (used by reset)
func set_default_view(
	focal_point: Vector3 = Vector3.ZERO,
	distance: float = Config.Camera.DEFAULT_DISTANCE,
	pitch_deg: float = Config.Camera.DEFAULT_PITCH,
	yaw_deg: float = Config.Camera.DEFAULT_YAW
) -> void:
	_default_focal_point = focal_point
	_default_distance = distance
	_default_pitch = deg_to_rad(pitch_deg)
	_default_yaw = deg_to_rad(yaw_deg)


## Reset camera to default view
func reset_camera() -> void:
	_target_focal_point = _default_focal_point
	_target_distance = _default_distance
	_target_pitch = _default_pitch
	_target_yaw = _default_yaw

	if not smooth_enabled:
		_focal_point = _target_focal_point
		_distance = _target_distance
		_pitch = _target_pitch
		_yaw = _target_yaw
		_update_camera_transform()

	camera_reset.emit()


## Instantly apply target values (skip smoothing)
func apply_instantly() -> void:
	_focal_point = _target_focal_point
	_distance = _target_distance
	_pitch = _target_pitch
	_yaw = _target_yaw
	_update_camera_transform()


## Get camera info for debugging
func get_debug_info() -> String:
	var info := ""
	info += "Focal Point: (%.1f, %.1f, %.1f)\n" % [_focal_point.x, _focal_point.y, _focal_point.z]
	info += "Distance: %.1f m\n" % _distance
	info += "Pitch: %.1f°  Yaw: %.1f°\n" % [rad_to_deg(_pitch), rad_to_deg(_yaw)]
	if camera:
		info += "Camera Pos: (%.1f, %.1f, %.1f)\n" % [camera.position.x, camera.position.y, camera.position.z]
	return info
