## Global configuration for the Digital Twin Traffic Client
## Contains backend connection settings and application constants
class_name Config
extends RefCounted


## Backend API configuration
const BACKEND_HOST: String = "localhost"
const BACKEND_PORT: int = 8000
const BACKEND_PROTOCOL: String = "http"

## Computed backend URLs
static var base_url: String:
	get:
		return "%s://%s:%d" % [BACKEND_PROTOCOL, BACKEND_HOST, BACKEND_PORT]

static var api_url: String:
	get:
		return "%s/api" % base_url

static var ws_url: String:
	get:
		return "ws://%s:%d/ws/simulation" % [BACKEND_HOST, BACKEND_PORT]


## HTTP client configuration
const HTTP_TIMEOUT_SECONDS: float = 10.0
const HTTP_MAX_RETRIES: int = 3
const HTTP_RETRY_DELAY_SECONDS: float = 1.0


## API endpoints
class Endpoints:
	const HEALTH: String = "/health"
	const HEALTH_DETAILED: String = "/health/detailed"
	const MAP_IMPORT: String = "/map/import"
	const MAP_IMPORT_STATUS: String = "/map/import/status"


## Application settings
const APP_NAME: String = "Digital Twin Traffic Client"
const APP_VERSION: String = "0.1.0"
const DEBUG_MODE: bool = true


## Logging levels
enum LogLevel {
	DEBUG,
	INFO,
	WARNING,
	ERROR
}

const CURRENT_LOG_LEVEL: LogLevel = LogLevel.DEBUG


## Helper to check if we should log at a given level
static func should_log(level: LogLevel) -> bool:
	return level >= CURRENT_LOG_LEVEL


## Helper to get full endpoint URL
static func get_endpoint_url(endpoint: String) -> String:
	return api_url + endpoint
