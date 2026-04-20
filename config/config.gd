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


## WebSocket client configuration
const WS_MAX_QUEUE_SIZE: int = 1000           # Maximum messages buffered before dropping oldest
const WS_MAX_MESSAGES_PER_FRAME: int = 50     # Messages drained per _process() call
const WS_BASE_RECONNECT_DELAY: float = 1.0    # Initial reconnect wait (seconds)
const WS_MAX_RECONNECT_DELAY: float = 60.0    # Maximum reconnect wait (seconds)
const WS_STATS_LOG_INTERVAL: float = 5.0      # Seconds between periodic stat logs


## Simulation API endpoints
class SimEndpoints:
	const START: String = "/simulation/start"
	const STOP: String = "/simulation/stop"
	const PAUSE: String = "/simulation/pause"
	const RESUME: String = "/simulation/resume"
	const STATUS: String = "/simulation/status"
	const CONFIG: String = "/simulation/config"
	const VEHICLES: String = "/simulation/vehicles"
	const VEHICLES_SPAWN: String = "/simulation/vehicles/spawn"
	const TRAFFIC_LIGHTS: String = "/simulation/traffic-lights"
	const TL_ALL_GREEN: String = "/simulation/traffic-lights/all-green"
	const TL_ALL_RED: String = "/simulation/traffic-lights/all-red"
	const TL_NORMAL: String = "/simulation/traffic-lights/normal"


## WebSocket message type constants
class SimMessageTypes:
	const TICK: String = "tick"
	const SIM_STATE: String = "sim_state"
	const VEHICLE_SPAWNED: String = "vehicle_spawned"
	const VEHICLE_FINISHED: String = "vehicle_finished"
	const VEHICLES_BATCH_SPAWNED: String = "vehicles_batch_spawned"
	const TRAFFIC_LIGHT: String = "traffic_light"


## Road type colors — light theme, high contrast over near-white ground
## (readable in projectors with strong ambient light)
class RoadColors:
	const MOTORWAY: Color       = Color(0.10, 0.22, 0.48)   # Deep Blue
	const MOTORWAY_LINK: Color  = Color(0.15, 0.30, 0.55)
	const TRUNK: Color          = Color(0.18, 0.38, 0.62)
	const TRUNK_LINK: Color     = Color(0.22, 0.45, 0.68)
	const PRIMARY: Color        = Color(0.85, 0.55, 0.00)   # Strong Orange
	const PRIMARY_LINK: Color   = Color(0.88, 0.62, 0.12)
	const SECONDARY: Color      = Color(0.82, 0.30, 0.05)   # Red-orange
	const SECONDARY_LINK: Color = Color(0.85, 0.40, 0.15)
	const TERTIARY: Color       = Color(0.70, 0.45, 0.15)
	const TERTIARY_LINK: Color  = Color(0.72, 0.52, 0.22)
	const RESIDENTIAL: Color    = Color(0.30, 0.32, 0.36)   # Dark gray — not white, to stand out
	const SERVICE: Color        = Color(0.45, 0.47, 0.50)
	const UNCLASSIFIED: Color   = Color(0.40, 0.42, 0.46)
	const LIVING_STREET: Color  = Color(0.55, 0.55, 0.58)
	const UNKNOWN: Color        = Color(0.35, 0.35, 0.38)


## Node type colors — saturated and dark so they pop on a light ground
class NodeColors:
	const INTERSECTION: Color = Color(0.22, 0.25, 0.30)   # Near-black
	const TRAFFIC_LIGHT: Color= Color(0.85, 0.08, 0.10)   # Strong red
	const ROUNDABOUT: Color   = Color(0.05, 0.35, 0.70)   # Deep blue
	const DEAD_END: Color     = Color(0.15, 0.15, 0.18)
	const ENTRY_POINT: Color  = Color(0.05, 0.55, 0.20)   # Deep green
	const EXIT_POINT: Color   = Color(0.85, 0.40, 0.05)   # Deep orange
	const UNKNOWN: Color      = Color(0.40, 0.42, 0.46)


## Vehicle status colors — high-saturation so cars read at a glance on white
class VehicleColors:
	const MOVING: Color    = Color(0.05, 0.35, 0.85)   # Strong blue
	const STOPPED: Color   = Color(0.82, 0.08, 0.12)   # Strong red
	const WAITING: Color   = Color(0.95, 0.70, 0.00)   # Saturated amber
	const IDLE: Color      = Color(0.95, 0.70, 0.00)
	const COLLISION: Color = Color(0.95, 0.30, 0.00)
	const PAUSED: Color    = Color(0.30, 0.35, 0.60)


## Vehicle rendering configuration
class VehicleRendering:
	const MAX_VEHICLES: int = 10000
	## "Base" mesh dimensions used when generando los BoxMesh de los MultiMesh.
	## Las dimensiones reales de cada vehículo se aplican mediante escala de la
	## base por instancia (length_m / BODY_LENGTH, etc.) — ver vehicle_renderer.
	const BODY_LENGTH: float = 4.0
	const BODY_HEIGHT: float = 1.5
	const BODY_WIDTH: float = 2.0
	const BODY_Y_OFFSET: float = 0.75  # Body centre above road  (= BODY_HEIGHT / 2)
	## Car roof dimensions
	const ROOF_LENGTH: float = 3.0
	const ROOF_HEIGHT: float = 0.7
	const ROOF_WIDTH: float = 1.5
	const ROOF_Y_OFFSET: float = 1.85  # Roof centre above road  (= BODY_HEIGHT + ROOF_HEIGHT / 2)
	## Road clearance (raises vehicles slightly to avoid Z-fighting)
	const CAR_ELEVATION: float = 0.2
	## Anchura estándar de un carril (m). Se usa para posicionar lateralmente cada
	## vehículo según su `lane`: lateral = (lane + 0.5) · LANE_WIDTH_M, proyectado
	## perpendicular al heading (a la derecha para tráfico de mano derecha).
	const LANE_WIDTH_M: float = 3.5
	const MATERIAL_ROUGHNESS: float = 0.4
	const MATERIAL_METALLIC: float = 0.2
	const RAYCAST_MAX_DISTANCE: float = 10000.0
	## Interpolation — smooth movement between 10 Hz server ticks
	const TICK_INTERVAL: float = 0.1       # Expected server tick period (s) at 10 Hz
	const SNAP_DISTANCE: float = 10.0      # Snap without lerp if error > this (metres)
	const SNAP_HEADING_DEG: float = 45.0   # Snap without lerp if heading changes > this (degrees)
	const MAX_DEAD_RECKONING: float = 0.3  # Cap dead-reckoning time (seconds)
	## Suavizado de velocidad — evita que saltos bruscos de `v` en el tick generen
	## tirones visibles durante la extrapolación. v_smooth = α·v_nuevo + (1-α)·v_ant.
	const VELOCITY_EMA_ALPHA: float = 0.4
	## Límite de velocidad angular de interpolación (rad/s). Evita giros instantáneos
	## cuando el backend publica un cambio brusco de heading. 180°/s ≈ π.
	const MAX_YAW_RATE_RAD_S: float = 3.141592653589793
	## Sombras proyectadas por el cuerpo del vehículo. Desactivable para benchmarks
	## en escenas con 10k vehículos donde el coste de sombras dinámicas domina.
	const SHADOWS_ENABLED: bool = true
	## Ruedas: radio (m) y separación longitudinal/lateral respecto al centro del
	## vehículo. Con CYL_MESH, el radio define el tamaño aparente de la rueda.
	const WHEEL_RADIUS: float = 0.33
	const WHEEL_THICKNESS: float = 0.25      # anchura axial
	## Aceleración umbral (m/s²) por debajo de la cual se encienden las luces de
	## freno. Un valor negativo pequeño evita parpadeos ante decelerations leves.
	const BRAKE_LIGHT_ACCEL_THRESHOLD: float = -0.8

	## Tamaños por tipo de vehículo (m). Cada slot del MultiMesh se escala sobre
	## BODY_LENGTH/BODY_WIDTH/BODY_HEIGHT para obtener estas dimensiones reales.
	class VehicleSize:
		const CAR_LENGTH: float = 4.5
		const CAR_WIDTH: float = 1.9
		const CAR_HEIGHT: float = 1.5

		const MOTO_LENGTH: float = 2.1
		const MOTO_WIDTH: float = 0.8
		const MOTO_HEIGHT: float = 1.2

		const TRUCK_LENGTH: float = 10.0
		const TRUCK_WIDTH: float = 2.5
		const TRUCK_HEIGHT: float = 3.2

	## Modulación de color según vtype aplicada al color base de estado. Permite
	## distinguir coches/motos/camiones aunque estén en el mismo estado.
	class VehicleTint:
		const CAR: Color    = Color(1.00, 1.00, 1.00)
		const MOTO: Color   = Color(1.15, 1.05, 0.40)   # tono amarillento
		const TRUCK: Color  = Color(0.65, 0.65, 0.75)   # tono acero


## Node rendering configuration
class NodeRendering:
	const DEFAULT_RADIUS: float = 3.0           # Node sphere radius in meters
	const MAX_RADIUS: float = 50.0              # Maximum node radius cap in meters
	const RADIUS_SCALE_FACTOR: float = 500.0    # Divisor for auto-scaling radius
	const SPHERE_RADIAL_SEGMENTS: int = 16      # Low-poly for performance
	const SPHERE_RINGS: int = 8                 # Low-poly for performance
	const LOD_DISTANCE_HIDE: float = 5000.0     # Distance to hide nodes
	const LOD_DISTANCE_LOW: float = 2000.0      # Distance for low detail
	const LOD_LOW_SCALE: float = 0.5            # Scale factor at low LOD
	const SELECTION_HIGHLIGHT_SCALE: float = 1.3  # Scale when selected
	const HOVER_HIGHLIGHT_SCALE: float = 1.15   # Scale when hovered
	const RAYCAST_MAX_DISTANCE: float = 10000.0 # Max raycast distance for node picking
	const MATERIAL_ROUGHNESS: float = 0.6       # Slightly less matte for a light theme
	const MATERIAL_METALLIC: float = 0.1
	const METALLIC_SPECULAR: float = 0.3
	const EMISSION_ENERGY: float = 0.15         # Subtle emission — dark saturated node colors already pop on light ground

	## Traffic light rendering — se dibuja UNA esfera por arista entrante sobre
	## la línea de stop (no en el centro del nodo). El tamaño se auto-escala
	## igual que las intersecciones, pero reducido, para distinguir los brazos
	## sin que una sola esfera tape el cruce entero.
	const TL_RADIUS_FRACTION: float = 0.35       # fracción del radio de nodo regular
	const TL_OFFSET_FRACTION: float = 1.5        # offset stop-line = TL_OFFSET_FRACTION · radio regular
	const TL_HEIGHT_FRACTION: float = 0.5        # altura vertical del foco = TL_HEIGHT_FRACTION · radio regular
	const TL_SPHERE_SEGMENTS: int = 12
	const TL_SPHERE_RINGS: int = 6


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
	const ARROW_COLOR: Color = Color(0.10, 0.10, 0.10, 0.85)  # Dark arrows, readable over light/mid roads

	## Selection/highlight
	const SELECTION_WIDTH_MULTIPLIER: float = 1.2
	const HOVER_WIDTH_MULTIPLIER: float = 1.1


## Camera controller configuration
class Camera:
	## Movement speeds
	const PAN_SPEED: float = 1.0               # Pan speed multiplier
	const PAN_SCALE_FACTOR: float = 0.001      # Pan distance scale factor
	const ROTATION_SPEED: float = 0.003        # Mouse rotation sensitivity
	const KEYBOARD_MOVE_SPEED: float = 100.0   # WASD movement speed (m/s)
	const KEYBOARD_SPEED_BOOST: float = 3.0    # Speed multiplier when holding Shift

	## Zoom configuration
	const ZOOM_SPEED: float = 50.0             # Zoom step per scroll
	const ZOOM_MIN_DISTANCE: float = 10.0      # Minimum distance from focal point
	const ZOOM_MAX_DISTANCE: float = 10000.0   # Maximum distance from focal point

	## Smoothing (interpolation)
	const SMOOTH_ENABLED: bool = true          # Enable smooth camera movement
	const SMOOTH_POSITION_WEIGHT: float = 10.0 # Position interpolation speed
	const SMOOTH_ROTATION_WEIGHT: float = 10.0 # Rotation interpolation speed

	## Default view
	const DEFAULT_HEIGHT: float = 500.0        # Default camera height (meters)
	const DEFAULT_DISTANCE: float = 500.0      # Default distance from center
	const DEFAULT_PITCH: float = -45.0         # Default pitch angle (degrees)
	const DEFAULT_YAW: float = 0.0             # Default yaw angle (degrees)

	## Limits
	const MIN_HEIGHT: float = 5.0              # Minimum camera Y position
	const MAX_PITCH: float = -5.0              # Maximum pitch (almost horizontal)
	const MIN_PITCH: float = -89.0             # Minimum pitch (almost vertical)

	## Orbit configuration
	const ORBIT_INVERT_Y: bool = false         # Invert Y axis for orbit

	## Focus on bounds configuration
	const BOUNDS_VIEW_MULTIPLIER: float = 0.75 # Multiplier for viewing bounds
	const BOUNDS_DEFAULT_SIZE: float = 1000.0  # Default size when bounds invalid


## UI configuration
class UI:
	## Layout / spacing
	const PANEL_MARGIN: int = 10               # Margin from screen edge
	const PANEL_MIN_WIDTH: int = 250           # Minimum panel width
	const PANEL_OPACITY: float = 0.96          # High opacity so text stays legible over 3D
	const PANEL_CORNER_RADIUS: int = 8         # Corner radius for rounded edges
	const PANEL_CONTENT_MARGIN: int = 12       # Content margin inside panel
	const PANEL_VERTICAL_MARGIN: int = 8       # Vertical margin inside panel
	const PANEL_ITEM_SPACING: int = 6          # Spacing between items
	const BUTTON_HEIGHT: int = 28              # Button minimum height
	const BUTTON_CORNER_RADIUS: int = 4        # Button corner radius

	## Colors — light theme optimised for projector visibility
	## Panels
	const BACKGROUND_COLOR: Color   = Color(0.98, 0.98, 0.98, 0.96)  # Near-white
	const PANEL_BORDER_COLOR: Color = Color(0.78, 0.82, 0.88, 1.0)   # Soft blue-gray border
	const PANEL_SHADOW_COLOR: Color = Color(0.0, 0.0, 0.0, 0.08)     # Very subtle shadow

	## Text
	const TEXT_COLOR: Color           = Color(0.10, 0.12, 0.16)      # Near-black
	const TEXT_SECONDARY_COLOR: Color = Color(0.35, 0.40, 0.48)      # Mid gray
	const TEXT_MUTED_COLOR: Color     = Color(0.55, 0.58, 0.62)

	## Accent (corporate blue — strong contrast on white)
	const ACCENT_COLOR: Color   = Color(0.09, 0.42, 0.78)            # #1769C7
	const ACCENT_HOVER: Color   = Color(0.12, 0.50, 0.90)
	const ACCENT_PRESSED: Color = Color(0.06, 0.32, 0.60)

	## Status / feedback
	const SUCCESS_COLOR: Color = Color(0.10, 0.55, 0.25)             # Deep green
	const WARNING_COLOR: Color = Color(0.88, 0.55, 0.05)             # Deep amber
	const ERROR_COLOR: Color   = Color(0.82, 0.10, 0.15)             # Deep red

	## Neutral widgets
	const SEPARATOR_COLOR: Color       = Color(0.82, 0.84, 0.88)
	const BUTTON_NORMAL_COLOR: Color   = Color(0.93, 0.94, 0.96)
	const BUTTON_HOVER_COLOR: Color    = Color(0.86, 0.89, 0.94)
	const BUTTON_PRESSED_COLOR: Color  = Color(0.78, 0.82, 0.88)
	const BUTTON_DISABLED_COLOR: Color = Color(0.94, 0.94, 0.94)

	## FPS counter
	const FPS_UPDATE_INTERVAL: float = 0.5     # Seconds between FPS updates
	const FPS_SAMPLE_COUNT: int = 30           # Number of frames to average


## Physics conversion constants
class Physics:
	const MS_TO_KMH: float = 3.6
	const KMH_TO_MS: float = 0.2778


## Traffic light phase colors (used by NodeRenderer and GameHUD)
class TLColors:
	const GREEN:  Color = Color(0.0, 0.85, 0.0)
	const YELLOW: Color = Color(1.0, 0.85, 0.0)
	const RED:    Color = Color(0.9, 0.1,  0.1)
	const UNKNOWN:Color = Color(0.5, 0.5,  0.5)


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
