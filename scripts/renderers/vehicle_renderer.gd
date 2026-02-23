## VehicleRenderer — renders all active simulation vehicles as instanced car shapes.
##
## Uses two MultiMeshInstance3D (body box + roof box) for efficient single-draw-call
## batch rendering at up to Config.VehicleRendering.MAX_VEHICLES vehicles.
##
## Usage:
##   1. Add as a Node3D child in your 3D scene.
##   2. Call set_converter(converter) with an initialised CoordinateConverter.
##   3. Call set_camera(camera) so click-picking works.
##   4. The renderer connects to VehicleManager automatically in _ready().
##   5. Connect vehicle_selected to a VehicleInfoPopup (or similar).
##
## Car orientation: vehicle "nose" is along local -Z.
##   heading = 0  → North (-Z)   rotation_y = 0
##   heading = 90 → East  (+X)   rotation_y = π/2
##   Formula: rotation_y = deg_to_rad(heading)
##
## Slot pool: MAX_VEHICLES slots are pre-allocated; when a vehicle is removed
## the last occupied slot swaps into the freed slot (O(1) removal, no gaps).
class_name VehicleRenderer
extends Node3D


## Emitted when the user left-clicks on a vehicle.
signal vehicle_selected(vehicle_id: String, state: Dictionary)


## ── Node references ────────────────────────────────────────────────────────
var _body_mmi: MultiMeshInstance3D  # Car body boxes
var _roof_mmi: MultiMeshInstance3D  # Car roof boxes

## ── Injection ───────────────────────────────────────────────────────────────
var _converter: CoordinateConverter
var _camera: Camera3D

## ── Slot book-keeping ───────────────────────────────────────────────────────
## vehicle_id → slot index  (only contains active IDs)
var _id_to_slot: Dictionary = {}

## slot index → vehicle_id  (indices 0 ..< _active_count are valid)
var _slot_to_id: Array[String] = []

## Number of occupied slots (= visible_instance_count on both MultiMeshes)
var _active_count: int = 0


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_build_multimesh()
	_connect_signals()
	set_process_unhandled_input(true)
	_log_info("VehicleRenderer ready (max %d vehicles)" % Config.VehicleRendering.MAX_VEHICLES)


# ── Public API ───────────────────────────────────────────────────────────────

func set_converter(converter: CoordinateConverter) -> void:
	_converter = converter


func set_camera(camera: Camera3D) -> void:
	_camera = camera


func get_active_count() -> int:
	return _active_count


func set_vehicles_visible(visible_flag: bool) -> void:
	_body_mmi.visible = visible_flag
	_roof_mmi.visible = visible_flag


## Returns the vehicle_id at the given screen position, or "" if none found.
func get_vehicle_at_position(screen_pos: Vector2, camera: Camera3D) -> String:
	if _active_count == 0 or not camera:
		return ""

	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir    := camera.project_ray_normal(screen_pos)

	var closest_id   := ""
	var closest_dist := INF

	# Half-extents for the combined body+roof bounding box
	var he := Vector3(
		Config.VehicleRendering.BODY_WIDTH  * 0.5,
		(Config.VehicleRendering.BODY_HEIGHT + Config.VehicleRendering.ROOF_HEIGHT) * 0.5,
		Config.VehicleRendering.BODY_LENGTH * 0.5
	)

	for i in range(_active_count):
		var body_t := _body_mmi.multimesh.get_instance_transform(i)
		var dist   := _ray_obb_intersection(ray_origin, ray_dir, body_t, he)
		if dist >= 0.0 and dist < closest_dist:
			closest_dist = dist
			closest_id   = _slot_to_id[i]

	return closest_id


# ── Input ────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if not _camera:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var vid := get_vehicle_at_position(mb.position, _camera)
			if not vid.is_empty():
				vehicle_selected.emit(vid, VehicleManager.get_vehicle(vid))
				get_viewport().set_input_as_handled()


# ── MultiMesh construction ───────────────────────────────────────────────────

func _build_multimesh() -> void:
	var max_v := Config.VehicleRendering.MAX_VEHICLES

	_slot_to_id.resize(max_v)
	_slot_to_id.fill("")

	_body_mmi = _make_mmi(
		"VehicleBodyMesh",
		Vector3(
			Config.VehicleRendering.BODY_WIDTH,
			Config.VehicleRendering.BODY_HEIGHT,
			Config.VehicleRendering.BODY_LENGTH
		),
		max_v
	)
	add_child(_body_mmi)

	_roof_mmi = _make_mmi(
		"VehicleRoofMesh",
		Vector3(
			Config.VehicleRendering.ROOF_WIDTH,
			Config.VehicleRendering.ROOF_HEIGHT,
			Config.VehicleRendering.ROOF_LENGTH
		),
		max_v
	)
	add_child(_roof_mmi)


## Creates one MultiMeshInstance3D with a BoxMesh of the given size.
func _make_mmi(node_name: String, box_size: Vector3, max_instances: int) -> MultiMeshInstance3D:
	var box := BoxMesh.new()
	box.size = box_size

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = Config.VehicleRendering.MATERIAL_ROUGHNESS
	mat.metallic  = Config.VehicleRendering.MATERIAL_METALLIC
	box.surface_set_material(0, mat)

	var mm := MultiMesh.new()
	mm.transform_format       = MultiMesh.TRANSFORM_3D
	mm.use_colors             = true
	mm.use_custom_data        = false
	mm.mesh                   = box
	mm.instance_count         = max_instances
	mm.visible_instance_count = 0

	var mmi := MultiMeshInstance3D.new()
	mmi.name      = node_name
	mmi.multimesh = mm
	return mmi


# ── Signal wiring ────────────────────────────────────────────────────────────

func _connect_signals() -> void:
	VehicleManager.vehicle_added.connect(_on_vehicle_added)
	VehicleManager.vehicle_updated.connect(_on_vehicle_updated)
	VehicleManager.vehicle_removed.connect(_on_vehicle_removed)
	SimulationClient.connected.connect(_on_ws_connected)


# ── Slot management ──────────────────────────────────────────────────────────

func _on_vehicle_added(vehicle_id: String, state: Dictionary) -> void:
	if _id_to_slot.has(vehicle_id):
		# Already allocated (e.g. vehicle_spawned arrived after first tick)
		_update_slot(_id_to_slot[vehicle_id], state)
		return

	var max_v := Config.VehicleRendering.MAX_VEHICLES
	if _active_count >= max_v:
		_log_warning("MAX_VEHICLES (%d) reached — skipping %s" % [max_v, vehicle_id])
		return

	var slot := _active_count
	_active_count           += 1
	_id_to_slot[vehicle_id]  = slot
	_slot_to_id[slot]        = vehicle_id
	_set_visible_count(_active_count)
	_update_slot(slot, state)


func _on_vehicle_updated(vehicle_id: String, state: Dictionary) -> void:
	if not _id_to_slot.has(vehicle_id):
		return
	_update_slot(_id_to_slot[vehicle_id], state)


func _on_vehicle_removed(vehicle_id: String) -> void:
	if not _id_to_slot.has(vehicle_id):
		return

	var slot := _id_to_slot[vehicle_id]
	_id_to_slot.erase(vehicle_id)
	_active_count -= 1

	if slot != _active_count:
		# Swap last active slot into the freed slot (O(1) removal)
		var last_id := _slot_to_id[_active_count]
		_slot_to_id[slot]  = last_id
		_id_to_slot[last_id] = slot

		_body_mmi.multimesh.set_instance_transform(
			slot, _body_mmi.multimesh.get_instance_transform(_active_count))
		_body_mmi.multimesh.set_instance_color(
			slot, _body_mmi.multimesh.get_instance_color(_active_count))
		_roof_mmi.multimesh.set_instance_transform(
			slot, _roof_mmi.multimesh.get_instance_transform(_active_count))
		_roof_mmi.multimesh.set_instance_color(
			slot, _roof_mmi.multimesh.get_instance_color(_active_count))

	_slot_to_id[_active_count] = ""  # Mark freed slot as empty
	_set_visible_count(_active_count)


func _on_ws_connected() -> void:
	_active_count = 0
	_id_to_slot.clear()
	_slot_to_id.fill("")
	_set_visible_count(0)
	_log_info("Reset on WebSocket connect")


func _set_visible_count(count: int) -> void:
	_body_mmi.multimesh.visible_instance_count = count
	_roof_mmi.multimesh.visible_instance_count = count


# ── Per-instance update ──────────────────────────────────────────────────────

func _update_slot(slot: int, state: Dictionary) -> void:
	if not _converter or not _converter.is_initialized():
		return
	if not state.has("lon") or not state.has("lat"):
		return  # No position data yet; will be applied on next update

	var lon    : float  = state["lon"]
	var lat    : float  = state["lat"]
	var heading: float  = state.get("h", 0.0)
	var status : String = state.get("status", "idle")

	var base_pos: Vector3 = _converter.gps_to_godot(lon, lat)
	base_pos.y = Config.VehicleRendering.CAR_ELEVATION

	# heading = 0 → North (-Z), 90 → East (+X)
	# Basis(UP, angle) rotates local -Z by angle:
	#   angle=0    → local -Z = world -Z (North) ✓
	#   angle=π/2  → local -Z = world +X (East)  ✓
	var rot_y := deg_to_rad(heading)
	var basis := Basis(Vector3.UP, rot_y)

	var body_pos := base_pos + Vector3(0.0, Config.VehicleRendering.BODY_Y_OFFSET, 0.0)
	var roof_pos := base_pos + Vector3(0.0, Config.VehicleRendering.ROOF_Y_OFFSET, 0.0)

	_body_mmi.multimesh.set_instance_transform(slot, Transform3D(basis, body_pos))
	_roof_mmi.multimesh.set_instance_transform(slot, Transform3D(basis, roof_pos))

	var color := _get_status_color(status)
	_body_mmi.multimesh.set_instance_color(slot, color)
	_roof_mmi.multimesh.set_instance_color(slot, color)


func _get_status_color(status: String) -> Color:
	match status:
		"moving":
			return Config.VehicleColors.MOVING
		"stopped":
			return Config.VehicleColors.STOPPED
		"waiting":
			return Config.VehicleColors.WAITING
		_:
			return Config.VehicleColors.IDLE


# ── Ray picking ──────────────────────────────────────────────────────────────

## Transforms the ray into the OBB's local space, then runs a slab AABB test.
func _ray_obb_intersection(
	ray_origin  : Vector3,
	ray_dir     : Vector3,
	obb_transform: Transform3D,
	half_extents: Vector3
) -> float:
	var inv         := obb_transform.affine_inverse()
	var local_origin := inv * ray_origin
	var local_dir    := inv.basis * ray_dir
	return _ray_aabb_test(local_origin, local_dir, half_extents)


## Slab-method AABB test (AABB centred at origin with given half-extents).
## Returns the entry distance (≥ 0) or -1.0 on miss.
func _ray_aabb_test(
	ray_origin  : Vector3,
	ray_dir     : Vector3,
	half_extents: Vector3
) -> float:
	var t_min := -INF
	var t_max :=  INF

	for axis in [0, 1, 2]:
		var o : float = ray_origin[axis]
		var d : float = ray_dir[axis]
		var mn: float = -half_extents[axis]
		var mx: float =  half_extents[axis]

		if abs(d) < 1e-6:
			if o < mn or o > mx:
				return -1.0
		else:
			var t1 := (mn - o) / d
			var t2 := (mx - o) / d
			if t1 > t2:
				var tmp := t1; t1 = t2; t2 = tmp
			t_min = maxf(t_min, t1)
			t_max = minf(t_max, t2)
			if t_min > t_max:
				return -1.0

	return t_min if t_min >= 0.0 else (t_max if t_max >= 0.0 else -1.0)


# ── Logging ──────────────────────────────────────────────────────────────────

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[VehicleRenderer] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[VehicleRenderer] %s" % message)
