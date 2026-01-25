# Digital Twin Traffic Client

Cliente Godot 4.x para el gemelo digital de tráfico urbano de Talavera de la Reina.

## Descripción

Este proyecto implementa el frontend 3D para visualizar y controlar la simulación de tráfico urbano. Desarrollado con Godot 4.5 y GDScript, se comunica con el backend FastAPI mediante HTTP y WebSocket.

### Características principales

- **Cliente HTTP** con async/await para comunicación REST con el backend
- **WebSocket** para comunicación en tiempo real (próximamente)
- **Sistema de configuración** centralizado
- **Manejo de errores** robusto con timeouts y reintentos
- **Escenas de prueba** para verificar conectividad

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
3. Usar "Open Test Scene" para ejecutar pruebas completas

## Configuración

La configuración se encuentra en [config/config.gd](config/config.gd):

```gdscript
## Backend API configuration
const BACKEND_HOST: String = "localhost"
const BACKEND_PORT: int = 8000
const BACKEND_PROTOCOL: String = "http"

## HTTP client configuration
const HTTP_TIMEOUT_SECONDS: float = 10.0
const HTTP_MAX_RETRIES: int = 3
```

Para cambiar la URL del backend, modifica estas constantes.

## Estructura del Proyecto

```
tfg-dt-godot-client/
├── scenes/
│   ├── main.tscn                      # Escena principal
│   └── test_scenes/
│       └── test_connection.tscn       # Escena de pruebas HTTP
├── scripts/
│   ├── autoload/
│   │   └── http_manager.gd            # Singleton HTTPManager
│   ├── http/
│   │   ├── http_client.gd             # Wrapper HTTP con async/await
│   │   └── http_result.gd             # Clase de resultado HTTP
│   ├── models/                        # Modelos de datos (futuro)
│   ├── test_scenes/
│   │   └── test_connection.gd         # Script de pruebas
│   ├── utils/
│   │   └── json_utils.gd              # Utilidades JSON
│   └── main.gd                        # Script escena principal
├── resources/
│   ├── materials/                     # Materiales (futuro)
│   ├── meshes/                        # Mallas 3D (futuro)
│   └── shaders/                       # Shaders (futuro)
├── assets/                            # Assets externos (futuro)
├── config/
│   └── config.gd                      # Configuración global
├── .gitignore
├── project.godot
└── README.md
```

## Uso del Cliente HTTP

### Acceso global via HTTPManager

El singleton `HTTPManager` está disponible globalmente:

```gdscript
# Health check básico
var result := await HTTPManager.health_check()
if result.success:
    print("Backend conectado!")

# Health check detallado
var detailed := await HTTPManager.health_check_detailed()
if detailed.success:
    print("Sistema info: ", detailed.data)

# GET request
var response := await HTTPManager.get_request("/map/import/status")

# POST request con datos
var import_result := await HTTPManager.post_request("/map/import", {
    "filepath": "talavera.osm",
    "clear_existing": true
})
```

### Manejo de errores

```gdscript
var result := await HTTPManager.get_request("/some/endpoint")

if result.success:
    # Procesar datos
    var data = result.data
    print("Status: ", result.status_code)
else:
    # Manejar error
    match result.error_type:
        HTTPResult.ErrorType.CONNECTION_REFUSED:
            print("No se puede conectar al servidor")
        HTTPResult.ErrorType.TIMEOUT:
            print("Timeout de conexión")
        HTTPResult.ErrorType.HTTP_ERROR:
            print("Error HTTP: ", result.status_code)
        _:
            print("Error: ", result.error_message)
```

### Utilidades JSON

```gdscript
# Parseo seguro
var parse_result := JsonUtils.parse(json_string)
if parse_result.success:
    var data = parse_result.data

# Obtener valores con defaults
var name := JsonUtils.get_string(dict, "name", "Unknown")
var count := JsonUtils.get_int(dict, "count", 0)

# Acceso a valores anidados
var city := JsonUtils.get_nested(dict, "address.city", "N/A")
```

## Escenas de Prueba

### test_connection.tscn

Proporciona pruebas completas del cliente HTTP:

| Test | Descripción |
|------|-------------|
| Health Check | Verifica endpoint `/api/health` |
| Detailed Health | Verifica endpoint `/api/health/detailed` |
| 404 Error | Prueba manejo de errores 404 |
| Connection Refused | Prueba timeout y conexión rechazada |

Para ejecutar:
1. Desde la escena principal, clic en "Open Test Scene"
2. Clic en "Run All Tests" para ejecutar todas las pruebas
3. O ejecutar pruebas individuales con los botones correspondientes

## Endpoints del Backend

| Endpoint | Método | Descripción |
|----------|--------|-------------|
| `/api/health` | GET | Health check básico |
| `/api/health/detailed` | GET | Health check con info del sistema |
| `/api/map/import/status` | GET | Estado del sistema de importación |
| `/api/map/import` | POST | Importar archivo OSM |
| `/ws/simulation` | WebSocket | Comunicación en tiempo real |

## Señales

### HTTPManager

```gdscript
# Emitida cuando cambia el estado de conexión
signal connection_status_changed(is_connected: bool)

# Emitida cuando se completa un health check
signal health_check_completed(result: HTTPResult)
```

### Ejemplo de uso:

```gdscript
func _ready():
    HTTPManager.connection_status_changed.connect(_on_connection_changed)

func _on_connection_changed(is_connected: bool):
    if is_connected:
        print("Conectado al backend")
    else:
        print("Desconectado del backend")
```

## Próximos pasos (Sprint 1.2+)

- [ ] Cliente WebSocket para comunicación en tiempo real
- [ ] Visualización 3D del mapa
- [ ] Renderizado de vehículos
- [ ] Controles de simulación

## Tecnologías

| Tecnología | Versión | Propósito |
|------------|---------|-----------|
| Godot | 4.5+ | Motor de juego/visualización |
| GDScript | 2.0 | Lenguaje de scripting |
| HTTP/REST | - | Comunicación con backend |
| WebSocket | - | Comunicación en tiempo real |

## Licencia

Este proyecto es parte del Trabajo de Fin de Grado (TFG) sobre Gemelos Digitales.
