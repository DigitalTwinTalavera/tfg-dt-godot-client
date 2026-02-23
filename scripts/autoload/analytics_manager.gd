## AnalyticsManager autoload singleton
## Receives analytics_update messages from SimulationClient and maintains
## the latest simulation analytics snapshot.
##
## Stub implementation — to be expanded in a future sprint with
## charts, KPI panels, and export functionality.
extends Node


## Emitted when analytics data is updated
signal analytics_updated(data: Dictionary)


## Latest analytics snapshot
var latest: Dictionary = {}

## Total analytics updates received since last connect
var update_count: int = 0


func _ready() -> void:
	SimulationClient.analytics_received.connect(_on_analytics)
	SimulationClient.connected.connect(_on_connected)
	_log_info("Initialized (stub)")


func get_value(key: String, default: Variant = null) -> Variant:
	return latest.get(key, default)


## Handlers ----------------------------------------------------------------

func _on_analytics(data: Dictionary) -> void:
	latest.merge(data, true)
	update_count += 1
	analytics_updated.emit(latest)
	_log_debug("Analytics updated (#%d)" % update_count)


func _on_connected() -> void:
	latest.clear()
	update_count = 0


## Logging -----------------------------------------------------------------

func _log_info(message: String) -> void:
	if Config.should_log(Config.LogLevel.INFO):
		print("[AnalyticsManager] %s" % message)


func _log_debug(message: String) -> void:
	if Config.should_log(Config.LogLevel.DEBUG):
		print("[AnalyticsManager] %s" % message)
