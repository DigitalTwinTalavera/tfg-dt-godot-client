## ZoneManager autoload singleton
## Mantiene el catálogo de zonas de control (ZBE / restringidas / peatonales)
## y notifica al renderer al crearse/actualizarse/borrarse.
##
## Protocolo WS:
##   { type: "zone", action: "created"|"updated"|"cleared",
##     zone: { id, name, zone_type, polygon_coords:[[lon,lat],...],
##             enforcement, restricted_vtypes, active, edges_count } }
extends Node


signal zone_created(zone_id: int, data: Dictionary)
signal zone_updated(zone_id: int, data: Dictionary)
signal zone_cleared(zone_id: int, data: Dictionary)


## Estado vivo: { zone_id → zone dict }.
var zones: Dictionary = {}


func _ready() -> void:
	SimulationClient.zone_received.connect(_on_zone)
	SimulationClient.connected.connect(_on_connected)
	_log_info("Initialized")


func get_zone(zone_id: int) -> Dictionary:
	return zones.get(zone_id, {})


func get_all_zones() -> Array:
	return zones.values()


func get_active_zones() -> Array:
	var out: Array = []
	for z in zones.values():
		if bool(z.get("active", true)):
			out.append(z)
	return out


## Handlers ----------------------------------------------------------------

func _on_zone(msg: Dictionary) -> void:
	var action: String = String(msg.get("action", ""))
	var zone: Dictionary = msg.get("zone", {})
	if zone.is_empty():
		_log_warning("Mensaje 'zone' sin payload")
		return
	var zid: int = int(zone.get("id", 0))
	match action:
		"created":
			zones[zid] = zone
			zone_created.emit(zid, zone)
		"updated":
			zones[zid] = zone
			zone_updated.emit(zid, zone)
		"cleared":
			zones.erase(zid)
			zone_cleared.emit(zid, zone)
		_:
			_log_warning("Acción de zona desconocida: '%s'" % action)


func _on_connected() -> void:
	zones.clear()
	_request_initial_snapshot()


func _request_initial_snapshot() -> void:
	var result: HTTPResult = await HTTPManager.get_request("/zones")
	if not result.success or result.data == null:
		return
	var items: Array = result.data.get("zones", [])
	for z in items:
		var zid := int(z.get("id", 0))
		zones[zid] = z
		zone_created.emit(zid, z)


## Logging -----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[ZoneManager] %s" % message)


func _log_warning(message: String) -> void:
	if Config.should_log(Config.LogLevel.WARNING):
		push_warning("[ZoneManager] %s" % message)
