## Centripetal Catmull-Rom spline (α=0.5) — twin of app/core/spline.py
## (backend). The two implementations follow the same arithmetic so a parity
## test can compare per-sample positions to within IEEE-754 rounding.
##
## Used by EdgeRenderer to draw roundabout edges as smooth curves instead of
## polylines that pivot at every OSM waypoint. Vehicles still get their
## position from the backend; the renderer only needs visually smooth roads.
class_name Spline
extends RefCounted


const _CR_ALPHA: float = 0.5


## Sample a centripetal Catmull-Rom spline through `points` with
## `samples_per_segment` evenly-spaced (in u, NOT in arc length) intermediate
## points per segment plus one final point at the end.
##
## Returns `(n - 1) * samples_per_segment + 1` points. First and last samples
## coincide with the first and last input points.
##
## `phantom_pre` / `phantom_post` (Vector2 or null) override the implicit
## reflected phantoms at the endpoints, which is useful to match the tangent
## of an adjacent spline at a shared waypoint.
static func sample(
	points: PackedVector2Array,
	samples_per_segment: int = 8,
	phantom_pre: Variant = null,
	phantom_post: Variant = null,
) -> PackedVector2Array:
	var n: int = points.size()
	var out := PackedVector2Array()
	if n < 2:
		out.append_array(points)
		return out
	if n == 2:
		var inv := 1.0 / float(samples_per_segment)
		for j in range(samples_per_segment + 1):
			var u := float(j) * inv
			out.append(points[0].lerp(points[1], u))
		return out

	var p_pre: Vector2
	if phantom_pre is Vector2:
		p_pre = phantom_pre
	else:
		p_pre = points[0] * 2.0 - points[1]

	var p_post: Vector2
	if phantom_post is Vector2:
		p_post = phantom_post
	else:
		p_post = points[n - 1] * 2.0 - points[n - 2]

	var inv_seg := 1.0 / float(samples_per_segment)
	for i in range(n - 1):
		var p0: Vector2 = p_pre if i == 0 else points[i - 1]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[i + 1]
		var p3: Vector2 = p_post if i == n - 2 else points[i + 2]
		for j in range(samples_per_segment):
			var u := float(j) * inv_seg
			out.append(_eval_segment(p0, p1, p2, p3, u))
	out.append(points[n - 1])
	return out


static func _eval_segment(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, u: float) -> Vector2:
	var d01: float = maxf(pow((p1 - p0).length(), _CR_ALPHA), 1e-12)
	var d12: float = maxf(pow((p2 - p1).length(), _CR_ALPHA), 1e-12)
	var d23: float = maxf(pow((p3 - p2).length(), _CR_ALPHA), 1e-12)

	var t0: float = 0.0
	var t1: float = t0 + d01
	var t2: float = t1 + d12
	var t3: float = t2 + d23
	var t: float = t1 + u * (t2 - t1)

	var a1: Vector2 = p0.lerp(p1, (t - t0) / (t1 - t0))
	var a2: Vector2 = p1.lerp(p2, (t - t1) / (t2 - t1))
	var a3: Vector2 = p2.lerp(p3, (t - t2) / (t3 - t2))
	var b1: Vector2 = a1.lerp(a2, (t - t0) / (t2 - t0))
	var b2: Vector2 = a2.lerp(a3, (t - t1) / (t3 - t1))
	return b1.lerp(b2, (t - t1) / (t2 - t1))
