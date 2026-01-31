## Test scene for CameraController
## Demonstrates camera controls in a 3D environment with reference objects
extends Node3D


## UI References
@onready var info_label: RichTextLabel = $UI/PanelContainer/VBoxContainer/InfoLabel
@onready var fps_label: Label = $UI/FPSLabel
@onready var smooth_check: CheckBox = $UI/PanelContainer/VBoxContainer/SmoothCheck
@onready var keyboard_check: CheckBox = $UI/PanelContainer/VBoxContainer/KeyboardCheck
@onready var reset_button: Button = $UI/PanelContainer/VBoxContainer/ResetButton
@onready var focus_origin_button: Button = $UI/PanelContainer/VBoxContainer/FocusOriginButton
@onready var focus_marker_button: Button = $UI/PanelContainer/VBoxContainer/FocusMarkerButton
@onready var back_button: Button = $UI/PanelContainer/VBoxContainer/BackButton

## 3D References
@onready var camera_controller: CameraController = $CameraRig
@onready var marker: Node3D = $Marker

## Performance tracking
var _frame_times: Array[float] = []
var _max_frame_samples: int = 60


func _ready() -> void:
	_connect_signals()
	_setup_initial_state()
	_create_reference_objects()


func _connect_signals() -> void:
	smooth_check.toggled.connect(_on_smooth_toggled)
	keyboard_check.toggled.connect(_on_keyboard_toggled)
	reset_button.pressed.connect(_on_reset_pressed)
	focus_origin_button.pressed.connect(_on_focus_origin_pressed)
	focus_marker_button.pressed.connect(_on_focus_marker_pressed)
	back_button.pressed.connect(_on_back_pressed)

	camera_controller.camera_moved.connect(_on_camera_moved)
	camera_controller.camera_reset.connect(_on_camera_reset)
	camera_controller.focal_point_changed.connect(_on_focal_point_changed)


func _setup_initial_state() -> void:
	smooth_check.button_pressed = camera_controller.smooth_enabled
	keyboard_check.button_pressed = camera_controller.keyboard_enabled

	# Set default view centered on origin
	camera_controller.set_default_view(Vector3.ZERO, 500.0)
	camera_controller.reset_camera()
	camera_controller.apply_instantly()


func _create_reference_objects() -> void:
	# Create grid of reference cubes to help visualize camera movement
	var grid_size := 5
	var spacing := 200.0

	for x in range(-grid_size, grid_size + 1):
		for z in range(-grid_size, grid_size + 1):
			if x == 0 and z == 0:
				continue  # Skip center (marker is there)

			var cube := _create_reference_cube(
				Vector3(x * spacing, 0, z * spacing),
				Color(0.3, 0.3, 0.3) if (x + z) % 2 == 0 else Color(0.5, 0.5, 0.5)
			)
			add_child(cube)

	# Create axis indicators at origin
	_create_axis_indicator()


func _create_reference_cube(pos: Vector3, color: Color) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(20, 20, 20)
	mesh_instance.mesh = box

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh_instance.material_override = material

	mesh_instance.position = pos
	return mesh_instance


func _create_axis_indicator() -> void:
	# X axis (red)
	var x_axis := _create_axis_line(Vector3(100, 0, 0), Color.RED)
	add_child(x_axis)

	# Y axis (green)
	var y_axis := _create_axis_line(Vector3(0, 100, 0), Color.GREEN)
	add_child(y_axis)

	# Z axis (blue)
	var z_axis := _create_axis_line(Vector3(0, 0, 100), Color.BLUE)
	add_child(z_axis)


func _create_axis_line(direction: Vector3, color: Color) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 2.0
	cylinder.bottom_radius = 2.0
	cylinder.height = direction.length()
	mesh_instance.mesh = cylinder

	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.5
	mesh_instance.material_override = material

	# Position and orient the cylinder
	mesh_instance.position = direction * 0.5
	if direction.x != 0:
		mesh_instance.rotation_degrees.z = 90
	elif direction.z != 0:
		mesh_instance.rotation_degrees.x = 90

	return mesh_instance


func _process(delta: float) -> void:
	_update_fps(delta)
	_update_info()


func _update_fps(delta: float) -> void:
	_frame_times.append(delta)
	if _frame_times.size() > _max_frame_samples:
		_frame_times.pop_front()

	var avg_delta := 0.0
	for t in _frame_times:
		avg_delta += t
	avg_delta /= _frame_times.size()

	var fps := 1.0 / avg_delta if avg_delta > 0 else 0.0
	fps_label.text = "FPS: %.1f" % fps


func _update_info() -> void:
	info_label.text = "[b]Camera Info[/b]\n" + camera_controller.get_debug_info()


## Button handlers
func _on_smooth_toggled(enabled: bool) -> void:
	camera_controller.smooth_enabled = enabled


func _on_keyboard_toggled(enabled: bool) -> void:
	camera_controller.keyboard_enabled = enabled


func _on_reset_pressed() -> void:
	camera_controller.reset_camera()


func _on_focus_origin_pressed() -> void:
	camera_controller.focus_on(Vector3.ZERO, 500.0)


func _on_focus_marker_pressed() -> void:
	camera_controller.focus_on(marker.position, 300.0)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")


## Camera controller signal handlers
func _on_camera_moved(_position: Vector3, _rotation: Vector3) -> void:
	pass  # Info updates in _process


func _on_camera_reset() -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestCamera] Camera reset to default view")


func _on_focal_point_changed(focal_point: Vector3) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[TestCamera] Focal point changed to: %s" % focal_point)
