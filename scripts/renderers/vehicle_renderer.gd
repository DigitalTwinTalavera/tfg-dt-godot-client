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
## Ruedas: un MultiMesh con 4 instancias por slot (FL, FR, RL, RR) dibujadas
## como cilindros tumbados y animadas mediante acumulación de ángulo de giro.
var _wheel_mmi: MultiMeshInstance3D
## Luces de freno: 2 instancias por slot (traseras). Color modulado según `a`
## y `status`: rojo brillante al frenar/stop, tenue en circulación normal.
var _brake_mmi: MultiMeshInstance3D

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

## World-space position at the *previous* snapshot (Y = CAR_ELEVATION)
var _snap_old_pos: Array[Vector3] = []
## World-space position at the *latest* snapshot
var _snap_new_pos: Array[Vector3] = []
## Heading at the previous snapshot (radians, 0 = North)
var _snap_old_heading: Array[float] = []
## Heading at the latest snapshot (radians)
var _snap_new_heading: Array[float] = []
## Server sim_time (seconds) at each snapshot. Usados para la interpolación:
## para el slot i, u = (render_time - snap_old_time) / (snap_new_time - snap_old_time),
## con u clampeado a [0, 1]. Así el render depende del reloj del servidor (no
## del reloj local de llegada del mensaje) y es imposible retroceder porque
## render_time = latest_server_sim_time - INTERPOLATION_DELAY avanza monotónicamente.
var _snap_old_time: PackedFloat32Array
var _snap_new_time: PackedFloat32Array
## Velocidad suavizada (EMA) en m/s — usada para dead reckoning.
## La actualización se hace como v = α·v_nuevo + (1-α)·v_ant para evitar
## tirones visibles cuando el backend publica un salto brusco de velocidad.
var _velocity: Array[float] = []
## Aceleración suavizada (EMA) en m/s² — permite integrar el movimiento
## durante el overshoot: pos = target + v·Δt + ½·a·Δt² (cinemática uniforme).
## Misma suavización EMA que la velocidad.
var _acceleration: Array[float] = []
## Forward-direction components: X = sin(heading), Z = -cos(heading)
var _forward_x: Array[float] = []
var _forward_z: Array[float] = []
## Escalas por-slot aplicadas a la malla base (length_m / BODY_LENGTH, etc.).
## Permiten usar una única MultiMesh para car/moto/truck: cada instancia se
## renderiza con el tamaño físico real del vehículo.
var _scale_x: PackedFloat32Array   ## width factor (body) aplicado a basis.x
var _scale_y: PackedFloat32Array   ## height factor aplicado a basis.y
var _scale_z: PackedFloat32Array   ## length factor aplicado a basis.z
## Mismo escalado pero para el techo (motos → 0 para esconderlo).
var _roof_scale_x: PackedFloat32Array
var _roof_scale_y: PackedFloat32Array
var _roof_scale_z: PackedFloat32Array
## Offset vertical en metros para el cuerpo (varia con la altura del vehículo)
var _body_y_off: PackedFloat32Array
var _roof_y_off: PackedFloat32Array
## Último vtype aplicado a cada slot (para evitar recomputar escalas cada tick)
var _slot_vtype: Array[String] = []
## Ángulo acumulado de giro de las ruedas por slot (rad). Se incrementa cada
## frame en v·Δt/R para dar sensación de rodadura real.
var _wheel_angle: PackedFloat32Array
## Semiseparación de ejes (X/Z) de las ruedas respecto al centro del vehículo,
## en metros. Se recalcula al aplicar vtype y se usa para posicionar las 4
## ruedas sin necesidad de recomputar en el hot-path.
var _wheel_sep_x: PackedFloat32Array
var _wheel_sep_z: PackedFloat32Array
## Último status aplicado a cada slot (usado para no regenerar buffers de luces
## innecesariamente). La luz de freno cambia según status y aceleración.
var _slot_status: Array[String] = []
## Flag de inicialización por slot.
##   -1 → slot nunca ha recibido datos (saltar render)
##   ≥0 → slot inicializado (el valor no se usa ya para interpolar)
## Se mantiene como PackedFloat32Array por compatibilidad con el bucle de
## workers (memoria contigua + escrituras por índice thread-safe).
var _lerp_t: PackedFloat32Array

## Reloj de servidor: el último sim_time recibido desde el backend.
## Se actualiza con cada mensaje `tick` de SimulationClient.
var _latest_server_sim_time: float = -1.0

## Reloj de render: sim_time al que el cliente dibuja actualmente.
## Se mantiene en `_latest_server_sim_time - INTERPOLATION_DELAY`, avanzando
## con delta local cada frame y re-ancla contra el reloj de servidor para
## corregir drift. NUNCA retrocede: garantiza que la posición dibujada va
## siempre entre dos snapshots reales, no por delante del servidor.
var _render_sim_time: float = -1.0

# ── Cached invariants (computados una vez en _ready) ────────────────────────
## Inverso del radio de rueda — se multiplica por v·Δt para obtener el ángulo
## de rodadura por frame. Cachearlo evita hacer la división en cada worker call.
var _inv_wheel_r: float = 0.0

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
## 4 ruedas por slot → MAX_VEHICLES * 4 instancias, 16 floats cada una.
var _wheel_buffer: PackedFloat32Array
## 2 luces de freno por slot → MAX_VEHICLES * 2 instancias.
var _brake_buffer: PackedFloat32Array


# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_inv_wheel_r = 1.0 / Config.VehicleRendering.WHEEL_RADIUS
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

	# Half-extents en el espacio local de la malla base (sin escalar): la basis
	# del transform ya incluye la escala del slot, y affine_inverse() la invierte
	# al transformar el rayo a local.
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

	# ── Avance del reloj de render ────────────────────────────────────────────
	# `render_sim_time` se mantiene a `latest_server_sim_time - INTERPOLATION_DELAY`
	# avanzando con delta local para dar movimiento suave entre ticks, pero
	# re-anclado al reloj del servidor para eliminar drift. Nunca retrocede.
	if _latest_server_sim_time < 0.0:
		return  # aún no hemos recibido ningún tick
	if _render_sim_time < 0.0:
		_render_sim_time = _latest_server_sim_time - Config.VehicleRendering.INTERPOLATION_DELAY
	else:
		_render_sim_time += delta
		var target := _latest_server_sim_time - Config.VehicleRendering.INTERPOLATION_DELAY
		var max_dr := Config.VehicleRendering.MAX_DEAD_RECKONING
		# Tope superior: `snap_new_time` + MAX_DEAD_RECKONING. Así render_time
		# puede recorrer el intervalo [t_old, t_new] completo (u = 0..1) por tick,
		# más un margen de extrapolación si el siguiente llega tarde. Un tope en
		# `target + max_dr` capaba u ≤ 0.5 → tirones de media-distancia cada 100 ms.
		var upper_cap := _latest_server_sim_time + max_dr
		if _render_sim_time > upper_cap:
			_render_sim_time = upper_cap
		# Si el reloj cliente se ha quedado muy atrás (pausa, lag), resync duro.
		elif _render_sim_time < target - 0.5:
			_render_sim_time = target

	# ── Snapshot de la cámara para LOD ────────────────────────────────────────
	# Leemos la posición de la cámara en el main thread (acceder a Camera3D
	# desde un worker no es thread-safe). Si no hay cámara asignada usamos
	# lod_dist_sq = INF → el check siempre falla → full detail para todos.
	var cam_x := 0.0
	var cam_z := 0.0
	var lod_dist_sq := INF
	if _camera:
		var cam_pos := _camera.global_position
		cam_x = cam_pos.x
		cam_z = cam_pos.z
		var d := Config.VehicleRendering.LOD_DETAIL_DISTANCE
		lod_dist_sq = d * d

	# ── Paralelización: una única group task hace TODO el trabajo por slot ───
	# El WorkerThreadPool reparte los _active_count índices entre los N hilos
	# disponibles (en esta máquina, 20). Cada worker lee sus snaps e índices
	# disjuntos, interpola posición + heading, y escribe sus ~112 floats en
	# los buffers MultiMesh (body+roof+4 ruedas+2 luces). Las escrituras son
	# thread-safe porque cada slot ocupa un rango contiguo distinto dentro de
	# los PackedFloat32Array; Godot garantiza memoria contigua sin COW en
	# escrituras por índice.
	#
	# Coste esperado con 6000 vehículos / 20 cores: ~3 ms/thread secuencial
	# era ~60 ms en el main thread → el loop antes triplicaba el presupuesto
	# de frame (16.67 ms) y producía los tirones.
	var gid := WorkerThreadPool.add_group_task(
		_compute_and_write_slot.bind(_render_sim_time, delta, cam_x, cam_z, lod_dist_sq),
		_active_count,
		-1,   # -1 = repartir entre todos los worker threads disponibles
		true  # high priority
	)
	WorkerThreadPool.wait_for_group_task_completion(gid)

	# Upload de los 4 buffers a GPU en una sola llamada C++ por mesh.
	_body_mmi.multimesh.buffer  = _body_buffer
	_roof_mmi.multimesh.buffer  = _roof_buffer
	_wheel_mmi.multimesh.buffer = _wheel_buffer
	_brake_mmi.multimesh.buffer = _brake_buffer


## Worker-thread entry point: hace TODO el trabajo por slot (interpolar +
## construir basis + escribir buffers). Llamado por
## WorkerThreadPool.add_group_task() con un índice distinto por thread.
##
## Thread-safety:
##   - Escribe sólo a las posiciones (i*16..i*16+15) de _body_buffer/_roof_buffer,
##     (i*64..i*64+63) de _wheel_buffer, (i*32..i*32+31) de _brake_buffer, y al
##     índice i de _wheel_angle. Cada slot tiene un rango disjunto → seguro.
##   - Lee snaps, velocidad, forward, scales, offsets: todos mutados sólo en
##     el main thread vía _update_slot, que corre antes que _process en el
##     mismo frame (handler síncrono de tick_received).
##   - Config.VehicleRendering.* son constantes (seguro desde cualquier thread).
##   - _camera NO se accede aquí: cam_x/cam_z/lod_dist_sq vienen bindeados.
##
## LOD: si dist_sq(pos, cam) > lod_dist_sq, escribe transforms degenerados
## (todos ceros) para las 4 ruedas y las 2 luces de freno. La GPU los descarta
## en setup de vértices (primitivas degeneradas) y nos ahorramos ~80 writes +
## 4 cos/sin por vehículo lejano. Los colores (índices 12-15 de cada instancia)
## los conserva _update_slot; aquí sólo tocamos los 12 floats de transform.
func _compute_and_write_slot(
	i: int,
	render_time: float,
	delta: float,
	cam_x: float,
	cam_z: float,
	lod_dist_sq: float,
) -> void:
	if _lerp_t[i] < 0.0:
		return

	# ── (a) Interpolación de posición + heading ───────────────────────────────
	var t_old := _snap_old_time[i]
	var t_new := _snap_new_time[i]
	var span := t_new - t_old

	var pos: Vector3
	if span <= 1e-6:
		pos = _snap_new_pos[i]
	elif render_time <= t_old:
		pos = _snap_old_pos[i]
	elif render_time < t_new:
		var u_p := (render_time - t_old) / span
		pos = _snap_old_pos[i].lerp(_snap_new_pos[i], u_p)
	else:
		# Red de seguridad: render_time pasó snap_new. Extrapolación corta
		# usando velocidad × forward, capada a MAX_DEAD_RECKONING.
		var overshoot := render_time - t_new
		if overshoot > Config.VehicleRendering.MAX_DEAD_RECKONING:
			overshoot = Config.VehicleRendering.MAX_DEAD_RECKONING
		var v := _velocity[i]
		if v > 0.0 and overshoot > 0.0:
			pos = _snap_new_pos[i] + \
				Vector3(_forward_x[i], 0.0, _forward_z[i]) * v * overshoot
		else:
			pos = _snap_new_pos[i]

	var heading: float
	if span <= 1e-6 or render_time >= t_new:
		heading = _snap_new_heading[i]
	elif render_time <= t_old:
		heading = _snap_old_heading[i]
	else:
		var from_h := _snap_old_heading[i]
		var to_h   := _snap_new_heading[i]
		var diff   := fmod(to_h - from_h + TAU + PI, TAU) - PI  # normalise a [-π, π]
		var cap := Config.VehicleRendering.MAX_YAW_RATE_RAD_S * span
		if diff >  cap: diff =  cap
		elif diff < -cap: diff = -cap
		var u_h := (render_time - t_old) / span
		heading = from_h + diff * u_h

	# ── (b) Body + roof transforms (siempre, no dependen de LOD) ──────────────
	var c := cos(heading)
	var s := sin(heading)
	var sx := _scale_x[i]; var sy := _scale_y[i]; var sz := _scale_z[i]
	var rsx := _roof_scale_x[i]; var rsy := _roof_scale_y[i]; var rsz := _roof_scale_z[i]
	var off := i * 16
	# body — basis = R_y(heading) con escala por columna; origen en pos
	_body_buffer[off +  0] =  c * sx; _body_buffer[off +  1] = 0.0; _body_buffer[off +  2] = -s * sz; _body_buffer[off +  3] = pos.x
	_body_buffer[off +  4] = 0.0;     _body_buffer[off +  5] = sy;  _body_buffer[off +  6] = 0.0;     _body_buffer[off +  7] = pos.y + _body_y_off[i]
	_body_buffer[off +  8] =  s * sx; _body_buffer[off +  9] = 0.0; _body_buffer[off + 10] =  c * sz; _body_buffer[off + 11] = pos.z
	# roof
	_roof_buffer[off +  0] =  c * rsx; _roof_buffer[off +  1] = 0.0; _roof_buffer[off +  2] = -s * rsz; _roof_buffer[off +  3] = pos.x
	_roof_buffer[off +  4] = 0.0;      _roof_buffer[off +  5] = rsy; _roof_buffer[off +  6] = 0.0;      _roof_buffer[off +  7] = pos.y + _roof_y_off[i]
	_roof_buffer[off +  8] =  s * rsx; _roof_buffer[off +  9] = 0.0; _roof_buffer[off + 10] =  c * rsz; _roof_buffer[off + 11] = pos.z

	var woff := i * 4 * 16
	var boff := i * 2 * 16

	# ── (c) LOD: lejos de cámara → transforms degenerados para ruedas + luces ─
	var dx := pos.x - cam_x
	var dz := pos.z - cam_z
	if dx * dx + dz * dz > lod_dist_sq:
		# Zero-out sólo los 12 floats de transform de cada instancia; los 4 de
		# color (12-15) los preserva _update_slot y valen cuando el slot vuelve
		# a entrar en near-LOD.
		for wk in range(4):
			var o := woff + wk * 16
			_wheel_buffer[o +  0] = 0.0; _wheel_buffer[o +  1] = 0.0; _wheel_buffer[o +  2] = 0.0; _wheel_buffer[o +  3] = 0.0
			_wheel_buffer[o +  4] = 0.0; _wheel_buffer[o +  5] = 0.0; _wheel_buffer[o +  6] = 0.0; _wheel_buffer[o +  7] = 0.0
			_wheel_buffer[o +  8] = 0.0; _wheel_buffer[o +  9] = 0.0; _wheel_buffer[o + 10] = 0.0; _wheel_buffer[o + 11] = 0.0
		for bk in range(2):
			var ob := boff + bk * 16
			_brake_buffer[ob +  0] = 0.0; _brake_buffer[ob +  1] = 0.0; _brake_buffer[ob +  2] = 0.0; _brake_buffer[ob +  3] = 0.0
			_brake_buffer[ob +  4] = 0.0; _brake_buffer[ob +  5] = 0.0; _brake_buffer[ob +  6] = 0.0; _brake_buffer[ob +  7] = 0.0
			_brake_buffer[ob +  8] = 0.0; _brake_buffer[ob +  9] = 0.0; _brake_buffer[ob + 10] = 0.0; _brake_buffer[ob + 11] = 0.0
		return

	# ── (d) Near-LOD: ruedas con rodadura + luces de freno ───────────────────
	# Ángulo de rodadura acumulado (v/R · Δt). Modulo TAU para evitar drift
	# de precisión float32 tras horas de simulación.
	var wa := _wheel_angle[i] + _velocity[i] * delta * _inv_wheel_r
	if wa >= TAU or wa <= -TAU:
		wa = fmod(wa, TAU)
	_wheel_angle[i] = wa
	var cw := cos(wa)
	var sw := sin(wa)
	# Basis = R_y_world(h) · R_z(-π/2) · R_y_mesh(w): tumba el cilindro
	# (eje Y → eje X del vehículo) y lo hace rodar alrededor de ese eje.
	var wr0_x := s * sw;   var wr0_y := c;    var wr0_z := -s * cw
	var wr1_x := -cw;      var wr1_y := 0.0;  var wr1_z := -sw
	var wr2_x := -c * sw;  var wr2_y := s;    var wr2_z := c * cw
	var wheel_r := Config.VehicleRendering.WHEEL_RADIUS
	var wy := pos.y + wheel_r  # centro de rueda sobre el suelo
	var wsx := _wheel_sep_x[i]
	var wsz := _wheel_sep_z[i]
	var c_wsx := c * wsx; var s_wsx := s * wsx
	var c_wsz := c * wsz; var s_wsz := s * wsz
	# FR (+wsx, -wsz)
	_wheel_buffer[woff +  0] = wr0_x; _wheel_buffer[woff +  1] = wr0_y; _wheel_buffer[woff +  2] = wr0_z; _wheel_buffer[woff +  3] = pos.x + c_wsx + s_wsz
	_wheel_buffer[woff +  4] = wr1_x; _wheel_buffer[woff +  5] = wr1_y; _wheel_buffer[woff +  6] = wr1_z; _wheel_buffer[woff +  7] = wy
	_wheel_buffer[woff +  8] = wr2_x; _wheel_buffer[woff +  9] = wr2_y; _wheel_buffer[woff + 10] = wr2_z; _wheel_buffer[woff + 11] = pos.z + s_wsx - c_wsz
	# FL (-wsx, -wsz)
	_wheel_buffer[woff + 16] = wr0_x; _wheel_buffer[woff + 17] = wr0_y; _wheel_buffer[woff + 18] = wr0_z; _wheel_buffer[woff + 19] = pos.x - c_wsx + s_wsz
	_wheel_buffer[woff + 20] = wr1_x; _wheel_buffer[woff + 21] = wr1_y; _wheel_buffer[woff + 22] = wr1_z; _wheel_buffer[woff + 23] = wy
	_wheel_buffer[woff + 24] = wr2_x; _wheel_buffer[woff + 25] = wr2_y; _wheel_buffer[woff + 26] = wr2_z; _wheel_buffer[woff + 27] = pos.z - s_wsx - c_wsz
	# RR (+wsx, +wsz)
	_wheel_buffer[woff + 32] = wr0_x; _wheel_buffer[woff + 33] = wr0_y; _wheel_buffer[woff + 34] = wr0_z; _wheel_buffer[woff + 35] = pos.x + c_wsx - s_wsz
	_wheel_buffer[woff + 36] = wr1_x; _wheel_buffer[woff + 37] = wr1_y; _wheel_buffer[woff + 38] = wr1_z; _wheel_buffer[woff + 39] = wy
	_wheel_buffer[woff + 40] = wr2_x; _wheel_buffer[woff + 41] = wr2_y; _wheel_buffer[woff + 42] = wr2_z; _wheel_buffer[woff + 43] = pos.z + s_wsx + c_wsz
	# RL (-wsx, +wsz)
	_wheel_buffer[woff + 48] = wr0_x; _wheel_buffer[woff + 49] = wr0_y; _wheel_buffer[woff + 50] = wr0_z; _wheel_buffer[woff + 51] = pos.x - c_wsx - s_wsz
	_wheel_buffer[woff + 52] = wr1_x; _wheel_buffer[woff + 53] = wr1_y; _wheel_buffer[woff + 54] = wr1_z; _wheel_buffer[woff + 55] = wy
	_wheel_buffer[woff + 56] = wr2_x; _wheel_buffer[woff + 57] = wr2_y; _wheel_buffer[woff + 58] = wr2_z; _wheel_buffer[woff + 59] = pos.z - s_wsx + c_wsz

	# Luces de freno: 2 instancias traseras. Pos local: (±real_w·0.35, real_h·0.55, real_l·0.5 + 0.04)
	var real_l := Config.VehicleRendering.BODY_LENGTH * sz
	var real_h := Config.VehicleRendering.BODY_HEIGHT * sy
	var real_w := Config.VehicleRendering.BODY_WIDTH * sx
	var bl_lx := real_w * 0.35
	var bl_ly := real_h * 0.55
	var bl_lz := real_l * 0.5 + 0.04
	# BL-right (+bl_lx, +bl_lz)
	_brake_buffer[boff +  0] = c;   _brake_buffer[boff +  1] = 0.0; _brake_buffer[boff +  2] = -s;  _brake_buffer[boff +  3] = pos.x + c * bl_lx - s * bl_lz
	_brake_buffer[boff +  4] = 0.0; _brake_buffer[boff +  5] = 1.0; _brake_buffer[boff +  6] = 0.0; _brake_buffer[boff +  7] = pos.y + bl_ly
	_brake_buffer[boff +  8] = s;   _brake_buffer[boff +  9] = 0.0; _brake_buffer[boff + 10] =  c;  _brake_buffer[boff + 11] = pos.z + s * bl_lx + c * bl_lz
	# BL-left (-bl_lx, +bl_lz)
	_brake_buffer[boff + 16] = c;   _brake_buffer[boff + 17] = 0.0; _brake_buffer[boff + 18] = -s;  _brake_buffer[boff + 19] = pos.x - c * bl_lx - s * bl_lz
	_brake_buffer[boff + 20] = 0.0; _brake_buffer[boff + 21] = 1.0; _brake_buffer[boff + 22] = 0.0; _brake_buffer[boff + 23] = pos.y + bl_ly
	_brake_buffer[boff + 24] = s;   _brake_buffer[boff + 25] = 0.0; _brake_buffer[boff + 26] =  c;  _brake_buffer[boff + 27] = pos.z - s * bl_lx + c * bl_lz


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
	_snap_old_pos.resize(max_v);      _snap_old_pos.fill(Vector3.ZERO)
	_snap_new_pos.resize(max_v);    _snap_new_pos.fill(Vector3.ZERO)
	_snap_old_heading.resize(max_v);  _snap_old_heading.fill(0.0)
	_snap_new_heading.resize(max_v);_snap_new_heading.fill(0.0)
	_snap_old_time.resize(max_v); _snap_old_time.fill(0.0)
	_snap_new_time.resize(max_v); _snap_new_time.fill(0.0)
	_velocity.resize(max_v);      _velocity.fill(0.0)
	_acceleration.resize(max_v);  _acceleration.fill(0.0)
	_forward_x.resize(max_v);     _forward_x.fill(0.0)
	_forward_z.resize(max_v);     _forward_z.fill(-1.0)   # Default facing North
	_lerp_t.resize(max_v);        _lerp_t.fill(-1.0)      # -1 = not initialised

	# Escalas por-slot: inicializadas a 1.0 (car default) hasta que llegue el
	# primer update con vtype/lane.
	_scale_x.resize(max_v);       _scale_x.fill(1.0)
	_scale_y.resize(max_v);       _scale_y.fill(1.0)
	_scale_z.resize(max_v);       _scale_z.fill(1.0)
	_roof_scale_x.resize(max_v);  _roof_scale_x.fill(1.0)
	_roof_scale_y.resize(max_v);  _roof_scale_y.fill(1.0)
	_roof_scale_z.resize(max_v);  _roof_scale_z.fill(1.0)
	_body_y_off.resize(max_v);    _body_y_off.fill(Config.VehicleRendering.BODY_Y_OFFSET)
	_roof_y_off.resize(max_v);    _roof_y_off.fill(Config.VehicleRendering.ROOF_Y_OFFSET)
	_slot_vtype.resize(max_v);    _slot_vtype.fill("")
	_slot_status.resize(max_v);   _slot_status.fill("")
	# Estado de ruedas
	_wheel_angle.resize(max_v);   _wheel_angle.fill(0.0)
	_wheel_sep_x.resize(max_v);   _wheel_sep_x.fill(Config.VehicleRendering.VehicleSize.CAR_WIDTH * 0.5)
	_wheel_sep_z.resize(max_v);   _wheel_sep_z.fill(Config.VehicleRendering.VehicleSize.CAR_LENGTH * 0.35)

	# Raw MultiMesh buffers: 16 floats per instance (12 transform + 4 color)
	_body_buffer.resize(max_v * 16)
	_body_buffer.fill(0.0)
	_roof_buffer.resize(max_v * 16)
	_roof_buffer.fill(0.0)
	# 4 ruedas × max_v
	_wheel_buffer.resize(max_v * 4 * 16)
	_wheel_buffer.fill(0.0)
	# 2 luces de freno × max_v
	_brake_buffer.resize(max_v * 2 * 16)
	_brake_buffer.fill(0.0)

	_body_mmi = _make_box_mmi(
		"VehicleBodyMesh",
		Vector3(Config.VehicleRendering.BODY_WIDTH,
				Config.VehicleRendering.BODY_HEIGHT,
				Config.VehicleRendering.BODY_LENGTH),
		max_v
	)
	_body_mmi.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if Config.VehicleRendering.SHADOWS_ENABLED
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	add_child(_body_mmi)

	_roof_mmi = _make_box_mmi(
		"VehicleRoofMesh",
		Vector3(Config.VehicleRendering.ROOF_WIDTH,
				Config.VehicleRendering.ROOF_HEIGHT,
				Config.VehicleRendering.ROOF_LENGTH),
		max_v
	)
	# El techo no proyecta sombra por separado: el cuerpo ya genera una sombra
	# plausible y evitamos duplicar coste de sombra por vehículo.
	_roof_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_roof_mmi)

	# Ruedas — cilindro tumbado horizontalmente por la composición R_y·R_x·R_z(π/2)
	# aplicada en _process (ver _write_wheel_transforms).
	_wheel_mmi = _make_cylinder_mmi(
		"VehicleWheelMesh",
		Config.VehicleRendering.WHEEL_RADIUS,
		Config.VehicleRendering.WHEEL_THICKNESS,
		max_v * 4,
	)
	_wheel_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_wheel_mmi)

	# Luces de freno — caja trasera pequeña con material emisivo modulado por
	# vertex color: rojo brillante al frenar, rojo tenue el resto del tiempo.
	_brake_mmi = _make_brake_light_mmi(
		"VehicleBrakeLightMesh",
		Vector3(0.25, 0.18, 0.08),
		max_v * 2,
	)
	_brake_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_brake_mmi)


## Creates a MultiMeshInstance3D with a BoxMesh of the given size.
func _make_box_mmi(node_name: String, box_size: Vector3, max_instances: int) -> MultiMeshInstance3D:
	var box := BoxMesh.new()
	box.size = box_size

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = Config.VehicleRendering.MATERIAL_ROUGHNESS
	mat.metallic  = Config.VehicleRendering.MATERIAL_METALLIC
	box.surface_set_material(0, mat)

	return _make_mmi_from_mesh(node_name, box, max_instances)


## Creates a MultiMeshInstance3D for brake lights: small box with emissive
## material driven by per-instance vertex color. When the vertex color is
## bright red the emission kicks in and the light visibly "glows"; when it's
## dim red, the emission stays minimal.
func _make_brake_light_mmi(
	node_name: String,
	box_size: Vector3,
	max_instances: int,
) -> MultiMeshInstance3D:
	var box := BoxMesh.new()
	box.size = box_size

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.5
	mat.metallic  = 0.0
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.1, 0.1)  # Color base del piloto trasero
	# La energía se multiplica por el albedo (vertex color) y, como el vertex
	# rojo brillante = (1, 0.08, 0.08) vs tenue = (0.22, 0.02, 0.02), la
	# emisión se amortigua automáticamente cuando la luz está apagada.
	mat.emission_energy_multiplier = 1.5
	box.surface_set_material(0, mat)

	return _make_mmi_from_mesh(node_name, box, max_instances)


## Creates a MultiMeshInstance3D with a short CylinderMesh shaped like a wheel.
## The mesh is emitted "standing" (axis along Y); the transform in _process
## applies R_z(π/2) via composition so wheels end up lying on the X axis.
func _make_cylinder_mmi(
	node_name: String,
	radius: float,
	thickness: float,
	max_instances: int
) -> MultiMeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius    = radius
	cyl.bottom_radius = radius
	cyl.height        = thickness
	cyl.radial_segments = 12
	cyl.rings           = 1

	var mat := StandardMaterial3D.new()
	# Color fijo (no modulado por vertex color): nunca escribimos color por-rueda.
	mat.vertex_color_use_as_albedo = false
	mat.roughness = 0.9
	mat.metallic  = 0.0
	mat.albedo_color = Color(0.12, 0.12, 0.14)  # tonalidad de neumático
	cyl.surface_set_material(0, mat)

	return _make_mmi_from_mesh(node_name, cyl, max_instances)


func _make_mmi_from_mesh(
	node_name: String,
	mesh: Mesh,
	max_instances: int,
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format       = MultiMesh.TRANSFORM_3D
	mm.use_colors             = true
	mm.use_custom_data        = false
	mm.mesh                   = mesh
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
	VehicleManager.vehicle_removed.connect(_on_vehicle_removed)
	SimulationClient.connected.connect(_on_ws_connected)
	# Consumimos el tick directamente de SimulationClient en lugar de recibir
	# un `vehicle_updated` por vehículo desde VehicleManager. Con 6000 vehículos
	# los 60 000 signal dispatches/s bloqueaban el main thread y provocaban
	# tirones. Aquí iteramos el array completo una sola vez por tick.
	SimulationClient.tick_received.connect(_on_server_tick)


func _on_server_tick(_tick: int, sim_time: float, vehicle_states: Array) -> void:
	if sim_time > _latest_server_sim_time:
		_latest_server_sim_time = sim_time

	# Batch update: una única pasada por todos los vehículos activos del tick.
	# Saltamos los que aún no tienen slot asignado — vehicles_batch_added los
	# registrará antes que vehicle_updated en la siguiente secuencia de señales.
	for state in vehicle_states:
		if not state is Dictionary:
			continue
		var vid: String = state.get("id", "")
		if vid.is_empty():
			continue
		var slot_val = _id_to_slot.get(vid, -1)
		if slot_val == -1:
			continue
		# Sella el sim_time del tick (VehicleManager también lo hace en su dict
		# para UI queries, pero nosotros trabajamos con la copia del array).
		if not state.has("_sim_time"):
			state["_sim_time"] = sim_time
		_update_slot(int(slot_val), state)


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
	_snap_old_pos[dst]      = _snap_old_pos[src]
	_snap_new_pos[dst]    = _snap_new_pos[src]
	_snap_old_heading[dst]  = _snap_old_heading[src]
	_snap_new_heading[dst]= _snap_new_heading[src]
	_snap_old_time[dst]   = _snap_old_time[src]
	_snap_new_time[dst]   = _snap_new_time[src]
	_velocity[dst]      = _velocity[src]
	_acceleration[dst]  = _acceleration[src]
	_forward_x[dst]     = _forward_x[src]
	_forward_z[dst]     = _forward_z[src]
	_lerp_t[dst]        = _lerp_t[src]
	# Escalas y offsets por-slot (dependientes del vtype).
	_scale_x[dst]       = _scale_x[src]
	_scale_y[dst]       = _scale_y[src]
	_scale_z[dst]       = _scale_z[src]
	_roof_scale_x[dst]  = _roof_scale_x[src]
	_roof_scale_y[dst]  = _roof_scale_y[src]
	_roof_scale_z[dst]  = _roof_scale_z[src]
	_body_y_off[dst]    = _body_y_off[src]
	_roof_y_off[dst]    = _roof_y_off[src]
	_slot_vtype[dst]    = _slot_vtype[src]
	_slot_status[dst]   = _slot_status[src]
	_wheel_angle[dst]   = _wheel_angle[src]
	_wheel_sep_x[dst]   = _wheel_sep_x[src]
	_wheel_sep_z[dst]   = _wheel_sep_z[src]
	# Copiar los 16 floats del buffer (12 transform + 4 color) desde src a dst
	var src_off := src * 16
	var dst_off := dst * 16
	for k in range(16):
		_body_buffer[dst_off + k] = _body_buffer[src_off + k]
		_roof_buffer[dst_off + k] = _roof_buffer[src_off + k]
	# Las 4 ruedas y 2 luces de freno viven en buffers más grandes: copiar
	# sus bloques contiguos (4×16 y 2×16 floats respectivamente).
	var wheel_src := src * 4 * 16
	var wheel_dst := dst * 4 * 16
	for k in range(4 * 16):
		_wheel_buffer[wheel_dst + k] = _wheel_buffer[wheel_src + k]
	var brake_src := src * 2 * 16
	var brake_dst := dst * 2 * 16
	for k in range(2 * 16):
		_brake_buffer[brake_dst + k] = _brake_buffer[brake_src + k]


## Reset a slot's state to its uninitialised defaults.
func _clear_slot(slot: int) -> void:
	_slot_to_id[slot]  = ""
	_slot_vtype[slot]  = ""   # Fuerza re-aplicar scales en el siguiente reuso
	_slot_status[slot] = ""   # Fuerza recalcular la luz de freno en el primer update
	_wheel_angle[slot] = 0.0  # Rueda parada al reutilizar el slot
	_lerp_t[slot]      = -1.0  # Prevents _process from rendering this slot


func _on_ws_connected() -> void:
	_active_count = 0
	_id_to_slot.clear()
	_slot_to_id.fill("")
	_lerp_t.fill(-1.0)
	_snap_old_time.fill(0.0)
	_snap_new_time.fill(0.0)
	_body_buffer.fill(0.0)
	_roof_buffer.fill(0.0)
	_wheel_buffer.fill(0.0)
	_brake_buffer.fill(0.0)
	_wheel_angle.fill(0.0)
	_slot_vtype.fill("")
	_slot_status.fill("")
	_latest_server_sim_time = -1.0
	_render_sim_time = -1.0
	_set_visible_count(0)
	_log_info("Reset on WebSocket connect")


func _set_visible_count(count: int) -> void:
	_body_mmi.multimesh.visible_instance_count = count
	_roof_mmi.multimesh.visible_instance_count = count
	_wheel_mmi.multimesh.visible_instance_count = count * 4
	_brake_mmi.multimesh.visible_instance_count = count * 2


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
	var accel      : float  = state.get("a",      0.0)
	var status     : String = state.get("status", "idle")
	var vtype      : String = state.get("vtype",  "car")
	var lane       : int    = int(state.get("lane", 0))
	# Sim-time del snapshot (sellado por VehicleManager con el tick sim_time).
	# Si el estado viene de una ruta antigua (spawn message individual sin sim_time)
	# usamos el último reloj de servidor conocido.
	var sim_time   : float  = float(state.get("_sim_time", _latest_server_sim_time))
	if sim_time < 0.0:
		sim_time = 0.0
	# Mantener el reloj de servidor al día incluso si el handler de
	# SimulationClient.tick_received aún no se ha ejecutado este frame.
	if sim_time > _latest_server_sim_time:
		_latest_server_sim_time = sim_time

	# Aplicar las dimensiones del tipo de vehículo al slot (actualiza sólo
	# cuando el valor cambia realmente para evitar trabajo innecesario).
	_apply_vtype_to_slot(slot, vtype)

	var new_heading := deg_to_rad(heading_deg)
	var new_pos     := _converter.gps_to_godot(lon, lat)
	new_pos.y        = Config.VehicleRendering.CAR_ELEVATION
	# Offset lateral dinámico por carril: (lane + 0.5) · LANE_WIDTH_M a la derecha
	# del centerline (tráfico mano derecha). Equivalente a proyectar perpendicular
	# al heading: right_vector = (cos(h), 0, sin(h)).
	var lane_off := (float(lane) + 0.5) * Config.VehicleRendering.LANE_WIDTH_M
	new_pos.x += cos(new_heading) * lane_off
	new_pos.z += sin(new_heading) * lane_off

	if _lerp_t[slot] < 0.0:
		# ── First snapshot for this slot ─────────────────────────────────────
		# Inicializamos ambos snapshots al mismo punto con una separación
		# artificial de TICK_INTERVAL: así la interpolación arranca con u=1
		# (posición estable) hasta que llegue el siguiente snapshot real.
		_snap_old_pos[slot]     = new_pos
		_snap_new_pos[slot]     = new_pos
		_snap_old_heading[slot] = new_heading
		_snap_new_heading[slot] = new_heading
		_snap_old_time[slot]    = sim_time - Config.VehicleRendering.TICK_INTERVAL
		_snap_new_time[slot]    = sim_time
		_lerp_t[slot]           = 0.0  # initialised flag
		_velocity[slot]         = speed
		_acceleration[slot]     = accel
		_log_debug("Slot %d initialised at (%.1f, %.1f, %.1f)" % [slot, new_pos.x, new_pos.y, new_pos.z])
	else:
		# ── Rotación de snapshots ────────────────────────────────────────────
		# Descarta mensajes fuera de orden (el servidor usa TCP, así que esto
		# sólo pasa si el cliente re-ordenó o recibió un chunk muy retrasado).
		if sim_time <= _snap_new_time[slot]:
			return

		# Detección de teletransporte: si el salto es demasiado grande para
		# interpolar razonablemente, colapsamos los snapshots al punto nuevo.
		var error := _snap_new_pos[slot].distance_to(new_pos)
		var heading_change_deg := rad_to_deg(absf(
			angle_difference(_snap_new_heading[slot], new_heading)
		))
		var should_snap := error > Config.VehicleRendering.SNAP_DISTANCE or \
						   heading_change_deg > Config.VehicleRendering.SNAP_HEADING_DEG
		if should_snap:
			_snap_old_pos[slot]     = new_pos
			_snap_new_pos[slot]     = new_pos
			_snap_old_heading[slot] = new_heading
			_snap_new_heading[slot] = new_heading
			_snap_old_time[slot]    = sim_time - Config.VehicleRendering.TICK_INTERVAL
			_snap_new_time[slot]    = sim_time
			_log_debug("Snap on slot %d (error %.1f m, heading %.1f°)" % [slot, error, heading_change_deg])
		else:
			# Rotación normal: el snapshot "nuevo" pasa a ser "viejo" y el
			# entrante pasa a ser "nuevo". El render_time seguirá avanzando
			# a través del nuevo intervalo [old, new].
			_snap_old_pos[slot]     = _snap_new_pos[slot]
			_snap_old_heading[slot] = _snap_new_heading[slot]
			_snap_old_time[slot]    = _snap_new_time[slot]
			_snap_new_pos[slot]     = new_pos
			_snap_new_heading[slot] = new_heading
			_snap_new_time[slot]    = sim_time

	# EMA de velocidad / aceleración — usadas para:
	#   (1) animación de rodadura de las ruedas en _process,
	#   (2) encendido de luces de freno,
	#   (3) extrapolación de emergencia si el servidor deja de enviar ticks.
	var alpha := Config.VehicleRendering.VELOCITY_EMA_ALPHA
	var inv_a := 1.0 - alpha
	_velocity[slot]        = alpha * speed + inv_a * _velocity[slot]
	_acceleration[slot]    = alpha * accel + inv_a * _acceleration[slot]
	_forward_x[slot]       = sin(new_heading)   # East component
	_forward_z[slot]       = -cos(new_heading)  # South component (-cos because +Z = South)

	# Status colour, modulado por el tipo de vehículo para distinguir visualmente
	# coches / motos / camiones sin duplicar MultiMeshes.
	var color := _get_status_color(status) * _get_vtype_tint(vtype)
	var off   := slot * 16
	_body_buffer[off + 12] = color.r;  _body_buffer[off + 13] = color.g
	_body_buffer[off + 14] = color.b;  _body_buffer[off + 15] = color.a
	_roof_buffer[off + 12] = color.r;  _roof_buffer[off + 13] = color.g
	_roof_buffer[off + 14] = color.b;  _roof_buffer[off + 15] = color.a

	# Luz de freno: rojo brillante al decelerar fuerte o al estar parado, tenue
	# el resto del tiempo (piloto posterior normal). Dos instancias por slot.
	var brake_on := accel < Config.VehicleRendering.BRAKE_LIGHT_ACCEL_THRESHOLD \
				 or status == "stopped"
	var bl_r: float; var bl_g: float; var bl_b: float
	if brake_on:
		bl_r = 1.0;  bl_g = 0.08; bl_b = 0.08
	else:
		bl_r = 0.22; bl_g = 0.02; bl_b = 0.02
	var bloff := slot * 2 * 16
	_brake_buffer[bloff + 12] = bl_r; _brake_buffer[bloff + 13] = bl_g
	_brake_buffer[bloff + 14] = bl_b; _brake_buffer[bloff + 15] = 1.0
	_brake_buffer[bloff + 28] = bl_r; _brake_buffer[bloff + 29] = bl_g
	_brake_buffer[bloff + 30] = bl_b; _brake_buffer[bloff + 31] = 1.0
	_slot_status[slot] = status


func _get_status_color(status: String) -> Color:
	match status:
		"moving":    return Config.VehicleColors.MOVING
		"stopped":   return Config.VehicleColors.STOPPED
		"waiting":   return Config.VehicleColors.WAITING
		"collision": return Config.VehicleColors.COLLISION
		"paused":    return Config.VehicleColors.PAUSED
		_:           return Config.VehicleColors.IDLE


func _get_vtype_tint(vtype: String) -> Color:
	match vtype:
		"moto":  return Config.VehicleRendering.VehicleTint.MOTO
		"truck": return Config.VehicleRendering.VehicleTint.TRUCK
		_:       return Config.VehicleRendering.VehicleTint.CAR


## Ajusta las escalas por-slot y los offsets verticales en función del tipo.
## Motos → sin techo (rsy=0). Camiones → más alto/ancho/largo. No-op cuando
## el vtype no ha cambiado desde la última aplicación al slot.
func _apply_vtype_to_slot(slot: int, vtype: String) -> void:
	if _slot_vtype[slot] == vtype:
		return
	_slot_vtype[slot] = vtype
	var body_len := Config.VehicleRendering.BODY_LENGTH
	var body_w   := Config.VehicleRendering.BODY_WIDTH
	var body_h   := Config.VehicleRendering.BODY_HEIGHT
	var roof_len := Config.VehicleRendering.ROOF_LENGTH
	var roof_w   := Config.VehicleRendering.ROOF_WIDTH
	var roof_h   := Config.VehicleRendering.ROOF_HEIGHT
	var sizes    := Config.VehicleRendering.VehicleSize

	var real_l: float
	var real_w: float
	var real_h: float
	var show_roof: bool = true
	match vtype:
		"moto":
			real_l = sizes.MOTO_LENGTH
			real_w = sizes.MOTO_WIDTH
			real_h = sizes.MOTO_HEIGHT
			show_roof = false
		"truck":
			real_l = sizes.TRUCK_LENGTH
			real_w = sizes.TRUCK_WIDTH
			real_h = sizes.TRUCK_HEIGHT
		_:  # car y fallback
			real_l = sizes.CAR_LENGTH
			real_w = sizes.CAR_WIDTH
			real_h = sizes.CAR_HEIGHT

	_scale_x[slot] = real_w / body_w
	_scale_y[slot] = real_h / body_h
	_scale_z[slot] = real_l / body_len
	_body_y_off[slot] = real_h * 0.5
	# Ruedas posicionadas ligeramente dentro de la caja del vehículo
	# (0.45·ancho desde el centro → 0.05·ancho de inset por lado), y a 0.35·largo
	# desde el centro (~70% de la distancia entre ejes para un sedán típico).
	_wheel_sep_x[slot] = real_w * 0.45
	_wheel_sep_z[slot] = real_l * 0.35

	if show_roof:
		# Techo proporcional al vehículo real (no a la base del mesh).
		var roof_real_w := real_w * 0.75
		var roof_real_l := real_l * 0.7
		var roof_real_h := real_h * 0.45
		_roof_scale_x[slot] = roof_real_w / roof_w
		_roof_scale_y[slot] = roof_real_h / roof_h
		_roof_scale_z[slot] = roof_real_l / roof_len
		_roof_y_off[slot] = real_h + roof_real_h * 0.5
	else:
		# Ocultar el techo escalando a 0 (la moto no tiene techo).
		_roof_scale_x[slot] = 0.0
		_roof_scale_y[slot] = 0.0
		_roof_scale_z[slot] = 0.0
		_roof_y_off[slot] = 0.0


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
