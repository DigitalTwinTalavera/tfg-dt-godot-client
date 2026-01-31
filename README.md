# Digital Twin Traffic Client

Cliente Godot 4.x para el gemelo digital de tráfico urbano de Talavera de la Reina.

## Tabla de Contenidos

- [Descripción](#descripción)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Estructura del Proyecto](#estructura-del-proyecto)
- [Arquitectura](#arquitectura)
- [Configuración](#configuración)
- [Componentes](#componentes)
  - [Capa de Comunicación HTTP](#capa-de-comunicación-http)
  - [Modelos de Datos](#modelos-de-datos)
  - [Gestión de Red Vial](#gestión-de-red-vial)
  - [Conversión de Coordenadas](#conversión-de-coordenadas)
  - [Utilidades](#utilidades)
- [Escenas de Prueba](#escenas-de-prueba)
- [Ejemplos de Uso](#ejemplos-de-uso)
- [API Reference](#api-reference)

---

## Descripción

Este proyecto implementa el frontend 3D para visualizar y controlar la simulación de tráfico urbano. Desarrollado con Godot 4.5 y GDScript, se comunica con el backend FastAPI mediante HTTP y WebSocket.

### Características principales

- **Cliente HTTP** con async/await para comunicación REST con el backend
- **Gestión de red vial** con carga paginada y caché de datos
- **Conversión de coordenadas** GPS (EPSG:4326) a espacio 3D de Godot
- **Renderizado 3D** eficiente con MultiMesh para 5000+ nodos a 60 FPS
- **Modelos de datos** para nodos y aristas de la red vial
- **Sistema de configuración** centralizado
- **Manejo de errores** robusto con timeouts y reintentos
- **Escenas de prueba** para verificar funcionalidad

## Requisitos

- Godot 4.5+ (Forward+ renderer)
- Backend FastAPI ejecutándose (por defecto en `http://localhost:8000`)

## Instalación

### 1. Clonar el repositorio

```bash
git clone <repository-url>
cd tfg-dt-godot-client
```

### 2. Abrir en Godot

1. Abrir Godot 4.5+
2. Importar proyecto: seleccionar la carpeta `tfg-dt-godot-client`
3. Esperar a que Godot importe los recursos

### 3. Verificar el backend

Asegurarse de que el backend está ejecutándose:

```bash
# En el directorio del backend
docker-compose up -d
# o
uvicorn app.main:app --reload
```

### 4. Ejecutar el cliente

1. Presionar F5 o el botón "Play" en Godot
2. Hacer clic en "Check Health" para verificar la conexión
3. Usar las escenas de prueba para verificar funcionalidad

---

## Estructura del Proyecto

```
tfg-dt-godot-client/
├── config/
│   └── config.gd                   # Configuración global
├── scenes/
│   ├── main.tscn                   # Escena del menú principal
│   ├── camera_rig.tscn             # Componente de cámara reutilizable
│   ├── ui/
│   │   └── debug_panel.tscn        # Panel de debug reutilizable
│   └── test_scenes/
│       ├── test_connection.tscn    # Pruebas de conexión HTTP
│       ├── test_load_network.tscn  # Pruebas de carga de red
│       ├── test_coordinates.tscn   # Pruebas de coordenadas
│       └── test_camera.tscn        # Pruebas de controlador de cámara
├── scripts/
│   ├── main.gd                     # Script de escena principal
│   ├── autoload/
│   │   ├── http_manager.gd         # Singleton HTTP
│   │   └── network_manager.gd      # Singleton de red vial
│   ├── camera/
│   │   └── camera_controller.gd    # Controlador de cámara 3D
│   ├── http/
│   │   ├── http_client.gd          # Wrapper HTTP con async/await
│   │   └── http_result.gd          # Clase de respuesta HTTP
│   ├── models/
│   │   ├── node_data.gd            # Nodo de red vial
│   │   ├── edge_data.gd            # Arista de red vial
│   │   └── road_network.gd         # Contenedor de red completa
│   ├── renderers/
│   │   ├── node_renderer.gd        # Renderizado 3D de nodos
│   │   └── edge_renderer.gd        # Renderizado 3D de carreteras
│   ├── ui/
│   │   └── debug_panel.gd          # Panel de debug y estadísticas
│   ├── utils/
│   │   ├── json_utils.gd           # Utilidades JSON
│   │   ├── ui_logger.gd            # Logger para UI
│   │   └── coordinate_converter.gd # Conversión de coordenadas
│   └── test_scenes/
│       ├── test_connection.gd
│       ├── test_load_network.gd
│       ├── test_coordinates.gd
│       ├── test_camera.gd          # Prueba de cámara
│       └── test_node_renderer.gd   # Prueba de renderizado 3D
└── project.godot                   # Configuración del proyecto
```

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────────────┐
│                      Aplicación Godot                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │   Escenas    │    │   Autoloads  │    │    Utilidades    │  │
│  │              │    │              │    │                  │  │
│  │  - main      │───▶│ HTTPManager  │◀───│  JsonUtils       │  │
│  │  - test_*    │    │              │    │  UILogger        │  │
│  │              │───▶│ NetworkMgr   │◀───│  CoordConverter  │  │
│  └──────────────┘    └──────────────┘    └──────────────────┘  │
│         │                   │                                    │
│         │                   ▼                                    │
│         │    ┌──────────────────────────────────────────────┐   │
│         │    │               Modelos de Datos                │   │
│         │    │  NodeData │ EdgeData │ RoadNetwork │ HTTPResult│   │
│         │    └──────────────────────────────────────────────┘   │
│         │                   │                                    │
│         ▼                   ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                     Renderizadores                        │   │
│  │  NodeRenderer: MultiMesh para nodos 3D                    │   │
│  │  EdgeRenderer: ImmediateMesh para carreteras 3D           │   │
│  │  - Renderizado eficiente de redes viales completas        │   │
│  │  - Colores por tipo, ancho por carriles, LOD              │   │
│  └──────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│                        Capa HTTP                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  HTTPClient2: peticiones HTTP con async/await             │   │
│  │  - GET, POST, PUT, DELETE, PATCH                          │   │
│  │  - Parseo automático de JSON                              │   │
│  │  - Manejo de timeouts                                     │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Backend API (FastAPI)                        │
│                    http://localhost:8000                         │
└─────────────────────────────────────────────────────────────────┘
```

---

## Configuración

Toda la configuración está centralizada en `config/config.gd`:

### Conexión al Backend

```gdscript
const BACKEND_HOST: String = "localhost"
const BACKEND_PORT: int = 8000
const BACKEND_PROTOCOL: String = "http"

# URLs calculadas automáticamente
static var base_url: String  # http://localhost:8000
static var api_url: String   # http://localhost:8000/api
static var ws_url: String    # ws://localhost:8000/ws/simulation
```

### Configuración HTTP

```gdscript
const HTTP_TIMEOUT_SECONDS: float = 10.0
const HTTP_MAX_RETRIES: int = 3
const HTTP_RETRY_DELAY_SECONDS: float = 1.0
const HTTP_TIMEOUT_BUFFER: float = 1.0
```

### Carga de Red Vial

```gdscript
const NETWORK_PAGE_SIZE: int = 1000
const NETWORK_MAX_RETRIES: int = 3
const NETWORK_RETRY_DELAY: float = 1.0
const NETWORK_PAGINATION_DELAY: float = 0.01
const NETWORK_PROGRESS_NODES_WEIGHT: float = 0.5
const NETWORK_PROGRESS_EDGES_WEIGHT: float = 0.5
```

### Endpoints de la API

```gdscript
class Endpoints:
    const HEALTH: String = "/health"
    const HEALTH_DETAILED: String = "/health/detailed"
    const MAP_IMPORT: String = "/map/import"
    const MAP_IMPORT_STATUS: String = "/map/import/status"
    const MAP_NODES: String = "/map/nodes"
    const MAP_EDGES: String = "/map/edges"
```

### Colores de Carreteras (Visualización)

```gdscript
class RoadColors:
    const MOTORWAY: Color = Color(0.0, 0.2, 0.4)       # Azul oscuro #003366
    const MOTORWAY_LINK: Color = Color(0.0, 0.3, 0.5)  # Ligeramente más claro
    const TRUNK: Color = Color(0.0, 0.4, 0.6)          # Azul medio
    const TRUNK_LINK: Color = Color(0.0, 0.5, 0.7)
    const PRIMARY: Color = Color(1.0, 0.8, 0.0)        # Amarillo #FFCC00
    const PRIMARY_LINK: Color = Color(1.0, 0.85, 0.2)
    const SECONDARY: Color = Color(1.0, 0.53, 0.0)     # Naranja #FF8800
    const SECONDARY_LINK: Color = Color(1.0, 0.6, 0.2)
    const TERTIARY: Color = Color(1.0, 0.67, 0.27)     # Naranja claro #FFAA44
    const TERTIARY_LINK: Color = Color(1.0, 0.75, 0.4)
    const RESIDENTIAL: Color = Color(1.0, 1.0, 1.0)    # Blanco #FFFFFF
    const SERVICE: Color = Color(0.8, 0.8, 0.8)        # Gris claro #CCCCCC
    const UNCLASSIFIED: Color = Color(0.7, 0.7, 0.7)   # Gris
    const LIVING_STREET: Color = Color(0.9, 0.9, 0.9)  # Gris muy claro
    const UNKNOWN: Color = Color(0.5, 0.5, 0.5)        # Gris por defecto
```

### Constantes de Coordenadas

```gdscript
class Coordinates:
    const METERS_PER_DEGREE_LAT: float = 111320.0
    const EARTH_RADIUS_METERS: float = 6371000.0
    const DEFAULT_CENTER_LON: float = -4.8300  # Talavera de la Reina
    const DEFAULT_CENTER_LAT: float = 39.9600
    const GPS_PRECISION: float = 0.000001      # ~0.1 metros
    const METERS_PRECISION: float = 0.01       # 1 centímetro
```

### Colores de Nodos (Visualización)

```gdscript
class NodeColors:
    const INTERSECTION: Color = Color(0.5, 0.5, 0.5)    # Gris
    const TRAFFIC_LIGHT: Color = Color(1.0, 0.0, 0.0)   # Rojo
    const ROUNDABOUT: Color = Color(0.0, 0.5, 1.0)      # Azul
    const DEAD_END: Color = Color(0.25, 0.25, 0.25)     # Gris oscuro
    const ENTRY_POINT: Color = Color(0.0, 1.0, 0.0)     # Verde
    const EXIT_POINT: Color = Color(1.0, 0.65, 0.0)     # Naranja
    const UNKNOWN: Color = Color(0.5, 0.5, 0.5)         # Gris
```

### Configuración de Renderizado de Nodos

```gdscript
class NodeRendering:
    const DEFAULT_RADIUS: float = 3.0              # Radio de esfera en metros
    const MAX_RADIUS: float = 50.0                 # Radio máximo en metros
    const RADIUS_SCALE_FACTOR: float = 500.0       # Divisor para auto-escalado
    const SPHERE_RADIAL_SEGMENTS: int = 16         # Low-poly para rendimiento
    const SPHERE_RINGS: int = 8                    # Low-poly para rendimiento
    const LOD_DISTANCE_HIDE: float = 5000.0        # Distancia para ocultar nodos
    const LOD_DISTANCE_LOW: float = 2000.0         # Distancia para detalle bajo
    const LOD_LOW_SCALE: float = 0.5               # Factor de escala en LOD bajo
    const SELECTION_HIGHLIGHT_SCALE: float = 1.3   # Escala al seleccionar
    const HOVER_HIGHLIGHT_SCALE: float = 1.15      # Escala al pasar sobre
    const RAYCAST_MAX_DISTANCE: float = 10000.0    # Distancia máxima de raycast
    const MATERIAL_ROUGHNESS: float = 0.7          # Rugosidad del material
    const MATERIAL_METALLIC: float = 0.1           # Metalicidad del material
    const METALLIC_SPECULAR: float = 0.3           # Valor especular del material
    const EMISSION_ENERGY: float = 0.1             # Energía de emisión
```

### Configuración de Renderizado de Carreteras

```gdscript
class EdgeRendering:
    # Anchos de carretera por número de carriles
    const LANE_WIDTH: float = 3.0         # Ancho por carril
    const WIDTH_1_LANE: float = 3.0       # 1 carril: 3m
    const WIDTH_2_LANES: float = 6.0      # 2 carriles: 6m
    const WIDTH_3_LANES: float = 9.0      # 3 carriles: 9m
    const WIDTH_4_LANES: float = 12.0     # 4+ carriles: 12m

    # Geometría de carreteras
    const ROAD_HEIGHT: float = 0.2        # Grosor de carretera
    const ROAD_ELEVATION: float = 0.1     # Elevación sobre el suelo

    # Distancias LOD
    const LOD_DISTANCE_HIDE: float = 8000.0       # Ocultar carreteras
    const LOD_DISTANCE_SIMPLIFY: float = 3000.0   # Simplificar geometría

    # Simplificación de geometría
    const MIN_SEGMENT_LENGTH: float = 5.0         # Longitud mínima de segmento
    const LOD_MIN_SEGMENT_LENGTH: float = 20.0    # Longitud mínima para LOD

    # Flechas de dirección (calles de un sentido)
    const ARROW_SPACING: float = 50.0     # Metros entre flechas
    const ARROW_SIZE: float = 4.0         # Tamaño de flecha
    const ARROW_HEIGHT: float = 0.3       # Altura sobre carretera
    const ARROW_COLOR: Color = Color(1.0, 1.0, 1.0, 0.9)  # Color de flechas

    # Selección/resaltado
    const SELECTION_WIDTH_MULTIPLIER: float = 1.2  # Multiplicador al seleccionar
    const HOVER_WIDTH_MULTIPLIER: float = 1.1      # Multiplicador al pasar sobre
```

### Configuración de Cámara

```gdscript
class Camera:
    # Velocidades de movimiento
    const PAN_SPEED: float = 1.0               # Multiplicador de velocidad de pan
    const PAN_SCALE_FACTOR: float = 0.001      # Factor de escala para pan
    const ROTATION_SPEED: float = 0.003        # Sensibilidad de rotación
    const KEYBOARD_MOVE_SPEED: float = 100.0   # Velocidad WASD (m/s)
    const KEYBOARD_SPEED_BOOST: float = 3.0    # Multiplicador con Shift

    # Configuración de zoom
    const ZOOM_SPEED: float = 50.0             # Paso de zoom por scroll
    const ZOOM_MIN_DISTANCE: float = 10.0      # Distancia mínima al punto focal
    const ZOOM_MAX_DISTANCE: float = 10000.0   # Distancia máxima al punto focal

    # Suavizado (interpolación)
    const SMOOTH_ENABLED: bool = true          # Activar movimiento suave
    const SMOOTH_POSITION_WEIGHT: float = 10.0 # Velocidad de interpolación posición
    const SMOOTH_ROTATION_WEIGHT: float = 10.0 # Velocidad de interpolación rotación

    # Vista por defecto
    const DEFAULT_HEIGHT: float = 500.0        # Altura por defecto (metros)
    const DEFAULT_DISTANCE: float = 500.0      # Distancia por defecto al centro
    const DEFAULT_PITCH: float = -45.0         # Ángulo pitch por defecto (grados)
    const DEFAULT_YAW: float = 0.0             # Ángulo yaw por defecto (grados)

    # Límites
    const MIN_HEIGHT: float = 5.0              # Altura Y mínima de cámara
    const MAX_PITCH: float = -5.0              # Pitch máximo (casi horizontal)
    const MIN_PITCH: float = -89.0             # Pitch mínimo (casi vertical)

    # Configuración de órbita
    const ORBIT_INVERT_Y: bool = false         # Invertir eje Y en órbita

    # Configuración de enfoque en límites
    const BOUNDS_VIEW_MULTIPLIER: float = 0.75 # Multiplicador para ver límites
    const BOUNDS_DEFAULT_SIZE: float = 1000.0  # Tamaño por defecto cuando inválido
```

### Configuración de UI

```gdscript
class UI:
    # Panel de debug
    const PANEL_MARGIN: int = 10               # Margen desde borde de pantalla
    const PANEL_MIN_WIDTH: int = 250           # Ancho mínimo del panel
    const PANEL_OPACITY: float = 0.85          # Opacidad del fondo (0-1)
    const PANEL_CORNER_RADIUS: int = 8         # Radio de esquinas redondeadas
    const PANEL_CONTENT_MARGIN: int = 12       # Margen de contenido interior
    const PANEL_VERTICAL_MARGIN: int = 8       # Margen vertical interior
    const PANEL_ITEM_SPACING: int = 6          # Espaciado entre elementos
    const BUTTON_HEIGHT: int = 28              # Altura mínima de botón
    const BUTTON_CORNER_RADIUS: int = 4        # Radio de esquinas de botón

    # Colores
    const BACKGROUND_COLOR: Color = Color(0.1, 0.1, 0.12, 0.85)  # Fondo oscuro semi-transparente
    const TEXT_COLOR: Color = Color(0.9, 0.9, 0.9)               # Texto gris claro
    const TEXT_SECONDARY_COLOR: Color = Color(0.7, 0.7, 0.7)     # Texto secundario
    const TEXT_MUTED_COLOR: Color = Color(0.8, 0.8, 0.8)         # Texto atenuado
    const ACCENT_COLOR: Color = Color(0.3, 0.6, 1.0)             # Acento azul
    const SUCCESS_COLOR: Color = Color(0.3, 0.8, 0.4)            # Verde
    const WARNING_COLOR: Color = Color(1.0, 0.7, 0.2)            # Amarillo/Naranja
    const ERROR_COLOR: Color = Color(1.0, 0.3, 0.3)              # Rojo
    const SEPARATOR_COLOR: Color = Color(0.3, 0.3, 0.35)         # Color de separadores
    const BUTTON_NORMAL_COLOR: Color = Color(0.2, 0.2, 0.25)     # Botón normal
    const BUTTON_HOVER_COLOR: Color = Color(0.25, 0.25, 0.3)     # Botón hover
    const BUTTON_PRESSED_COLOR: Color = Color(0.15, 0.15, 0.2)   # Botón presionado

    # Contador de FPS
    const FPS_UPDATE_INTERVAL: float = 0.5     # Segundos entre actualizaciones
    const FPS_SAMPLE_COUNT: int = 30           # Frames a promediar
```

---

## Componentes

### Capa de Comunicación HTTP

#### HTTPResult

Clase que encapsula la información de respuesta HTTP.

```gdscript
# Propiedades
var success: bool           # Si la petición fue exitosa
var status_code: int        # Código HTTP (200, 404, etc.)
var data: Variant           # Cuerpo JSON parseado
var body: String            # Cuerpo raw de la respuesta
var error_message: String   # Descripción del error si falló
var error_type: ErrorType   # Categorización del error
var headers: Dictionary     # Headers de respuesta

# Tipos de error
enum ErrorType {
    NONE,
    CONNECTION_REFUSED,
    TIMEOUT,
    DNS_FAILURE,
    SSL_ERROR,
    HTTP_ERROR,
    PARSE_ERROR,
    UNKNOWN
}

# Métodos factory
static func ok(status, data, body, headers) -> HTTPResult
static func error(message, type, status) -> HTTPResult
static func from_http_error(http_error) -> HTTPResult
```

#### HTTPClient2

Cliente HTTP de bajo nivel con patrón async/await.

```gdscript
class_name HTTPClient2
extends Node

# Señales
signal request_completed(result: HTTPResult)

# Métodos
func get_request(endpoint: String, headers: PackedStringArray = []) -> HTTPResult
func post_request(endpoint: String, data: Dictionary = {}, headers: PackedStringArray = []) -> HTTPResult
func put_request(endpoint: String, data: Dictionary = {}, headers: PackedStringArray = []) -> HTTPResult
func delete_request(endpoint: String, headers: PackedStringArray = []) -> HTTPResult
func patch_request(endpoint: String, data: Dictionary = {}, headers: PackedStringArray = []) -> HTTPResult

func is_busy() -> bool
func cancel() -> void
```

#### HTTPManager (Autoload)

Singleton global para operaciones HTTP. Registrado como autoload.

```gdscript
# Señales
signal connection_status_changed(connected: bool)
signal health_check_completed(result: HTTPResult)

# Health checks
func health_check() -> HTTPResult
func health_check_detailed() -> HTTPResult

# Peticiones genéricas
func get_request(endpoint: String) -> HTTPResult
func post_request(endpoint: String, data: Dictionary = {}) -> HTTPResult
func put_request(endpoint: String, data: Dictionary = {}) -> HTTPResult
func delete_request(endpoint: String) -> HTTPResult
func patch_request(endpoint: String, data: Dictionary = {}) -> HTTPResult

# Operaciones de mapa
func get_import_status() -> HTTPResult
func import_osm(filepath: String, clear_existing: bool = false) -> HTTPResult

# Estado
var backend_connected: bool { get }
func is_busy() -> bool
func cancel_request() -> void
```

**Uso:**

```gdscript
# Health check
var result := await HTTPManager.health_check()
if result.success:
    print("Backend conectado!")
else:
    print("Error: ", result.error_message)

# Petición GET
var nodes := await HTTPManager.get_request("/map/nodes?limit=100")
if nodes.success:
    for node in nodes.data.items:
        print(node)
```

---

### Modelos de Datos

#### NodeData

Representa un nodo de la red vial (intersección, semáforo, etc.).

```gdscript
class_name NodeData
extends RefCounted

# Tipos de nodo
enum NodeType {
    INTERSECTION,     # Intersección
    TRAFFIC_LIGHT,    # Semáforo
    ROUNDABOUT,       # Rotonda
    DEAD_END,         # Calle sin salida
    ENTRY_POINT,      # Punto de entrada
    EXIT_POINT,       # Punto de salida
    UNKNOWN           # Desconocido
}

# Propiedades
var id: int
var name: String
var node_type: NodeType
var longitude: float
var latitude: float
var is_active: bool
var metadata: Dictionary

# Métodos
static func from_dict(data: Dictionary) -> NodeData
func to_dict() -> Dictionary
func get_position_vector2() -> Vector2  # (lon, lat)
func get_type_string() -> String
func has_valid_position() -> bool
```

#### EdgeData

Representa un segmento de carretera que conecta dos nodos.

```gdscript
class_name EdgeData
extends RefCounted

# Tipos de carretera
enum RoadType {
    MOTORWAY, MOTORWAY_LINK,      # Autopista
    TRUNK, TRUNK_LINK,            # Autovía
    PRIMARY, PRIMARY_LINK,        # Primaria
    SECONDARY, SECONDARY_LINK,    # Secundaria
    TERTIARY, TERTIARY_LINK,      # Terciaria
    RESIDENTIAL,                  # Residencial
    SERVICE,                      # Servicio
    UNCLASSIFIED,                 # Sin clasificar
    LIVING_STREET,                # Zona residencial
    UNKNOWN                       # Desconocido
}

# Propiedades
var id: int
var name: String
var start_node_id: int
var end_node_id: int
var road_type: RoadType
var geometry: Array          # [[lon, lat], ...]
var length: float            # metros
var max_speed: int           # km/h
var lanes: int
var one_way: bool
var is_active: bool
var metadata: Dictionary

# Métodos
static func from_dict(data: Dictionary) -> EdgeData
func to_dict() -> Dictionary
func get_geometry_vectors() -> Array[Vector2]
func get_start_position() -> Vector2
func get_end_position() -> Vector2
func get_center_position() -> Vector2
func get_road_color() -> Color
func has_valid_geometry() -> bool
```

#### RoadNetwork

Contenedor para la red vial completa con indexación.

```gdscript
class_name RoadNetwork
extends RefCounted

# Propiedades
var nodes: Dictionary        # int -> NodeData
var edges: Dictionary        # int -> EdgeData
var edges_by_start_node: Dictionary  # int -> Array[EdgeData]
var edges_by_end_node: Dictionary    # int -> Array[EdgeData]
var bounds_min: Vector2      # (min_lon, min_lat)
var bounds_max: Vector2      # (max_lon, max_lat)

# Operaciones CRUD
func add_node(node: NodeData) -> void
func add_nodes(node_list: Array) -> void
func add_edge(edge: EdgeData) -> void
func add_edges(edge_list: Array) -> void
func clear() -> void

# Consultas
func get_node(id: int) -> NodeData
func get_edge(id: int) -> EdgeData
func get_outgoing_edges(node_id: int) -> Array
func get_incoming_edges(node_id: int) -> Array
func get_connected_edges(node_id: int) -> Array

func get_node_ids() -> Array
func get_edge_ids() -> Array
func get_node_count() -> int
func get_edge_count() -> int

func get_nodes_by_type(node_type: NodeData.NodeType) -> Array[NodeData]
func get_edges_by_type(road_type: EdgeData.RoadType) -> Array[EdgeData]
func find_nodes_in_bounds(min_pos: Vector2, max_pos: Vector2) -> Array[NodeData]

# Estadísticas
func get_center() -> Vector2
func get_extent() -> Vector2
func get_stats() -> Dictionary
func validate() -> Dictionary  # Retorna {valid, issues, orphan_nodes}

func is_empty() -> bool
func has_data() -> bool
```

---

### Gestión de Red Vial

#### NetworkManager (Autoload)

Gestiona la carga y caché de datos de la red vial. Registrado como autoload.

```gdscript
# Señales
signal loading_started()
signal loading_progress(progress: float, message: String)
signal loading_completed(network: RoadNetwork)
signal loading_failed(error: String)
signal network_cleared()

# Estados de carga
enum LoadingState { IDLE, LOADING_NODES, LOADING_EDGES, COMPLETED, FAILED }

# Propiedades
var state: LoadingState
var network: RoadNetwork
var is_loaded: bool
var last_error: String

# Métodos
func load_network(clear_existing: bool = true) -> bool
func clear_network() -> void
func is_loading() -> bool
func get_loading_progress() -> float  # 0.0 a 1.0

# Accesos de conveniencia
func get_network_node(id: int) -> NodeData
func get_network_edge(id: int) -> EdgeData
func get_network_stats() -> Dictionary

# Configuración
func set_page_size(size: int) -> void
func set_max_retries(retries: int) -> void
```

**Uso:**

```gdscript
# Conectar a señales
NetworkManager.loading_started.connect(_on_loading_started)
NetworkManager.loading_progress.connect(_on_loading_progress)
NetworkManager.loading_completed.connect(_on_loading_completed)
NetworkManager.loading_failed.connect(_on_loading_failed)

# Cargar red
await NetworkManager.load_network()

# Acceder a datos
if NetworkManager.is_loaded:
    var stats := NetworkManager.get_network_stats()
    print("Nodos: ", stats.node_count)
    print("Aristas: ", stats.edge_count)

    # Acceder a nodo/arista específico
    var node := NetworkManager.get_network_node(123)
    var edge := NetworkManager.get_network_edge(456)
```

---

### Renderizado 3D

#### NodeRenderer

Renderiza nodos de la red vial usando MultiMeshInstance3D para eficiencia.

**Características:**
- Renderizado de 5000+ nodos en una sola llamada de dibujo
- Colores por instancia según tipo de nodo
- Sistema de LOD (Level of Detail) basado en distancia
- Selección de nodos mediante raycast
- Detección de hover
- Mallas de esfera low-poly para rendimiento

```gdscript
class_name NodeRenderer
extends Node3D

# Señales
signal node_selected(node_data: NodeData)
signal node_hovered(node_data: NodeData)
signal node_hover_ended()
signal render_complete(node_count: int)

# Configuración
func set_converter(converter: CoordinateConverter) -> void
func set_camera(camera: Camera3D) -> void
func set_node_radius(radius: float) -> void

# Renderizado
func render_network(network: RoadNetwork) -> void
func render_nodes(nodes: Array[NodeData]) -> void
func clear() -> void

# Interacción
func get_node_at_position(screen_pos: Vector2, camera: Camera3D) -> NodeData
func select_node(node: NodeData) -> void
func deselect() -> void
func set_hovered_node(node: NodeData) -> void

# LOD
func update_lod(camera: Camera3D) -> void

# Consultas
func has_nodes() -> bool
func get_node_count() -> int
func get_node_by_id(node_id: int) -> NodeData
func get_node_position(node: NodeData) -> Vector3
func get_rendered_bounds() -> Dictionary  # {min, max, center, size}
func get_stats() -> Dictionary
func get_node_debug_info(node: NodeData) -> String

# Visibilidad
func set_nodes_visible(visible: bool) -> void
func are_nodes_visible() -> bool
```

**Uso:**

```gdscript
# Configurar
var converter := CoordinateConverter.new()
converter.set_bounds_from_network(NetworkManager.network)

@onready var node_renderer: NodeRenderer = $NodeRenderer
node_renderer.set_converter(converter)
node_renderer.set_camera($Camera3D)

# Conectar señales
node_renderer.render_complete.connect(_on_render_complete)
node_renderer.node_selected.connect(_on_node_selected)

# Renderizar
node_renderer.render_network(NetworkManager.network)

# Actualizar LOD en _process
func _process(_delta: float) -> void:
    if lod_enabled and node_renderer.has_nodes():
        node_renderer.update_lod($Camera3D)

# Selección por click
func _on_click(screen_pos: Vector2) -> void:
    var node := node_renderer.get_node_at_position(screen_pos, $Camera3D)
    if node:
        node_renderer.select_node(node)
    else:
        node_renderer.deselect()
```

#### EdgeRenderer

Renderiza las carreteras de la red vial usando ImmediateMesh para eficiencia.

**Características:**
- Renderizado eficiente de 2000+ aristas con ImmediateMesh
- Colores por tipo de carretera (motorway, primary, secondary, etc.)
- Ancho de carretera basado en número de carriles
- Flechas direccionales para calles de un solo sentido
- Sistema LOD para simplificar geometría distante
- Filtro de visibilidad por tipo de carretera

```gdscript
class_name EdgeRenderer
extends Node3D

# Señales
signal edge_selected(edge_data: EdgeData)
signal edge_hovered(edge_data: EdgeData)
signal edge_hover_ended()
signal render_complete(edge_count: int)

# Configuración
func set_converter(converter: CoordinateConverter) -> void
func set_camera(camera: Camera3D) -> void

# Renderizado
func render_network(network: RoadNetwork) -> void
func render_edges(edges: Array[EdgeData]) -> void
func clear() -> void
func refresh() -> void

# Visibilidad por tipo
func set_road_type_visible(road_type: EdgeData.RoadType, visible: bool) -> void
func is_road_type_visible(road_type: EdgeData.RoadType) -> bool
func toggle_road_type(road_type: EdgeData.RoadType) -> void

# LOD
func update_lod(camera: Camera3D) -> void
func set_lod_enabled(enabled: bool) -> void

# Consultas
func has_edges() -> bool
func get_edge_count() -> int
func get_edge_by_id(edge_id: int) -> EdgeData
func get_rendered_bounds() -> Dictionary  # {min, max, center, size}
func get_stats() -> Dictionary
func get_edge_debug_info(edge: EdgeData) -> String

# Visibilidad general
func set_roads_visible(visible: bool) -> void
func are_roads_visible() -> bool
```

**Esquema de Colores:**
| Tipo de Carretera | Color | Descripción |
|-------------------|-------|-------------|
| Motorway | Azul oscuro (#003366) | Autopistas |
| Primary | Amarillo (#FFCC00) | Carreteras principales |
| Secondary | Naranja (#FF8800) | Carreteras secundarias |
| Tertiary | Naranja claro (#FFAA44) | Carreteras terciarias |
| Residential | Blanco (#FFFFFF) | Calles residenciales |
| Service | Gris claro (#CCCCCC) | Vías de servicio |

**Ancho de Carretera por Carriles:**
| Carriles | Ancho (metros) |
|----------|----------------|
| 1 | 3.0 m |
| 2 | 6.0 m |
| 3 | 9.0 m |
| 4+ | 12.0 m |

**Uso:**

```gdscript
# Configurar
var converter := CoordinateConverter.new()
converter.set_bounds_from_network(NetworkManager.network)

@onready var edge_renderer: EdgeRenderer = $EdgeRenderer
edge_renderer.set_converter(converter)
edge_renderer.set_camera($Camera3D)

# Renderizar
edge_renderer.render_network(NetworkManager.network)

# Filtrar por tipo
edge_renderer.set_road_type_visible(EdgeData.RoadType.SERVICE, false)
edge_renderer.refresh()

# Actualizar LOD
func _process(_delta: float) -> void:
    if lod_enabled:
        edge_renderer.update_lod($Camera3D)
```

---

### Controlador de Cámara

#### CameraController

Controlador de cámara 3D con órbita, zoom, pan y controles de teclado.

**Características:**
- Rotación orbital alrededor de punto focal (arrastrar con botón derecho)
- Zoom con rueda del ratón
- Pan con botón central o Shift + arrastrar derecho
- Movimiento con teclado (WASD, Q/E)
- Enfoque automático en red vial
- Movimiento suave con interpolación
- Límites de zoom configurables
- Reset a vista por defecto (tecla Home)

```gdscript
class_name CameraController
extends Node3D

# Señales
signal camera_moved(position: Vector3, rotation: Vector3)
signal focal_point_changed(focal_point: Vector3)
signal camera_reset()

# Propiedades exportadas
@export var camera: Camera3D
@export var enabled: bool = true
@export var smooth_enabled: bool = true
@export var keyboard_enabled: bool = true

# Configuración del punto focal
func set_focal_point(point: Vector3) -> void
func get_focal_point() -> Vector3

# Configuración de distancia
func set_distance(distance: float) -> void
func get_distance() -> float

# Configuración de ángulos de órbita
func set_orbit_angles(pitch_deg: float, yaw_deg: float) -> void
func get_orbit_angles() -> Vector2  # (pitch, yaw) en grados

# Enfoque
func focus_on(position: Vector3, distance: float = -1.0) -> void
func focus_on_network(network: RoadNetwork, converter: CoordinateConverter = null) -> void
func focus_on_bounds(bounds: Dictionary) -> void

# Vista por defecto
func set_default_view(focal_point: Vector3, distance: float, pitch_deg: float, yaw_deg: float) -> void
func reset_camera() -> void
func apply_instantly() -> void

# Debug
func get_debug_info() -> String
```

**Controles:**

| Control | Acción |
|---------|--------|
| Arrastrar botón derecho | Órbita alrededor del punto focal |
| Rueda del ratón arriba | Zoom in |
| Rueda del ratón abajo | Zoom out |
| Arrastrar botón central | Pan (mover punto focal) |
| Shift + arrastrar derecho | Pan alternativo |
| W/S | Mover adelante/atrás |
| A/D | Mover izquierda/derecha |
| Q/E | Mover abajo/arriba |
| Shift (con WASD) | Movimiento rápido |
| Home | Reset a vista por defecto |

**Uso:**

```gdscript
# Usar la escena camera_rig.tscn
@onready var camera_controller: CameraController = $CameraRig

# Configurar vista por defecto
camera_controller.set_default_view(Vector3.ZERO, 500.0, -45.0, 0.0)

# Enfocar en la red vial cargada
camera_controller.focus_on_bounds(edge_renderer.get_rendered_bounds())

# Enfocar en una posición específica
camera_controller.focus_on(Vector3(100, 0, 200), 300.0)

# Reset a vista por defecto
camera_controller.reset_camera()

# Desactivar temporalmente
camera_controller.enabled = false
```

---

### Panel de Debug

#### DebugPanel

Panel de UI superpuesto para mostrar estadísticas de red y controles de visualización.

**Características:**
- Panel semi-transparente en esquina superior izquierda
- Estadísticas en tiempo real (nodos, aristas, longitud de carreteras)
- Información de cámara (posición, distancia)
- Contador de FPS con código de colores
- Toggles de visibilidad (nodos, carreteras, flechas)
- Botones de acción (recargar red, reset cámara)
- Diseño minimalista y responsive

```gdscript
class_name DebugPanel
extends CanvasLayer

# Señales
signal nodes_visibility_changed(visible: bool)
signal edges_visibility_changed(visible: bool)
signal arrows_visibility_changed(visible: bool)
signal reload_requested()
signal reset_camera_requested()

# Referencias externas (asignar desde escena padre)
var camera_controller: CameraController
var node_renderer: NodeRenderer
var edge_renderer: EdgeRenderer

# Establecer estadísticas de red
func set_network_stats(nodes: int, edges: int, length_km: float) -> void

# Actualizar stats desde renderers
func update_from_renderers() -> void

# Control de toggles
func set_nodes_visible(visible: bool) -> void
func set_edges_visible(visible: bool) -> void
func set_arrows_visible(visible: bool) -> void
func are_nodes_visible() -> bool
func are_edges_visible() -> bool
func are_arrows_visible() -> bool

# Visibilidad del panel
func set_panel_visible(visible: bool) -> void
func is_panel_visible() -> bool
func toggle_panel() -> void
```

**Uso:**

```gdscript
# Instanciar debug_panel.tscn
var debug_panel := preload("res://scenes/ui/debug_panel.tscn").instantiate()
add_child(debug_panel)

# Asignar referencias
debug_panel.camera_controller = $CameraRig
debug_panel.node_renderer = $NodeRenderer
debug_panel.edge_renderer = $EdgeRenderer

# Conectar señales
debug_panel.reload_requested.connect(_on_reload_network)
debug_panel.reset_camera_requested.connect(_on_reset_camera)

# Actualizar estadísticas
debug_panel.update_from_renderers()

# O manualmente
debug_panel.set_network_stats(5000, 2500, 150.5)

# Ocultar/mostrar panel (por ejemplo con tecla Tab)
func _input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_focus_next"):
        debug_panel.toggle_panel()
```

---

### Conversión de Coordenadas

#### CoordinateConverter

Convierte coordenadas GPS (EPSG:4326) a espacio 3D de Godot.

**Mapeo de Sistema de Coordenadas:**

| GPS                | Godot               |
|--------------------|---------------------|
| Longitud (Este+)   | X (positivo = Este) |
| Latitud (Norte+)   | Z (positivo = Sur)  |
| Elevación          | Y (arriba)          |
| Punto central      | Origen (0, 0, 0)    |

```gdscript
class_name CoordinateConverter
extends RefCounted

# Constantes
const METERS_PER_DEGREE_LAT: float = 111320.0
const EARTH_RADIUS_METERS: float = 6371000.0

# Propiedades
var center_longitude: float
var center_latitude: float
var bounds_min: Vector2  # (min_lon, min_lat)
var bounds_max: Vector2  # (max_lon, max_lat)

# Inicialización
func set_center(longitude: float, latitude: float) -> void
func set_bounds(min_lon: float, min_lat: float, max_lon: float, max_lat: float) -> void
func set_bounds_from_network(network: RoadNetwork) -> void

# Conversión directa (GPS -> Godot)
func gps_to_godot(longitude: float, latitude: float, elevation: float = 0.0) -> Vector3
func gps_to_godot_v2(gps_coords: Vector2, elevation: float = 0.0) -> Vector3

# Conversión inversa (Godot -> GPS)
func godot_to_gps(position: Vector3) -> Vector2  # (lon, lat)
func godot_to_gps_with_elevation(position: Vector3) -> Vector3  # (lon, lat, elevation)

# Conversión por lotes
func batch_gps_to_godot(gps_coords: Array, elevation: float = 0.0) -> Array[Vector3]
func batch_godot_to_gps(positions: Array[Vector3]) -> Array[Vector2]

# Cálculo de distancia (Haversine)
func gps_distance_meters(lon1: float, lat1: float, lon2: float, lat2: float) -> float
func gps_distance_meters_v2(point1: Vector2, point2: Vector2) -> float

# Utilidades
func get_bounds_size_meters() -> Vector2  # (ancho, alto) en metros
func get_godot_bounds() -> Dictionary  # {min, max, size}
func is_initialized() -> bool
func get_center_gps() -> Vector2
func get_meters_per_degree_lon() -> float
```

**Uso:**

```gdscript
# Inicializar con punto central
var converter := CoordinateConverter.new()
converter.set_center(-4.8300, 39.9600)  # Talavera de la Reina

# O inicializar desde los límites de la red
converter.set_bounds_from_network(NetworkManager.network)

# Convertir GPS a Godot
var godot_pos := converter.gps_to_godot(-4.8293, 39.9579)  # Plaza del Pan
print(godot_pos)  # Vector3(x, 0, z) en metros desde el centro

# Convertir Godot a GPS
var gps_coords := converter.godot_to_gps(godot_pos)
print(gps_coords)  # Vector2(-4.8293, 39.9579)

# Conversión por lotes
var gps_points := [
    Vector2(-4.8293, 39.9579),
    Vector2(-4.8315, 39.9589),
]
var godot_positions := converter.batch_gps_to_godot(gps_points)

# Calcular distancia
var distance := converter.gps_distance_meters(-4.8293, 39.9579, -4.8315, 39.9589)
print("Distancia: ", distance, " metros")
```

---

### Utilidades

#### JsonUtils

Utilidades de parseo JSON seguro.

```gdscript
class_name JsonUtils
extends RefCounted

# Clase de resultado de parseo
class ParseResult:
    var success: bool
    var data: Variant
    var error: String
    var error_line: int

# Parseo
static func parse(json_string: String) -> ParseResult
static func parse_or_default(json_string: String, default: Variant = null) -> Variant
static func stringify(data: Variant, pretty: bool = false) -> String

# Extracción segura de valores
static func get_value(dict: Dictionary, key: String, default: Variant = null) -> Variant
static func get_nested(dict: Dictionary, path: String, default: Variant = null) -> Variant
static func get_string(dict: Dictionary, key: String, default: String = "") -> String
static func get_int(dict: Dictionary, key: String, default: int = 0) -> int
static func get_float(dict: Dictionary, key: String, default: float = 0.0) -> float
static func get_bool(dict: Dictionary, key: String, default: bool = false) -> bool
static func get_array(dict: Dictionary, key: String, default: Array = []) -> Array
static func get_dict(dict: Dictionary, key: String, default: Dictionary = {}) -> Dictionary

# Operaciones de diccionario
static func merge(base: Dictionary, overlay: Dictionary) -> Dictionary
static func deep_merge(base: Dictionary, overlay: Dictionary) -> Dictionary
static func to_camel_case(dict: Dictionary) -> Dictionary
static func to_snake_case(dict: Dictionary) -> Dictionary
```

**Uso:**

```gdscript
# Extracción segura de valores
var name := JsonUtils.get_string(response, "name", "Desconocido")
var count := JsonUtils.get_int(response, "count", 0)
var items := JsonUtils.get_array(response, "items", [])

# Acceso anidado
var city := JsonUtils.get_nested(response, "address.city", "N/A")

# Parsear JSON de forma segura
var result := JsonUtils.parse(json_string)
if result.success:
    print(result.data)
else:
    print("Error: ", result.error)
```

#### UILogger

Utilidad de logging basado en BBCode para RichTextLabel.

```gdscript
class_name UILogger
extends RefCounted

# Inicializar
func _init(log_output: RichTextLabel) -> void

# Métodos de logging
func info(message: String) -> void      # Color por defecto
func success(message: String) -> void   # Verde
func error(message: String) -> void     # Rojo
func warning(message: String) -> void   # Amarillo
func debug(message: String) -> void     # Gris (solo en DEBUG_MODE)
func colored(message: String, color: String) -> void

# Utilidades
func clear() -> void
func separator(char: String = "-", length: int = 40) -> void
```

**Uso:**

```gdscript
@onready var log_text: RichTextLabel = $LogText
var _logger: UILogger

func _ready() -> void:
    _logger = UILogger.new(log_text)
    _logger.info("Aplicación iniciada")
    _logger.success("Conectado al backend")
    _logger.warning("Red lenta")
    _logger.error("Conexión fallida")
```

---

## Escenas de Prueba

### Test Connection (`test_connection.tscn`)

Pruebas de conectividad HTTP con el backend:

- Health check básico (`/health`)
- Health check detallado (`/health/detailed`)
- Manejo de errores 404
- Manejo de conexión rechazada
- Ejecutar todas las pruebas secuencialmente

### Test Load Network (`test_load_network.tscn`)

Pruebas de carga de datos de red vial:

- Cargar red completa con paginación
- Seguimiento de progreso
- Mostrar estadísticas de red
- Validar integridad de la red
- Limpiar datos de red

### Test Coordinates (`test_coordinates.tscn`)

Pruebas de conversión de coordenadas:

- Inicialización del convertidor
- Coordenadas conocidas (monumentos de Talavera)
- Precisión de ida y vuelta (GPS → Godot → GPS)
- Comparación de cálculo de distancia
- Conversión por lotes
- Integración con límites de red

### Test Camera (`test_camera.tscn`)

Pruebas del controlador de cámara 3D:

- Rotación orbital alrededor de punto focal
- Zoom in/out con rueda del ratón
- Pan con botón central o Shift + botón derecho
- Movimiento con teclado (WASD, Q/E)
- Reset a vista por defecto (tecla Home)
- Toggle de movimiento suave (interpolación)
- Toggle de controles de teclado
- Enfoque en puntos de referencia
- Visualización de información de cámara en tiempo real
- Objetos de referencia para orientación visual

### Test Network Renderer (`test_node_renderer.tscn`)

Pruebas de renderizado 3D completo de la red vial (nodos y carreteras):

- Carga y visualización completa de red vial en 3D
- **Nodos**: Esferas con colores por tipo (intersección, semáforo, etc.)
- **Carreteras**: Líneas 3D con colores por tipo y ancho por carriles
- **Flechas**: Indicadores de dirección en calles de un sentido
- Toggles de visibilidad para nodos y carreteras
- Controles de cámara:
  - **WASD**: Movimiento de cámara
  - **Q/E**: Arriba/Abajo
  - **Click derecho + arrastrar**: Rotar cámara
  - **Scroll**: Zoom
  - **Click izquierdo**: Seleccionar nodo
- Sistema LOD para optimización de rendimiento
- Estadísticas: nodos, aristas, longitud total, tipos
- Prueba de rendimiento: 5000+ nodos y 2000+ aristas a 60 FPS

---

## Ejemplos de Uso

### Flujo de Trabajo Completo

```gdscript
extends Node

func _ready() -> void:
    # 1. Verificar conexión al backend
    var health := await HTTPManager.health_check()
    if not health.success:
        push_error("Backend no disponible")
        return

    # 2. Cargar red vial
    NetworkManager.loading_completed.connect(_on_network_loaded)
    await NetworkManager.load_network()

func _on_network_loaded(network: RoadNetwork) -> void:
    # 3. Configurar convertidor de coordenadas
    var converter := CoordinateConverter.new()
    converter.set_bounds_from_network(network)

    # 4. Convertir todos los nodos a posiciones de Godot
    for node_id in network.get_node_ids():
        var node := network.get_node(node_id)
        var godot_pos := converter.gps_to_godot(node.longitude, node.latitude)
        _spawn_node_visual(node, godot_pos)

    # 5. Convertir todas las aristas
    for edge_id in network.get_edge_ids():
        var edge := network.get_edge(edge_id)
        var points := converter.batch_gps_to_godot(edge.geometry)
        _spawn_road_visual(edge, points)

func _spawn_node_visual(node: NodeData, position: Vector3) -> void:
    # Crear visualización 3D para el nodo
    pass

func _spawn_road_visual(edge: EdgeData, points: Array[Vector3]) -> void:
    # Crear visualización 3D para el segmento de carretera
    pass
```

---

## API Reference

### Singletons Autoload

| Nombre           | Acceso Global     | Descripción                      |
|------------------|-------------------|----------------------------------|
| `HTTPManager`    | `HTTPManager`     | Comunicación HTTP                |
| `NetworkManager` | `NetworkManager`  | Gestión de datos de red vial     |

### Clases (class_name)

| Clase                | Propósito                                |
|----------------------|------------------------------------------|
| `Config`             | Constantes de configuración global       |
| `HTTPResult`         | Wrapper de respuesta HTTP                |
| `HTTPClient2`        | Cliente HTTP de bajo nivel               |
| `NodeData`           | Datos de nodo de red vial                |
| `EdgeData`           | Datos de arista de red vial              |
| `RoadNetwork`        | Contenedor de red completa               |
| `CameraController`   | Controlador de cámara 3D con órbita/zoom |
| `DebugPanel`         | Panel de estadísticas y controles UI     |
| `NodeRenderer`       | Renderizado 3D de nodos con MultiMesh    |
| `EdgeRenderer`       | Renderizado 3D de carreteras con ImmediateMesh |
| `CoordinateConverter`| Conversión de coordenadas GPS a Godot    |
| `JsonUtils`          | Utilidades de parseo JSON                |
| `UILogger`           | Utilidad de logging para RichTextLabel   |

---

## Endpoints del Backend

| Endpoint               | Método | Descripción                    |
|------------------------|--------|--------------------------------|
| `/api/health`          | GET    | Health check básico            |
| `/api/health/detailed` | GET    | Health check con info sistema  |
| `/api/map/nodes`       | GET    | Obtener nodos (paginado)       |
| `/api/map/edges`       | GET    | Obtener aristas (paginado)     |
| `/api/map/import`      | POST   | Importar archivo OSM           |
| `/api/map/import/status`| GET   | Estado de importación          |
| `/ws/simulation`       | WS     | Comunicación en tiempo real    |

---

## Tecnologías

| Tecnología | Versión | Propósito                        |
|------------|---------|----------------------------------|
| Godot      | 4.5+    | Motor de juego/visualización     |
| GDScript   | 2.0     | Lenguaje de scripting            |
| HTTP/REST  | -       | Comunicación con backend         |
| GeoJSON    | -       | Formato de datos geográficos     |
| WebSocket  | -       | Comunicación en tiempo real      |

---

## Licencia

TFG - Universidad de Castilla-La Mancha