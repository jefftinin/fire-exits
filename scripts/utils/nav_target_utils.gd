class_name NavTargetUtils
extends Object

## Nearest reachable candidate via the navigation mesh, or null.
##
## `candidates` is the filtered group array (Exits/Assemblies). `cache` is an
## optional Dictionary used to memoize `_center()` results per node instance,
## avoiding repeated NavigationServer2D sampling queries for static targets.
static func best_target(nav: NavigationAgent2D, from: Vector2, candidates: Array[Node], cache: Dictionary = {}) -> Node2D:
	var map := nav.get_navigation_map()
	if not map.is_valid():
		return null
	var best: Node2D = null
	var best_len := INF
	var tol := nav.radius + 2.0
	for n in candidates:
		if not is_instance_valid(n) or not (n is Node2D):
			continue
		var node := n as Node2D
		var aim := center(nav, node, cache)
		# Strict on-mesh check of the actual aim point, then a real navigable
		# path that lands near it — skips unreachable (empty or short) paths.
		if not on_mesh(map, aim, tol):
			continue
		var path := NavigationServer2D.map_get_path(map, from, aim, true)
		if path.size() < 2 or path[-1].distance_squared_to(aim) > tol * tol:
			continue
		var len := 0.0
		for i in range(path.size() - 1):
			len += path[i].distance_to(path[i + 1])
		if len < best_len:
			best_len = len
			best = node
	return best

## Centroid of on-mesh samples around a static target (cached per node).
## Exits/assemblies sit at the visual edge of the walkable area; NavigationAgent2D
## clamps the raw position to the mesh boundary, arriving off-center. Sampling
## the 8 cardinal/diagonal neighbors and averaging the on-mesh ones lands the
## arrow in the middle of the walkable opening instead.
static func center(nav: NavigationAgent2D, target: Node2D, cache: Dictionary = {}) -> Vector2:
	var id := target.get_instance_id()
	if cache.has(id):
		return cache[id]
	var map := nav.get_navigation_map()
	if not map.is_valid():
		return target.global_position
	var raw := target.global_position
	var close := NavigationServer2D.map_get_closest_point(map, raw)
	var sample_len := 20.0   # radius of the sampling ring
	var on_tol := 8.0        # on-mesh tolerance for each sample
	var pts: Array[Vector2] = [close]
	var dirs: Array[Vector2] = [
		Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN,
		Vector2(1, 1).normalized(), Vector2(-1, 1).normalized(),
		Vector2(1, -1).normalized(), Vector2(-1, -1).normalized(),
	]
	for d in dirs:
		var s := raw + d * sample_len
		var c := NavigationServer2D.map_get_closest_point(map, s)
		if c.distance_squared_to(s) <= on_tol * on_tol:
			pts.append(c)
	# Only the clamp itself on-mesh → no walkable surroundings; use it as-is.
	if pts.size() == 1:
		cache[id] = close
		return close
	var sum := Vector2.ZERO
	for p in pts:
		sum += p
	var result := NavigationServer2D.map_get_closest_point(map, sum / pts.size())
	cache[id] = result
	return result

## True when `p` is within `tol` of the navigation mesh (via closest-point).
static func on_mesh(map: RID, p: Vector2, tol: float) -> bool:
	var close := NavigationServer2D.map_get_closest_point(map, p)
	return close.distance_squared_to(p) <= tol * tol