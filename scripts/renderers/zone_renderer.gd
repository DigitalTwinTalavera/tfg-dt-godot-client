## ZoneRenderer
## Dibuja cada zona de control como un polígono traslúcido elevado ligeramente
## sobre el suelo. Geometría construida con SurfaceTool + triangulate_polygon.
##
## Se enlaza vía ZoneManager (autoload). La escena contenedora debe llamar a
## ``setup(converter)`` una sola vez tras cargar la red.
class_name ZoneRenderer
extends Node3D


const POLYGON_HEIGHT_M: float = 0.5
## Toma el valor de Config.ZoneTypeColors.POLYGON_ALPHA en runtime — usado como
## var (no const) para evitar referencias a class constants en const expressions.
static var POLYGON_ALPHA: float = Config.ZoneTypeColors.POLYGON_ALPHA


var _converter: CoordinateConverter = null

## zone_id → MeshInstance3D
var _meshes: Dictionary = {}


func _ready() -> void:
	ZoneManager.zone_created.connect(_on_created)
	ZoneManager.zone_updated.connect(_on_updated)
	ZoneManager.zone_cleared.connect(_on_cleared)


func setup(converter: CoordinateConverter) -> void:
	_converter = converter
	for zid in ZoneManager.zones:
		_on_created(zid, ZoneManager.zones[zid])


func _on_created(zone_id: int, data: Dictionary) -> void:
	if _converter == null:
		return
	if not bool(data.get("active", true)):
		return
	var mesh := _build_zone_mesh(data)
	if mesh == null:
		return
	_meshes[zone_id] = mesh
	add_child(mesh)


func _on_updated(zone_id: int, data: Dictionary) -> void:
	var existing: MeshInstance3D = _meshes.get(zone_id, null)
	if existing != null:
		existing.queue_free()
		_meshes.erase(zone_id)
	_on_created(zone_id, data)


func _on_cleared(zone_id: int, _data: Dictionary) -> void:
	var existing: MeshInstance3D = _meshes.get(zone_id, null)
	if existing != null:
		existing.queue_free()
		_meshes.erase(zone_id)


func _color_for_type(zone_type: String) -> Color:
	var base: Color
	match zone_type:
		"zbe":
			base = Config.ZoneTypeColors.ZBE
		"pedestrian":
			base = Config.ZoneTypeColors.PEDESTRIAN
		"restricted":
			base = Config.ZoneTypeColors.RESTRICTED
		_:
			base = Config.ZoneTypeColors.UNKNOWN
	return Color(base.r, base.g, base.b, POLYGON_ALPHA)


func _build_zone_mesh(data: Dictionary) -> MeshInstance3D:
	var coords: Array = data.get("polygon_coords", [])
	if coords.size() < 3:
		return null

	# Convertir cada par [lon, lat] a Vector3 sobre el plano del suelo.
	var pts3d: PackedVector3Array = PackedVector3Array()
	var pts2d: PackedVector2Array = PackedVector2Array()
	for p in coords:
		if p.size() < 2:
			continue
		var world: Vector3 = _converter.gps_to_godot(float(p[0]), float(p[1]), 0.0)
		pts3d.append(world)
		pts2d.append(Vector2(world.x, world.z))

	var indices: PackedInt32Array = Geometry2D.triangulate_polygon(pts2d)
	if indices.size() < 3:
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for idx in indices:
		var v := pts3d[idx]
		st.add_vertex(Vector3(v.x, POLYGON_HEIGHT_M, v.z))

	var mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color_for_type(String(data.get("zone_type", "")))
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.name = "Zone_%d" % int(data.get("id", 0))
	return mi
