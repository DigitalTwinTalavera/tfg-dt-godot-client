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
	const MAP_NODES: String = "/map/nodes"
	const MAP_EDGES: String = "/map/edges"


## Network loading configuration
const NETWORK_PAGE_SIZE: int = 1000
const NETWORK_MAX_RETRIES: int = 3
const NETWORK_RETRY_DELAY: float = 1.0
const NETWORK_PAGINATION_DELAY: float = 0.01  # Delay between paginated requests
const NETWORK_PROGRESS_NODES_WEIGHT: float = 0.5  # Progress weight for nodes loading
const NETWORK_PROGRESS_EDGES_WEIGHT: float = 0.5  # Progress weight for edges loading

## HTTP internal configuration
const HTTP_TIMEOUT_BUFFER: float = 1.0  # Extra buffer added to timeout timer


## Road type colors for visualization (matching OSM road hierarchy)
class RoadColors:
	const MOTORWAY: Color = Color(0.0, 0.2, 0.4)       # Dark Blue #003366
	const MOTORWAY_LINK: Color = Color(0.0, 0.3, 0.5)  # Slightly lighter
	const TRUNK: Color = Color(0.0, 0.4, 0.6)          # Medium Blue
	const TRUNK_LINK: Color = Color(0.0, 0.5, 0.7)
	const PRIMARY: Color = Color(1.0, 0.8, 0.0)        # Yellow #FFCC00
	const PRIMARY_LINK: Color = Color(1.0, 0.85, 0.2)
	const SECONDARY: Color = Color(1.0, 0.53, 0.0)     # Orange #FF8800
	const SECONDARY_LINK: Color = Color(1.0, 0.6, 0.2)
	const TERTIARY: Color = Color(1.0, 0.67, 0.27)     # Light Orange #FFAA44
	const TERTIARY_LINK: Color = Color(1.0, 0.75, 0.4)
	const RESIDENTIAL: Color = Color(1.0, 1.0, 1.0)    # White #FFFFFF
	const SERVICE: Color = Color(0.8, 0.8, 0.8)        # Light Gray #CCCCCC
	const UNCLASSIFIED: Color = Color(0.7, 0.7, 0.7)   # Gray
	const LIVING_STREET: Color = Color(0.9, 0.9, 0.9)  # Very light gray
	const UNKNOWN: Color = Color(0.5, 0.5, 0.5)        # Default gray


## Node type colors for visualization
class NodeColors:
	const INTERSECTION: Color = Color(0.5, 0.5, 0.5)      # Gray #808080
	const TRAFFIC_LIGHT: Color = Color(1.0, 0.0, 0.0)     # Red #FF0000
	const ROUNDABOUT: Color = Color(0.0, 0.5, 1.0)        # Blue #0080FF
	const DEAD_END: Color = Color(0.25, 0.25, 0.25)       # Dark Gray #404040
	const ENTRY_POINT: Color = Color(0.0, 1.0, 0.0)       # Green #00FF00
	const EXIT_POINT: Color = Color(1.0, 0.65, 0.0)       # Orange #FFA500
	const UNKNOWN: Color = Color(0.5, 0.5, 0.5)           # Gray (default)


## Node rendering configuration
class NodeRendering:
	const DEFAULT_RADIUS: float = 3.0           # Node sphere radius in meters
	const SPHERE_RADIAL_SEGMENTS: int = 16      # Low-poly for performance
	const SPHERE_RINGS: int = 8                 # Low-poly for performance
	const LOD_DISTANCE_HIDE: float = 5000.0     # Distance to hide nodes
	const LOD_DISTANCE_LOW: float = 2000.0      # Distance for low detail
	const LOD_LOW_SCALE: float = 0.5            # Scale factor at low LOD
	const SELECTION_HIGHLIGHT_SCALE: float = 1.3  # Scale when selected
	const HOVER_HIGHLIGHT_SCALE: float = 1.15   # Scale when hovered
	const RAYCAST_MAX_DISTANCE: float = 10000.0 # Max raycast distance for node picking


## Edge/Road rendering configuration
class EdgeRendering:
	## Road width per lane in meters
	const LANE_WIDTH: float = 3.0

	## Default road widths based on lane count
	const WIDTH_1_LANE: float = 3.0   # 1 lane
	const WIDTH_2_LANES: float = 6.0  # 2 lanes
	const WIDTH_3_LANES: float = 9.0  # 3 lanes
	const WIDTH_4_LANES: float = 12.0 # 4+ lanes

	## Road height (thickness) above ground
	const ROAD_HEIGHT: float = 0.2

	## Road elevation above ground (to avoid z-fighting)
	const ROAD_ELEVATION: float = 0.1

	## LOD distances
	const LOD_DISTANCE_HIDE: float = 8000.0      # Distance to hide roads
	const LOD_DISTANCE_SIMPLIFY: float = 3000.0  # Distance to simplify geometry

	## Geometry simplification
	const MIN_SEGMENT_LENGTH: float = 5.0        # Minimum segment length in meters
	const LOD_MIN_SEGMENT_LENGTH: float = 20.0   # Minimum segment for LOD

	## One-way arrow settings
	const ARROW_SPACING: float = 50.0     # Meters between arrows
	const ARROW_SIZE: float = 4.0         # Arrow size in meters
	const ARROW_HEIGHT: float = 0.3       # Arrow height above road

	## Selection/highlight
	const SELECTION_WIDTH_MULTIPLIER: float = 1.2
	const HOVER_WIDTH_MULTIPLIER: float = 1.1


## Coordinate conversion constants
class Coordinates:
	## Meters per degree of latitude (approximately constant worldwide)
	const METERS_PER_DEGREE_LAT: float = 111320.0

	## Earth's radius in meters (WGS84 mean radius)
	const EARTH_RADIUS_METERS: float = 6371000.0

	## Default location: Talavera de la Reina, Spain
	const DEFAULT_CENTER_LON: float = -4.8300
	const DEFAULT_CENTER_LAT: float = 39.9600

	## Coordinate precision for comparisons
	const GPS_PRECISION: float = 0.000001  # ~0.1 meters
	const METERS_PRECISION: float = 0.01   # 1 centimeter


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
