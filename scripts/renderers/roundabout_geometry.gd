## RoundaboutGeometry — pre-cálculo por mapa de las circunferencias de cada
## rotonda. El EdgeRenderer las usa para clippear la geometría de los brazos
## (aristas con `is_roundabout=False`) y eliminar las porciones que caen
## dentro del anillo, sea por endpoint o por waypoint intermedio.
##
## El clip cubre los tres patrones que producen mallas de brazos invadiendo
## el centro de la rotonda:
##   1. El endpoint del brazo es un nodo del anillo (caso normal): el
##      polyline termina sobre la centerline, la perpendicular a la
##      extrusión empuja la malla hacia adentro en aproximaciones oblicuas.
##   2. El endpoint del brazo cae dentro del ring sin estar etiquetado como
##      nodo del anillo (datos OSM messy con un "nodo central" o similar).
##   3. El polyline del brazo cruza la rotonda con ambos extremos fuera
##      (road que pasa a través del ring, error de mapeo OSM).
##
## Estrategia: por cada `roundabout_id` calcular el centroide en world-XZ y
## el `R_max` (distancia máxima desde el centroide a cualquier waypoint del
## ring). El círculo de recorte es `(centroide, R_max + safety)`. Todo lo
## que caiga dentro de ese círculo en un brazo se elimina del render.
class_name RoundaboutGeometry
extends RefCounted


## Resumen por rotonda (clave: roundabout_id, int).
##   summaries[rid] = {
##     center: Vector2 (world XZ, m),
##     R_max_m: float (radio del bounding-circle del ring, m)
##   }
var summaries: Dictionary = {}


## Construye los resúmenes a partir del listado de aristas y el converter de
## coordenadas. Se llama una vez por carga de red — `EdgeRenderer.render_edges`
## la invoca antes de extruir la malla. Coste O(N_waypoints_ring) por rotonda
## en dos pasadas.
func build(edges: Array, converter: CoordinateConverter) -> void:
	summaries.clear()

	if converter == null or not converter.is_initialized():
		return

	# 1. Aislar las aristas marcadas como rotonda (cualquier `roundabout_id`,
	#    incluso -1 — ver más abajo).
	var ring_edges: Array = []
	for edge in edges:
		if edge != null and edge.is_roundabout:
			ring_edges.append(edge)
	if ring_edges.is_empty():
		return

	# 2. Agrupamiento por **conectividad espacial** (BFS sobre nodos
	#    compartidos). El backend asigna `roundabout_id` con un BFS propio,
	#    pero hay rotondas en OSM donde la detección falla y el `rid` queda
	#    en -1; agrupar aquí mismo a partir de los endpoints nos hace
	#    independientes de eso. Cada componente conexo es una rotonda
	#    distinta.
	var node_to_indices: Dictionary = {}
	for i in range(ring_edges.size()):
		var e = ring_edges[i]
		var lst1: Array = node_to_indices.get(e.start_node_id, [])
		lst1.append(i)
		node_to_indices[e.start_node_id] = lst1
		var lst2: Array = node_to_indices.get(e.end_node_id, [])
		lst2.append(i)
		node_to_indices[e.end_node_id] = lst2

	var component_of: PackedInt32Array = PackedInt32Array()
	component_of.resize(ring_edges.size())
	for i in range(ring_edges.size()):
		component_of[i] = -1
	var next_comp_id: int = 0
	for i in range(ring_edges.size()):
		if component_of[i] != -1:
			continue
		var queue: Array = [i]
		component_of[i] = next_comp_id
		while not queue.is_empty():
			var cur: int = queue.pop_back()
			var e = ring_edges[cur]
			for n_id in [e.start_node_id, e.end_node_id]:
				for nbr in node_to_indices.get(n_id, []):
					if component_of[nbr] == -1:
						component_of[nbr] = next_comp_id
						queue.append(nbr)
		next_comp_id += 1

	# 3. Acumular waypoints world-space por componente.
	var sum_x: Dictionary = {}
	var sum_z: Dictionary = {}
	var sample_count: Dictionary = {}
	var waypoints_by_comp: Dictionary = {}
	for i in range(ring_edges.size()):
		var e = ring_edges[i]
		var comp: int = component_of[i]
		var bucket: Array = waypoints_by_comp.get(comp, [])
		for coord in e.geometry:
			if coord is Array and coord.size() >= 2:
				var w := converter.gps_to_godot(float(coord[0]), float(coord[1]))
				var p := Vector2(w.x, w.z)
				bucket.append(p)
				sum_x[comp] = sum_x.get(comp, 0.0) + p.x
				sum_z[comp] = sum_z.get(comp, 0.0) + p.y
				sample_count[comp] = sample_count.get(comp, 0) + 1
		waypoints_by_comp[comp] = bucket

	var safety: float = Config.EdgeRendering.ROUNDABOUT_ARM_TRIM_SAFETY_M

	for comp in sum_x.keys():
		var n: int = sample_count.get(comp, 0)
		if n <= 0:
			continue
		var center := Vector2(sum_x[comp] / float(n), sum_z[comp] / float(n))
		var R_max := 0.0
		for p in waypoints_by_comp.get(comp, []):
			var d: float = (p as Vector2).distance_to(center)
			if d > R_max:
				R_max = d
		summaries[comp] = {
			"center": center,
			"R_max_m": R_max,
			"R_clip_m": R_max + safety,
		}


## Devuelve los círculos de recorte de todas las rotondas conocidas. El
## EdgeRenderer itera sobre éstos para clippear los brazos.
##
## Cada elemento: { center: Vector2, R_clip_m: float }
func clip_circles() -> Array:
	var out: Array = []
	for rid in summaries.keys():
		var s = summaries[rid]
		out.append({
			"center": s.center,
			"R_clip_m": s.R_clip_m,
		})
	return out
