extends CharacterBody2D

@onready var nav: NavigationAgent2D = $NavigationAgent2D
@onready var line: Line2D = $"../Line2D"
@onready var polygon: Polygon2D = $Polygon2D

@export var speed: float = 500.0
@export var min_point_distance: float = 5.0

## Emitted when a new point is added to the drawn path.
signal path_point_added(point: Vector2)
## Emitted once when the arrow arrives at the assembly point.
signal path_completed

enum NavState { SEEKING_EXIT, SEEKING_ASSEMBLY }

const ALIGN_TOL: float = 4.0        # px per-axis arrival tolerance
const MIN_SPEED_RATIO: float = 0.35 # slowest speed near a waypoint
const DECEL_RAMP_STEPS: float = 1.5 # ramp starts this many steps out

var exits: Array[Node] = []
var assemblies: Array[Node] = []
var _nav_state: NavState = NavState.SEEKING_EXIT
var _last_recorded: Vector2 = Vector2.INF
var _locked_axis: int = 0        # 0=none, 1=X, 2=Y (persistent, anti-jitter)
var _assembly_reached: bool = false
var _navigation_active: bool = false # seeking only after teleport_to()

## Cached centered positions keyed by node instance ID. Exit/assembly nodes are
## static, so centering is computed once to avoid batch NavigationServer2D
## queries every physics frame.
var _centered_cache: Dictionary = {}

func _ready() -> void:
	_last_recorded = global_position
	refresh_targets()
	polygon.visible = true

## Re-cache scene group targets. Call after dynamically loading a new map.
## Puts the arrow into a fully idle state: it will not seek nor emit
## path_completed until an explicit navigation (teleport_to) re-arms it.
func refresh_targets() -> void:
	exits = get_tree().get_nodes_in_group("Exits").filter(_valid)
	assemblies = get_tree().get_nodes_in_group("Assembly").filter(_valid)
	_nav_state = NavState.SEEKING_EXIT
	_assembly_reached = true     # prevent immediate path_completed
	_navigation_active = false   # do not seek until told to
	nav.target_position = Vector2.ZERO
	velocity = Vector2.ZERO
	line.clear_points()
	_update_total_length()
	_last_recorded = global_position
	polygon.visible = true
	_centered_cache.clear()

func _valid(n: Node) -> bool:
	return is_instance_valid(n)

func teleport_to(new_position: Vector2) -> void:
	# Clear the drawn path and all stale state, then move the body.
	_navigation_active = true    # arm seeking on navigation
	polygon.visible = true
	line.clear_points()
	_update_total_length()
	_last_recorded = new_position
	_centered_cache.clear()
	_nav_state = NavState.SEEKING_EXIT
	_assembly_reached = false
	velocity = Vector2.ZERO
	_locked_axis = 0
	global_position = new_position
	# Force NavigationAgent2D to replan by toggling the target across a frame.
	var saved := nav.target_position
	nav.target_position = new_position
	await get_tree().physics_frame
	nav.target_position = saved

## Nearest reachable assembly target, falling back to any assembly position.
func get_assembly_target_position() -> Vector2:
	if assemblies.is_empty():
		return global_position
	var best := _best_target(assemblies)
	if best != null:
		return _center(best)
	for a in assemblies:
		if is_instance_valid(a) and a is Node2D:
			return (a as Node2D).global_position
	return global_position

func _physics_process(_delta: float) -> void:
	if not _navigation_active:
		velocity = Vector2.ZERO
		return
	if not nav.get_navigation_map().is_valid():
		velocity = Vector2.ZERO
		return
	# Seek the current phase's targets; advance on arrival.
	if _seek(exits if _nav_state == NavState.SEEKING_EXIT else assemblies):
		match _nav_state:
			NavState.SEEKING_EXIT:
				_nav_state = NavState.SEEKING_ASSEMBLY
				_seek(assemblies)  # continue into next phase same frame
			NavState.SEEKING_ASSEMBLY:
				velocity = Vector2.ZERO
				if not _assembly_reached:
					_assembly_reached = true
					polygon.visible = false  # the ExitPanel circle takes over
					path_completed.emit()

## Steers toward the nearest reachable candidate's centered aim point.
## Returns true once the body is axis-aligned within ALIGN_TOL of it.
func _seek(candidates: Array[Node]) -> bool:
	if candidates.is_empty():
		velocity = Vector2.ZERO
		return false
	var target := _best_target(candidates)
	if target == null:
		velocity = Vector2.ZERO
		return false
	# Center the aim so we land mid-opening, not on the navmesh boundary edge.
	var aim := _center(target)
	if nav.target_position != aim:
		nav.target_position = aim
	# Axis-aligned arrival beats is_navigation_finished(), which can fire early
	# on transition frames before the agent recomputes its path.
	var d := global_position - aim
	if absf(d.x) <= ALIGN_TOL and absf(d.y) <= ALIGN_TOL:
		return true
	_move_toward_target()
	return false

## Nearest reachable candidate via the navigation mesh, or null.
func _best_target(candidates: Array[Node]) -> Node2D:
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
		var aim := _center(node)
		# Strict on-mesh check of the actual aim point, then a real navigable
		# path that lands near it — skips unreachable (empty or short) paths.
		if not _on_mesh(map, aim, tol):
			continue
		var path := NavigationServer2D.map_get_path(map, global_position, aim, true)
		if path.size() < 2 or path[-1].distance_squared_to(aim) > tol * tol:
			continue
		var len := 0.0
		for i in range(path.size() - 1):
			len += path[i].distance_to(path[i + 1])
		if len < best_len:
			best_len = len
			best = node
	return best

func _on_mesh(map: RID, p: Vector2, tol: float) -> bool:
	var close := NavigationServer2D.map_get_closest_point(map, p)
	return close.distance_squared_to(p) <= tol * tol

## Centroid of on-mesh samples around a static target (cached per node).
## Exits/assemblies sit at the visual edge of the walkable area; NavigationAgent2D
## clamps the raw position to the mesh boundary, arriving off-center. Sampling
## the 8 cardinal/diagonal neighbors and averaging the on-mesh ones lands the
## arrow in the middle of the walkable opening instead.
func _center(target: Node2D) -> Vector2:
	var id := target.get_instance_id()
	if _centered_cache.has(id):
		return _centered_cache[id]
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
		_centered_cache[id] = close
		return close
	var sum := Vector2.ZERO
	for p in pts:
		sum += p
	var result := NavigationServer2D.map_get_closest_point(map, sum / pts.size())
	_centered_cache[id] = result
	return result

func _move_toward_target() -> void:
	var delta := get_physics_process_delta_time()
	var step_r := speed * delta  # raw per-frame step
	# Corner-safe deceleration: ramp speed down near each waypoint so we never
	# skip past a corner (the #1 cause of wall clipping at high speed).
	var wp := nav.get_next_path_position() - global_position
	var wp_dist := wp.length()
	var ratio := wp_dist / maxf(step_r * DECEL_RAMP_STEPS, 0.001)
	var step := step_r * (MIN_SPEED_RATIO + (1.0 - MIN_SPEED_RATIO) * clampf(ratio, 0.0, 1.0))

	var x_aligned := absf(wp.x) <= ALIGN_TOL
	var y_aligned := absf(wp.y) <= ALIGN_TOL
	# Cardinal movement with persistent axis lock to prevent per-frame
	# oscillation between axes when distances are similar.
	var dir := Vector2.ZERO
	if x_aligned and y_aligned:
		_locked_axis = 0
	elif x_aligned:
		_locked_axis = 2
		dir = Vector2(0.0, signf(wp.y))
	elif y_aligned:
		_locked_axis = 1
		dir = Vector2(signf(wp.x), 0.0)
	elif _locked_axis == 1 or (_locked_axis == 0 and absf(wp.x) >= absf(wp.y)):
		_locked_axis = 1
		dir = Vector2(signf(wp.x), 0.0)
	else:
		_locked_axis = 2
		dir = Vector2(0.0, signf(wp.y))

	# Overshoot clamp — never move farther on the active axis than the remaining
	# distance to the waypoint, guaranteeing we land exactly on the corner.
	var mv := dir * step
	match _locked_axis:
		1: mv.x = signf(mv.x) * minf(absf(mv.x), absf(wp.x))
		2: mv.y = signf(mv.y) * minf(absf(mv.y), absf(wp.y))

	velocity = mv / delta
	move_and_slide()
	if velocity.length_squared() > 0.0:
		rotation = velocity.angle()  # snap to 0/90/180/-90°
	_record_path_point()

func _record_path_point() -> void:
	var p := global_position
	if _last_recorded == Vector2.INF:
		line.add_point(Vector2.ZERO)
		_last_recorded = p
		return
	if p.distance_squared_to(_last_recorded) >= min_point_distance * min_point_distance:
		line.add_point(p)
		_last_recorded = p
		_update_total_length()
		path_point_added.emit(p)

## Recompute the Line2D's arc length for the shader so dash sizes stay fixed in
## pixels regardless of line length (prevents the UV-based "pulsing" artifact).
func _update_total_length() -> void:
	var len := 0.0
	var pts := line.points
	for i in range(1, pts.size()):
		len += pts[i - 1].distance_to(pts[i])
	var mat := line.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("total_length", len)
