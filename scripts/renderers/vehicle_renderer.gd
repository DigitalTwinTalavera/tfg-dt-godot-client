## VehicleRenderer — renders all active simulation vehicles as instanced car shapes
## with client-side position interpolation for smooth 60 FPS movement from 10 Hz ticks.
##
## Interpolation strategy (snapshot interpolation + dead reckoning):
##   1. On each tick update:
##        • prev_pos / prev_heading ← current smoothed position at that moment
##        • target_pos / target_heading ← new server values
##        • lerp_t reset to 0  (or 1 for first-ever update / snap)
##   2. Each frame (_process):
##        • lerp_t += delta / TICK_INTERVAL
##        • lerp_t ≤ 1 → lerp(prev, target, lerp_t) for position & heading
##        • lerp_t > 1 → dead reckoning: target + forward * velocity * overshoot_time
##        • lerp_t capped at 1 + MAX_DEAD_RECKONING / TICK_INTERVAL to avoid runaway
##   3. Snap if the new server position is > SNAP_DISTANCE metres away.
##
## Car orientation: vehicle nose is along local −Z.
##   heading = 0   → North  (−Z),  rotation_y = 0
##   heading = 90  → East   (+X),  rotation_y = π/2
##   Formula: rotation_y = deg_to_rad(heading)
##
## Slot pool: MAX_VEHICLES slots pre-allocated; swap-to-fill-gap on removal (O(1)).
class_name VehicleRenderer
extends Node3D


## Emitted when the user left-clicks on a vehicle.
signal vehicle_selected(vehicle_id: String, state: Dictionary)


# ── Node references ──────────────────────────────────────────────────────────
var _body_mmi: MultiMeshInstance3D  # Car body boxes
var _roof_mmi: MultiMeshInstance3D  # Car roof boxes

# ── Injection ────────────────────────────────────────────────────────────────
var _converter: CoordinateConverter
var _camera: Camera3D

# ── Slot book-keeping ────────────────────────────────────────────────────────
## vehicle_id → slot index  (only contains active IDs)
var _id_to_slot: Dictionary = {}
## slot index → vehicle_id  (indices 0 ..< _active_count are valid)
var _slot_to_id: Array[String] = []
## Number of occupied slots (= visible_instance_count on both MultiMeshes)
var _active_count: int = 0

# ── Per-slot interpolation state ─────────────────────────────────────────────
## All arrays are pre-allocated to MAX_VEHICLES in _build_multimesh().

## World-space position at the *previous* tick (Y = CAR_ELEVATION)
var _prev_pos: Array[Vector3] = []
## World-space position from the *latest* tick
var _target_pos: Array[Vector3] = []
## Heading at the previous tick (radians, 0 = North)
var _prev_heading: Array[float] = []
## Heading from the latest tick (radians)
var _target_heading: Array[float] = []
## Speed from the latest tick (m/s) — used for dead reckoning
var _velocity: Array[float] = []
## Forward-direction components: X = sin(heading), Z = -cos(heading)
var _forward_x: Array[float] = []
var _forward_z: Array[float] = []
## Interpolation parameter.
##   -1  → slot has never received position data (skip rendering)
##    0  → just received a tick update (start of lerp)
##    ≤1 → interpolating between prev and target
##    >1 → dead reckoning beyond last known position
## PackedFloat32Array (NOT Array[float]): memoria contigua sin mutex por elemento,
## lo que permite que los worker threads escriban índices distintos de forma segura.
var _lerp_t: PackedFloat32Array

# ── Parallel-update output buffers ───────────────────────────────────────────
## Pre-allocated to MAX_VEHICLES. Worker threads write their slice by index;
## the main thread reads after WorkerThreadPool.wait_for_group_task_completion.
## PackedVector3Array / PackedFloat32Array use contiguous memory, so writing
## different indices from different threads is safe without a mutex.
var _out_pos:     PackedVector3Array   ## computed world-space positions
var _out_heading: PackedFloat32Array   ## computed headings (radians)

# ── MultiMesh raw buffers ─────────────────────────────────────────────────────
## Layout per instance (TRANSFORM_3D + use_colors, use_custom_data=false):
##   floats  0-11 : Transform3D (basis columns x/y/z then origin)
##   floats 12-15 : Color RGBA
## Workers write the transform portion (0-11) per frame; _update_slot writes
## the color portion (12-15) only on status change. The main thread uploads
## both buffers in one multimesh.buffer = ... call, replacing 10 000
## individual set_instance_transform() calls per frame.
var _body_buffer: PackedFloat32Array
var _roof_buffer: PackedFloat32Array


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


## Returns the vehicle_id at screen_pos using OBB ray test, or "" if none found.
func get_vehicle_at_position(screen_pos: Vector2, camera: Camera3D) -> String:
	if _active_count == 0 or not camera:
		return ""

	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir    := camera.project_ray_normal(screen_pos)

	# Half-extents for the combined body+roof bounding box
	var he := Vector3(
		Config.VehicleRendering.BODY_WIDTH  * 0.5,
		(Config.VehicleRendering.BODY_HEIGHT + Config.VehicleRendering.ROOF_HEIGHT) * 0.5,
		Config.VehicleRendering.BODY_LENGTH * 0.5
	)

	var closest_id   := ""
	var closest_dist := INF

	for i in range(_active_count):
		if _lerp_t[i] < 0.0:
			continue  # Not yet positioned
		var body_t := _body_mmi.multimesh.get_instance_transform(i)
		var dist   := _ray_obb_intersection(ray_origin, ray_dir, body_t, he)
		if dist >= 0.0 and dist < closest_dist:
			closest_dist = dist
			closest_id   = _slot_to_id[i]

	return closest_id


# ── Per-frame interpolation ──────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _active_count == 0:
		return

	var tick_inv := Config.VehicleRendering.TICK_INTERVAL
	var t_cap    := 1.0 + Config.VehicleRendering.MAX_DEAD_RECKONING / tick_inv

	# ── 1. Compute interpolated positions/headings in parallel ────────────────
	# _compute_vehicle_transform usa sólo PackedXxxArray y aritmética pura,
	# por lo que es segura llamarla desde worker threads de Godot 4.
	var gid := WorkerThreadPool.add_group_task(
		_compute_vehicle_transform.bind(delta, tick_inv, t_cap),
		_active_count,
		-1,   # -1 = usar todos los worker threads disponibles
		true  # high_priority
	)
	WorkerThreadPool.wait_for_group_task_completion(gid)

	# ── 2. Escribir transforms en los buffers y subir de golpe a la GPU ───────
	# Cada instancia ocupa 16 floats: 12 de Transform3D + 4 de Color RGBA.
	# Los colores (floats 12-15) los escribe _update_slot solo cuando cambia el
	# status: aquí solo sobreescribimos los 12 de transform (0-11).
	var body_y  := Config.VehicleRendering.BODY_Y_OFFSET
	var roof_y  := Config.VehicleRendering.ROOF_Y_OFFSET
	for i in range(_active_count):
		if _lerp_t[i] < 0.0:
			continue
		var pos     := _out_pos[i]
		var heading := _out_heading[i]
		var c       := cos(heading)
		var s       := sin(heading)
		# Basis(Vector3.UP, h): basis.x=(c,0,-s), basis.y=(0,1,0), basis.z=(s,0,c)
		# Buffer row-major [bx[k], by[k], bz[k], origin[k]] para k=0,1,2:
		#   Row 0: [ c,  0,  s, pos.x ]   Row 1: [ 0, 1, 0, pos.y ]   Row 2: [-s, 0, c, pos.z ]
		var off := i * 16
		# body
		_body_buffer[off +  0] =  c;  _body_buffer[off +  1] = 0.0; _body_buffer[off +  2] =  s; _body_buffer[off +  3] = pos.x
		_body_buffer[off +  4] = 0.0; _body_buffer[off +  5] = 1.0; _body_buffer[off +  6] = 0.0; _body_buffer[off +  7] = pos.y + body_y
		_body_buffer[off +  8] = -s;  _body_buffer[off +  9] = 0.0; _body_buffer[off + 10] =  c;  _body_buffer[off + 11] = pos.z
		# roof
		_roof_buffer[off +  0] =  c;  _roof_buffer[off +  1] = 0.0; _roof_buffer[off +  2] =  s; _roof_buffer[off +  3] = pos.x
		_roof_buffer[off +  4] = 0.0; _roof_buffer[off +  5] = 1.0; _roof_buffer[off +  6] = 0.0; _roof_buffer[off +  7] = pos.y + roof_y
		_roof_buffer[off +  8] = -s;  _roof_buffer[off +  9] = 0.0; _roof_buffer[off + 10] =  c;  _roof_buffer[off + 11] = pos.z

	# Una sola subida de datos a la GPU por mesh (en lugar de N llamadas individuales)
	_body_mmi.multimesh.buffer = _body_buffer
	_roof_mmi.multimesh.buffer = _roof_buffer


## Interpolated world position at parameter t for slot i.
func _eval_pos(slot: int, t: float) -> Vector3:
	if t <= 1.0:
		return _prev_pos[slot].lerp(_target_pos[slot], t)
	# Dead reckoning: extrapolate beyond the last known target
	var overshoot := (t - 1.0) * Config.VehicleRendering.TICK_INTERVAL
	return _target_pos[slot] + \
		Vector3(_forward_x[slot], 0.0, _forward_z[slot]) * _velocity[slot] * overshoot


## Interpolated heading (radians) at parameter t for slot i.
func _eval_heading(slot: int, t: float) -> float:
	if t <= 1.0:
		return lerp_angle(_prev_heading[slot], _target_heading[slot], t)
	return _target_heading[slot]  # Hold heading after dead reckoning


## Worker-thread entry point — llamado por WorkerThreadPool.add_group_task().
## Solo usa PackedXxxArray y aritmética pura (sin métodos de Node ni Array[T]).
## Escribe el resultado en _out_pos[i] y _out_heading[i], que son PackedXxxArray
## con memoria contigua: escrituras en índices distintos son thread-safe.
func _compute_vehicle_transform(i: int, delta: float, tick_inv: float, t_cap: float) -> void:
	if _lerp_t[i] < 0.0:
		return
	_lerp_t[i] = _lerp_t[i] + delta / tick_inv  # PackedFloat32Array: write is atomic per slot
	var t := minf(_lerp_t[i], t_cap)

	# ── Posición ──────────────────────────────────────────────────────────────
	var pos: Vector3
	if t <= 1.0:
		# lerp entre prev_pos y target_pos — sólo lectura de PackedVector3Array, thread-safe
		pos = _prev_pos[i].lerp(_target_pos[i], t)
	else:
		var overshoot := (t - 1.0) * Config.VehicleRendering.TICK_INTERVAL
		pos = _target_pos[i] + Vector3(_forward_x[i], 0.0, _forward_z[i]) * _velocity[i] * overshoot
	_out_pos[i] = pos

	# ── Heading ───────────────────────────────────────────────────────────────
	if t <= 1.0:
		# lerp_angle manual para no llamar a la función builtin desde worker
		var from_h := _prev_heading[i]
		var to_h   := _target_heading[i]
		var diff   := fmod(to_h - from_h + TAU + PI, TAU) - PI  # normalise a [-π, π]
		_out_heading[i] = from_h + diff * t
	else:
		_out_heading[i] = _target_heading[i]


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

	_slot_to_id.resize(max_v);    _slot_to_id.fill("")
	_prev_pos.resize(max_v);      _prev_pos.fill(Vector3.ZERO)
	_target_pos.resize(max_v);    _target_pos.fill(Vector3.ZERO)
	_prev_heading.resize(max_v);  _prev_heading.fill(0.0)
	_target_heading.resize(max_v);_target_heading.fill(0.0)
	_velocity.resize(max_v);      _velocity.fill(0.0)
	_forward_x.resize(max_v);     _forward_x.fill(0.0)
	_forward_z.resize(max_v);     _forward_z.fill(-1.0)   # Default facing North
	_lerp_t.resize(max_v);        _lerp_t.fill(-1.0)      # -1 = not initialised

	# Parallel-update output arrays
	_out_pos.resize(max_v)
	_out_heading.resize(max_v)

	# Raw MultiMesh buffers: 16 floats per instance (12 transform + 4 color)
	_body_buffer.resize(max_v * 16)
	_body_buffer.fill(0.0)
	_roof_buffer.resize(max_v * 16)
	_roof_buffer.fill(0.0)

	_body_mmi = _make_mmi(
		"VehicleBodyMesh",
		Vector3(Config.VehicleRendering.BODY_WIDTH,
				Config.VehicleRendering.BODY_HEIGHT,
				Config.VehicleRendering.BODY_LENGTH),
		max_v
	)
	add_child(_body_mmi)

	_roof_mmi = _make_mmi(
		"VehicleRoofMesh",
		Vector3(Config.VehicleRendering.ROOF_WIDTH,
				Config.VehicleRendering.ROOF_HEIGHT,
				Config.VehicleRendering.ROOF_LENGTH),
		max_v
	)
	add_child(_roof_mmi)


## Creates a MultiMeshInstance3D with a BoxMesh of the given size.
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
	VehicleManager.vehicles_batch_added.connect(_on_vehicles_batch_added)
	VehicleManager.vehicle_updated.connect(_on_vehicle_updated)
	VehicleManager.vehicle_removed.connect(_on_vehicle_removed)
	SimulationClient.connected.connect(_on_ws_connected)


# ── Slot management ──────────────────────────────────────────────────────────

func _on_vehicle_added(vehicle_id: String, state: Dictionary) -> void:
	if _id_to_slot.has(vehicle_id):
		_update_slot(_id_to_slot[vehicle_id], state)
		return

	var max_v := Config.VehicleRendering.MAX_VEHICLES
	if _active_count >= max_v:
		_log_warning("MAX_VEHICLES (%d) reached — skipping %s" % [max_v, vehicle_id])
		return

	var slot := _active_count
	_active_count            += 1
	_id_to_slot[vehicle_id]   = slot
	_slot_to_id[slot]         = vehicle_id
	_lerp_t[slot]             = -1.0   # Signals first-update in _update_slot
	_set_visible_count(_active_count)
	_update_slot(slot, state)


## Handles a batch of new vehicles arriving in a single tick.
## Allocates all slots first, then calls _set_visible_count() once at the end
## instead of once per vehicle — critical for performance with 10k vehicles.
func _on_vehicles_batch_added(batch: Array) -> void:
	var max_v := Config.VehicleRendering.MAX_VEHICLES
	for pair in batch:
		var vehicle_id: String = pair[0]
		var state: Dictionary = pair[1]
		if _id_to_slot.has(vehicle_id):
			_update_slot(_id_to_slot[vehicle_id], state)
			continue
		if _active_count >= max_v:
			_log_warning("MAX_VEHICLES (%d) reached — skipping batch remainder" % max_v)
			break
		var slot := _active_count
		_active_count += 1
		_id_to_slot[vehicle_id] = slot
		_slot_to_id[slot] = vehicle_id
		_lerp_t[slot] = -1.0
		_update_slot(slot, state)
	_set_visible_count(_active_count)


func _on_vehicle_updated(vehicle_id: String, state: Dictionary) -> void:
	if not _id_to_slot.has(vehicle_id):
		return
	_update_slot(_id_to_slot[vehicle_id], state)


func _on_vehicle_removed(vehicle_id: String) -> void:
	if not _id_to_slot.has(vehicle_id):
		return

	var slot: int = _id_to_slot[vehicle_id]
	_id_to_slot.erase(vehicle_id)
	_active_count -= 1

	if slot != _active_count:
		# Swap last active slot into the freed slot (O(1) removal)
		var last_id              := _slot_to_id[_active_count]
		_slot_to_id[slot]         = last_id
		_id_to_slot[last_id]      = slot
		_copy_slot_state(_active_count, slot)

	_clear_slot(_active_count)
	_set_visible_count(_active_count)


## Copy all per-slot state from slot src to slot dst.
func _copy_slot_state(src: int, dst: int) -> void:
	_prev_pos[dst]      = _prev_pos[src]
	_target_pos[dst]    = _target_pos[src]
	_prev_heading[dst]  = _prev_heading[src]
	_target_heading[dst]= _target_heading[src]
	_velocity[dst]      = _velocity[src]
	_forward_x[dst]     = _forward_x[src]
	_forward_z[dst]     = _forward_z[src]
	_lerp_t[dst]        = _lerp_t[src]
	# Copiar los 16 floats del buffer (12 transform + 4 color) desde src a dst
	var src_off := src * 16
	var dst_off := dst * 16
	for k in range(16):
		_body_buffer[dst_off + k] = _body_buffer[src_off + k]
		_roof_buffer[dst_off + k] = _roof_buffer[src_off + k]


## Reset a slot's state to its uninitialised defaults.
func _clear_slot(slot: int) -> void:
	_slot_to_id[slot] = ""
	_lerp_t[slot]     = -1.0  # Prevents _process from rendering this slot


func _on_ws_connected() -> void:
	_active_count = 0
	_id_to_slot.clear()
	_slot_to_id.fill("")
	_lerp_t.fill(-1.0)
	_body_buffer.fill(0.0)
	_roof_buffer.fill(0.0)
	_set_visible_count(0)
	_log_info("Reset on WebSocket connect")


func _set_visible_count(count: int) -> void:
	_body_mmi.multimesh.visible_instance_count = count
	_roof_mmi.multimesh.visible_instance_count = count


# ── Target update ────────────────────────────────────────────────────────────

func _update_slot(slot: int, state: Dictionary) -> void:
	if not _converter or not _converter.is_initialized():
		return
	if not state.has("lon") or not state.has("lat"):
		return  # No position data yet; will be applied on next update

	var lon        : float  = state["lon"]
	var lat        : float  = state["lat"]
	var heading_deg: float  = state.get("h",      0.0)
	var speed      : float  = state.get("v",      0.0)
	var status     : String = state.get("status", "idle")

	var new_pos     := _converter.gps_to_godot(lon, lat)
	new_pos.y        = Config.VehicleRendering.CAR_ELEVATION
	var new_heading := deg_to_rad(heading_deg)

	if _lerp_t[slot] < 0.0:
		# ── First update for this slot: snap directly to position ──────────
		_prev_pos[slot]      = new_pos
		_prev_heading[slot]  = new_heading
		_lerp_t[slot]        = 1.0  # Render at target immediately
		_log_debug("Slot %d initialised at (%.1f, %.1f, %.1f)" % [slot, new_pos.x, new_pos.y, new_pos.z])
	else:
		# ── Subsequent update: compute where the vehicle currently is ──────
		var t_now          := minf(_lerp_t[slot],
								   1.0 + Config.VehicleRendering.MAX_DEAD_RECKONING /
										 Config.VehicleRendering.TICK_INTERVAL)
		var current_pos    := _eval_pos(slot, t_now)
		var current_heading := _eval_heading(slot, t_now)
		var error          := current_pos.distance_to(new_pos)

		var heading_change_deg := rad_to_deg(absf(angle_difference(current_heading, new_heading)))
		var should_snap := error > Config.VehicleRendering.SNAP_DISTANCE or \
						   heading_change_deg > Config.VehicleRendering.SNAP_HEADING_DEG
		if should_snap:
			# Large discontinuity or sharp turn: snap to avoid lerping off-road
			_prev_pos[slot]     = new_pos
			_prev_heading[slot] = new_heading
			_lerp_t[slot]       = 1.0
			_log_debug("Snap on slot %d (error %.1f m, heading %.1f°)" % [slot, error, heading_change_deg])
		else:
			# Normal update: lerp from current rendered position to new target
			_prev_pos[slot]     = current_pos
			_prev_heading[slot] = current_heading
			_lerp_t[slot]       = 0.0

	# Always update target and kinematics
	_target_pos[slot]      = new_pos
	_target_heading[slot]  = new_heading
	_velocity[slot]        = speed
	_forward_x[slot]       = sin(new_heading)   # East component
	_forward_z[slot]       = -cos(new_heading)  # South component (-cos because +Z = South)

	# Status colour: escribe directamente en el buffer (floats 12-15 de cada slot)
	# en lugar de llamar a set_instance_color, para que multimesh.buffer = ...
	# en _process() suba el color junto con el transform en una sola operación.
	var color := _get_status_color(status)
	var off   := slot * 16
	_body_buffer[off + 12] = color.r;  _body_buffer[off + 13] = color.g
	_body_buffer[off + 14] = color.b;  _body_buffer[off + 15] = color.a
	_roof_buffer[off + 12] = color.r;  _roof_buffer[off + 13] = color.g
	_roof_buffer[off + 14] = color.b;  _roof_buffer[off + 15] = color.a


func _get_status_color(status: String) -> Color:
	match status:
		"moving":  return Config.VehicleColors.MOVING
		"stopped": return Config.VehicleColors.STOPPED
		"waiting": return Config.VehicleColors.WAITING
		_:         return Config.VehicleColors.IDLE


# ── Ray picking ──────────────────────────────────────────────────────────────

## Transforms the ray into the OBB's local space, then runs a slab AABB test.
func _ray_obb_intersection(
	ray_origin   : Vector3,
	ray_dir      : Vector3,
	obb_transform: Transform3D,
	half_extents : Vector3
) -> float:
	var inv          := obb_transform.affine_inverse()
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


func _log_debug(message: String) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[VehicleRenderer] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[VehicleRenderer] %s" % message)
