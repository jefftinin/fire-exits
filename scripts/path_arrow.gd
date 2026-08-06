extends CharacterBody2D

@onready var nav: NavigationAgent2D = $NavigationAgent2D
@onready var line: Line2D = $"../Line2D"
@onready var polygon: Polygon2D = $Polygon2D

@export var speed: float = 500.0
@export var min_point_distance: float = 5.0
## Speed multiplier used by the invisible probe run that measures the path
## extents before the visible arrow animates. Higher = snappier fit.
@export var probe_speed_multiplier: float = 32.0
## Distance from an exit's aim point that counts as "approached" while seeking
## the exit. Passing within this radius advances to the assembly phase, so the
## arrow doesn't detour to touch the exit center exactly when the assembly
## area lies near or past the exit.
@export var exit_approach_radius: float = 32.0

## Emitted once when the invisible probe run reaches the assembly point,
## carrying the world-space bounds of the entire traveled path. The camera
## uses these extents to zoom out to the full route before the visible arrow
## animates.
signal probe_completed(bounds: Rect2)
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
## True while the invisible probe run is active (measuring the path extents
## only, so the camera can fit the full route before the visible animation).
var _probe_mode: bool = false
## Low-density route collected during the visible run: start + every turn +
## final point. Swapped into the Line2D once the visible arrow finishes,
## replacing the high-density intermediate points.
var _low_density_points: PackedVector2Array = PackedVector2Array()
## World-space bounds expanded over every position the probe visits. Emitted
## with probe_completed so the camera can fit the full route.
var _probe_bounds: Rect2 = Rect2()
## Last cardinal direction the body moved along. Detects turns (a change of
## axis) so a point is recorded exactly at each corner of the visible path.
var _last_dir: Vector2 = Vector2.ZERO

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
	_probe_mode = false
	_low_density_points = PackedVector2Array()
	_probe_bounds = Rect2()
	_last_dir = Vector2.ZERO
	nav.target_position = Vector2.ZERO
	velocity = Vector2.ZERO
	line.clear_points()
	LineUtils.update_total_length(line)
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
	LineUtils.update_total_length(line)
	_last_recorded = new_position
	_centered_cache.clear()
	_nav_state = NavState.SEEKING_EXIT
	_assembly_reached = false
	velocity = Vector2.ZERO
	_locked_axis = 0
	_last_dir = Vector2.ZERO
	# The visible run drops the start point as the first low-density point.
	_low_density_points = PackedVector2Array([new_position])
	global_position = new_position
	# Force NavigationAgent2D to replan by toggling the target across a frame.
	var saved := nav.target_position
	nav.target_position = new_position
	await get_tree().physics_frame
	nav.target_position = saved

## Starts an invisible probe run from `from`: navigates the full exit→assembly
## route at an accelerated speed while measuring the traveled path's world-space
## bounds. On arrival it emits probe_completed(bounds) so the camera can fit
## the full route before the visible arrow animates.
## NOTE: No line drawing or path_point signals are emitted during a probe.
func start_probe(from: Vector2) -> void:
	_probe_mode = true
	_navigation_active = true
	_probe_bounds = Rect2(from, Vector2.ZERO)
	_last_dir = Vector2.ZERO
	_centered_cache.clear()
	_nav_state = NavState.SEEKING_EXIT
	_assembly_reached = false
	velocity = Vector2.ZERO
	_locked_axis = 0
	global_position = from
	var saved := nav.target_position
	nav.target_position = from
	await get_tree().physics_frame
	nav.target_position = saved

## Ends an active probe, returning the body to its pre-probe idle state so a
## subsequent teleport_to() can begin the visible run cleanly.
func end_probe() -> void:
	_probe_mode = false
	_navigation_active = false
	_probe_bounds = Rect2()
	velocity = Vector2.ZERO
	nav.target_position = Vector2.ZERO

## Returns the low-density route collected during the visible run: start, every
## turn corner, and the final assembly point. These are swapped into the Line2D
## once the visible arrow finishes, replacing the high-density intermediates.
func get_low_density_points() -> PackedVector2Array:
	return _low_density_points

## Nearest reachable assembly target, falling back to any assembly position.
func get_assembly_target_position() -> Vector2:
	if assemblies.is_empty():
		return global_position
	var best := NavTargetUtils.best_target(nav, global_position, assemblies, _centered_cache)
	if best != null:
		return NavTargetUtils.center(nav, best, _centered_cache)
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
					if _probe_mode:
						_probe_bounds = _probe_bounds.expand(global_position)
						probe_completed.emit(_probe_bounds)
					else:
						# The visible run's final position is the last low-density point.
						_low_density_points.append(global_position)
						polygon.visible = false  # the ExitPanel circle takes over
						if _low_density_points.size() >= 2:
							line.clear_points()
							line.points = _low_density_points
							LineUtils.update_total_length(line)
						path_completed.emit()

## Steers toward the nearest reachable candidate's centered aim point.
## Returns true once the body is axis-aligned within ALIGN_TOL of it.
func _seek(candidates: Array[Node]) -> bool:
	if candidates.is_empty():
		velocity = Vector2.ZERO
		return false
	var target := NavTargetUtils.best_target(nav, global_position, candidates, _centered_cache)
	if target == null:
		velocity = Vector2.ZERO
		return false
	# Center the aim so we land mid-opening, not on the navmesh boundary edge.
	var aim := NavTargetUtils.center(nav, target, _centered_cache)
	if nav.target_position != aim:
		nav.target_position = aim
	# Exit approach is proximity-based: passing within exit_approach_radius of
	# the aim counts as reached, so we don't overshoot past the opening just to
	# nail the exact center when the assembly area lies near the exit.
	if _nav_state == NavState.SEEKING_EXIT:
		if global_position.distance_squared_to(aim) <= exit_approach_radius * exit_approach_radius:
			return true
	# Assembly still needs the strict axis-aligned landing so the path ends
	# cleanly at the assembly point. Axis-aligned arrival beats
	# is_navigation_finished(), which can fire early on transition frames
	# before the agent recomputes its path.
	var d := global_position - aim
	if absf(d.x) <= ALIGN_TOL and absf(d.y) <= ALIGN_TOL:
		return true
	_move_toward_target()
	return false

func _move_toward_target() -> void:
	var delta := get_physics_process_delta_time()
	# The probe accelerates to measure extents quickly; the corner-safe ramp and
	# overshoot clamp keep it accurate at speed, and the nav polyline is
	# speed-independent so turns match the visible run.
	var eff_speed := speed * (probe_speed_multiplier if _probe_mode else 1.0)
	var step_r := eff_speed * delta  # raw per-frame step
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

	# Detect a turn BEFORE moving: when the desired direction changes, the
	# body is still sitting exactly on the corner waypoint (the overshoot
	# clamp guarantees it lands precisely on each waypoint), so global_position
	# is the true corner.
	_detect_turn(dir)

	velocity = mv / delta
	move_and_slide()
	if velocity.length_squared() > 0.0:
		rotation = velocity.angle()  # snap to 0/90/180/-90°
	_record_path_point()

## Detects a change in the active cardinal movement direction. When the axis
## the body is locked to changes, it is exactly on the bounding corner of that
## leg: during the visible run we record that corner into the low-density route
## (start + every turn + final), during the probe we only expand the bounds.
##
## The arrow pauses on the corner frame (dir == ZERO) before choosing the next
## leg, so that reset is skipped — the turn is recorded on the first frame the
## new, non-zero direction is issued, while the body is still on the corner.
func _detect_turn(dir: Vector2) -> void:
	if not _navigation_active or dir == Vector2.ZERO:
		return
	if _last_dir == Vector2.ZERO:
		# First leg after teleport: not a turn; the start is already seeded.
		_last_dir = dir
		return
	if dir != _last_dir:
		if _probe_mode:
			_probe_bounds = _probe_bounds.expand(global_position)
		else:
			_low_density_points.append(global_position)
	_last_dir = dir

func _record_path_point() -> void:
	if _probe_mode:
		# The probe collects extents/turns only; the visible Line2D stays clear.
		_probe_bounds = _probe_bounds.expand(global_position)
		return
	var p := global_position
	if _last_recorded == Vector2.INF:
		line.add_point(Vector2.ZERO)
		_last_recorded = p
		return
	if p.distance_squared_to(_last_recorded) >= min_point_distance * min_point_distance:
		line.add_point(p)
		_last_recorded = p
		LineUtils.update_total_length(line)
