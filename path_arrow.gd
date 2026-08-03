extends CharacterBody2D

@onready var line_2d: Line2D = $"../Line2D"
@onready var navigation_agent_2d: NavigationAgent2D = $NavigationAgent2D

@export var speed: float = 500.0
@export var line_color: Color = Color(1.0, 1.0, 0.0, 0.8)
@export var line_width: float = 4.0
@export var min_point_distance: float = 5.0

enum NavState { SEEKING_EXIT, SEEKING_ASSEMBLY }

var exits: Array[Node] = []
var assemblies: Array[Node] = []
var _nav_state: NavState = NavState.SEEKING_EXIT
var doors: Array[Node] = [] 

var _last_recorded_position: Vector2 = Vector2.INF

## Cache of centered target positions keyed by the target node's instance ID.
## Exit/assembly nodes don't move, so their centered position only needs to be
## computed once; this avoids ~8+ NavigationServer2D queries per target per frame.
var _centered_cache: Dictionary = {}

## Axis-alignment tolerance in pixels. When the remaining X or Y distance
## to the current waypoint falls within this range, that axis is "aligned".
const BASE_ALIGN_TOLERANCE: float = 4.0

## Minimum speed ratio (0–1) applied near waypoints. Decelerating prevents
## overshooting a corner, which is the primary cause of wall clipping at
## high speed.
const MIN_SPEED_RATIO: float = 0.35

## Distance (in multiples of per-frame step) over which deceleration ramps
## in before a waypoint. 1.5 means speed starts slowing ~1.5 steps before
## the corner.
const DECEL_RAMP_STEPS: float = 1.5

## Tracks which axis is currently locked for cardinal movement.
## 0 = none, 1 = X-axis, 2 = Y-axis. Prevents per-frame oscillation
## between axes when distances are similar.
var _locked_axis: int = 0

func _ready() -> void:
	_last_recorded_position = global_position
	refresh_targets()

## Refreshes the cached exit and assembly target lists from scene groups.
## Call this after dynamically loading a new map so the agent can find new targets.
func refresh_targets() -> void:
	doors = get_tree().get_nodes_in_group("Doors")
	exits = get_tree().get_nodes_in_group("Exits").filter(func(n): return is_instance_valid(n))
	assemblies = get_tree().get_nodes_in_group("Assembly").filter(func(n): return is_instance_valid(n))
	# Reset navigation state since targets have changed
	_nav_state = NavState.SEEKING_EXIT
	navigation_agent_2d.target_position = Vector2.ZERO
	# Targets have changed — invalidate the centered-position cache
	_centered_cache.clear()

func teleport_to(new_position: Vector2) -> void:
	# Clear the drawn path
	line_2d.clear_points()
	_update_total_length()
	_last_recorded_position = new_position
	# The start point changed, so any centering state is stale
	_centered_cache.clear()
	
	# Reset navigation state to start fresh
	_nav_state = NavState.SEEKING_EXIT
	
	# Reset physics state for clean teleport
	velocity = Vector2.ZERO
	_locked_axis = 0
	
	# Move the body
	global_position = new_position
	
	# Force NavigationAgent2D to replan by temporarily clearing target
	var saved_target := navigation_agent_2d.target_position
	navigation_agent_2d.target_position = new_position
	await get_tree().physics_frame
	navigation_agent_2d.target_position = saved_target

func _is_on_navigation_mesh(point: Vector2) -> bool:
	var map := navigation_agent_2d.get_navigation_map()
	if not map.is_valid():
		return false
	var closest_point := NavigationServer2D.map_get_closest_point(map, point)
	# Allow tolerance based on agent radius plus a small margin
	var tolerance := navigation_agent_2d.radius + 5.0
	return point.distance_squared_to(closest_point) <= tolerance * tolerance

## Finds the nearest reachable target from a list of candidate nodes.
## Returns null if no candidates are reachable via the navigation mesh.
func _find_nearest_reachable_target(candidates: Array[Node]) -> Node2D:
	var map := navigation_agent_2d.get_navigation_map()
	if not map.is_valid():
		return null
	
	var best_target: Node2D = null
	var best_path_length: float = INF
	
	for candidate in candidates:
		if not is_instance_valid(candidate):
			continue
		if candidate is Node2D:
			var candidate_node := candidate as Node2D
			
			# Compute the centered aim point for this candidate so we verify
			# reachability of the actual navigation target, not just the raw node.
			var aim_point := _get_centered_target_position(candidate_node)
			
			# Verify aim point is truly on the navmesh (strict check)
			var closest_to_candidate := NavigationServer2D.map_get_closest_point(map, aim_point)
			var reach_tolerance := navigation_agent_2d.radius + 2.0
			if closest_to_candidate.distance_squared_to(aim_point) > reach_tolerance * reach_tolerance:
				continue
			
			# Compute actual navigable path to the centered aim point
			var path := NavigationServer2D.map_get_path(
				map,
				global_position,
				aim_point,
				true  # optimize: true for shortest path
			)
			
			# Skip unreachable candidates (empty path or only start point)
			if path.size() < 2:
				continue
			
			# Verify the path endpoint actually reaches near the aim point
			var path_endpoint := path[path.size() - 1]
			if path_endpoint.distance_squared_to(aim_point) > reach_tolerance * reach_tolerance:
				continue
			
			# Calculate total path length
			var path_length: float = 0.0
			for i in range(path.size() - 1):
				path_length += path[i].distance_to(path[i + 1])
			if path_length < best_path_length:
				best_path_length = path_length
				best_target = candidate_node
	
	return best_target

## Computes a centered target position on the navigation mesh for a given
## target node. Exits/assembly points often sit at the visual edge of the
## walkable area (e.g. a doorway opening), and NavigationAgent2D clamps raw
## positions onto the mesh boundary — causing the arrow to arrive off-center.
## This samples the 8 cardinal/diagonal directions around the target and
## returns the centroid of all on-mesh sample points, so the arrow navigates
## to the middle of the walkable opening rather than its clamped edge.
func _get_centered_target_position(target_node: Node2D) -> Vector2:
	# Cache the result per node — targets are static, so this avoids repeating
	# a batch of NavigationServer2D queries every physics frame.
	var node_id := target_node.get_instance_id()
	if _centered_cache.has(node_id):
		return _centered_cache[node_id]
	
	var map := navigation_agent_2d.get_navigation_map()
	if not map.is_valid():
		return target_node.global_position
	
	var raw_target := target_node.global_position
	var closest_to_raw := NavigationServer2D.map_get_closest_point(map, raw_target)
	
	# Local sampling distance and tolerance — tight enough to detect the
	# walkable opening immediately around the target without spanning into
	# surrounding obstacles or far-side corridors.
	const SAMPLE_DIST: float = 20.0
	const ON_MESH_TOLERANCE: float = 8.0
	
	var directions: Array[Vector2] = [
		Vector2.RIGHT,
		Vector2.LEFT,
		Vector2.UP,
		Vector2.DOWN,
		Vector2(1, 1).normalized(),
		Vector2(-1, 1).normalized(),
		Vector2(1, -1).normalized(),
		Vector2(-1, -1).normalized(),
	]
	
	# Start with the clamp of the raw target onto the mesh
	var valid_points: Array[Vector2] = [closest_to_raw]
	
	for dir in directions:
		var sample := raw_target + dir * SAMPLE_DIST
		var sample_closest := NavigationServer2D.map_get_closest_point(map, sample)
		if sample_closest.distance_squared_to(sample) <= ON_MESH_TOLERANCE * ON_MESH_TOLERANCE:
			valid_points.append(sample_closest)
	
	# If only the clamped point itself is on the mesh, there's no walkable
	# surroundings to center on — fall back to the clamped point.
	if valid_points.size() == 1:
		_centered_cache[node_id] = closest_to_raw
		return closest_to_raw
	
	# Centroid of all on-mesh points gives the center of the walkable space
	var centroid := Vector2.ZERO
	for p in valid_points:
		centroid += p
	centroid /= valid_points.size()
	
	# Safety: clamp the centroid back onto the mesh
	var result := NavigationServer2D.map_get_closest_point(map, centroid)
	_centered_cache[node_id] = result
	return result

func _physics_process(_delta: float) -> void:
	var map := navigation_agent_2d.get_navigation_map()
	if not map.is_valid():
		velocity = Vector2.ZERO
		return
	
	match _nav_state:
		NavState.SEEKING_EXIT:
			if exits.is_empty():
				velocity = Vector2.ZERO
				return
			
			var best_exit := _find_nearest_reachable_target(exits)
			if best_exit == null:
				velocity = Vector2.ZERO
				return
			
			# Compute the centered arrival point so the arrow lands in the
			# middle of the walkable opening instead of its clamped edge.
			var centered_exit_pos := _get_centered_target_position(best_exit)
			
			# Update target if changed or not yet set
			if navigation_agent_2d.target_position != centered_exit_pos:
				navigation_agent_2d.target_position = centered_exit_pos
			
			# Check if navigation is complete (arrived at exit)
			# Don't rely on is_navigation_finished() as it returns true for intermediate waypoints.
			# Use axis-aligned arrival so we don't transition while visibly offset.
			var to_exit := global_position - centered_exit_pos
			if absf(to_exit.x) <= BASE_ALIGN_TOLERANCE and absf(to_exit.y) <= BASE_ALIGN_TOLERANCE:
				_nav_state = NavState.SEEKING_ASSEMBLY
				# Fall through to assembly seeking in same frame
				_handle_assembly_seeking()
				return
			
			_move_toward_target()
		
		NavState.SEEKING_ASSEMBLY:
			_handle_assembly_seeking()

func _handle_assembly_seeking() -> void:
	if assemblies.is_empty():
		velocity = Vector2.ZERO
		return
	
	var best_assembly := _find_nearest_reachable_target(assemblies)
	if best_assembly == null:
		velocity = Vector2.ZERO
		return
	
	# Compute the centered arrival point so the arrow lands centered in the
	# walkable area near the assembly point.
	var centered_assembly_pos := _get_centered_target_position(best_assembly)
	
	# Update target if changed or not yet set
	if navigation_agent_2d.target_position != centered_assembly_pos:
		navigation_agent_2d.target_position = centered_assembly_pos
	
	# Check if navigation is complete (arrived at assembly).
	# Use the same axis-aligned arrival check as the exit phase so we don't
	# rely on is_navigation_finished(), which can return true prematurely on
	# the transition frame before the agent has recomputed a path.
	var to_assembly := global_position - centered_assembly_pos
	if absf(to_assembly.x) <= BASE_ALIGN_TOLERANCE and absf(to_assembly.y) <= BASE_ALIGN_TOLERANCE:
		velocity = Vector2.ZERO
		return
	
	_move_toward_target()

## Finds the nearest door to a given position from the cached doors list.
## Returns the door's global position, or the fallback if no doors exist.
func _find_nearest_door_position(to_position: Vector2, fallback: Vector2) -> Vector2:
	if doors.is_empty():
		return fallback
	
	var best_pos: Vector2 = fallback
	var best_dist_sq: float = INF
	
	for door in doors:
		if not is_instance_valid(door):
			continue
		if door is Node2D:
			var door_pos := (door as Node2D).global_position
			var dist_sq := door_pos.distance_squared_to(to_position)
			if dist_sq < best_dist_sq:
				best_dist_sq = dist_sq
				best_pos = door_pos
	
	return best_pos

func _move_toward_target() -> void:
	var delta_time := get_physics_process_delta_time()
	var base_step := speed * delta_time
	
	# Get next path position from navigation agent
	var next_path_position := navigation_agent_2d.get_next_path_position()
	var to_waypoint := next_path_position - global_position
	var waypoint_distance := to_waypoint.length()
	
	# ** Corner-safe deceleration **
	# Slow down as we approach a waypoint so we never skip past a corner
	# (the #1 cause of wall clipping at high speed). Speed ramps from 100%
	# at `DECEL_RAMP_STEPS × step` away down to `MIN_SPEED_RATIO × speed`
	# right at the waypoint.
	var distance_ratio := waypoint_distance / maxf(base_step * DECEL_RAMP_STEPS, 0.001)
	var speed_ratio := MIN_SPEED_RATIO + (1.0 - MIN_SPEED_RATIO) * clampf(distance_ratio, 0.0, 1.0)
	var effective_step := base_step * speed_ratio
	
	# Determine alignment for cardinal movement
	var x_aligned := absf(to_waypoint.x) <= BASE_ALIGN_TOLERANCE
	var y_aligned := absf(to_waypoint.y) <= BASE_ALIGN_TOLERANCE
	
	# Choose cardinal movement direction with persistent axis locking.
	# Once an axis is chosen, it stays locked until aligned to prevent
	# per-frame oscillation between axes when distances are similar.
	var move_dir := Vector2.ZERO
	if x_aligned and y_aligned:
		# Fully aligned with current target; nav agent will advance next frame
		_locked_axis = 0
		move_dir = Vector2.ZERO
	elif x_aligned:
		# X is done, must move on Y
		_locked_axis = 2
		move_dir = Vector2(0.0, signf(to_waypoint.y))
	elif y_aligned:
		# Y is done, must move on X
		_locked_axis = 1
		move_dir = Vector2(signf(to_waypoint.x), 0.0)
	else:
		# Both axes need travel — use persistent lock to avoid jitter
		match _locked_axis:
			1:
				# Locked to X-axis
				move_dir = Vector2(signf(to_waypoint.x), 0.0)
			2:
				# Locked to Y-axis
				move_dir = Vector2(0.0, signf(to_waypoint.y))
			_:
				# No lock yet — choose dominant axis and commit
				if absf(to_waypoint.x) >= absf(to_waypoint.y):
					_locked_axis = 1
					move_dir = Vector2(signf(to_waypoint.x), 0.0)
				else:
					_locked_axis = 2
					move_dir = Vector2(0.0, signf(to_waypoint.y))
	
	# ** Overshoot clamp ** — never move farther on the active axis than the
	# remaining distance to the waypoint. This guarantees the arrow lands
	# exactly on the corner instead of skipping past it at high speed.
	var movement := move_dir * effective_step
	match _locked_axis:
		1:
			movement.x = signf(movement.x) * minf(absf(movement.x), absf(to_waypoint.x))
		2:
			movement.y = signf(movement.y) * minf(absf(movement.y), absf(to_waypoint.y))
		_:
			pass  # Already at the waypoint; no movement this frame
	
	# Apply movement (CharacterBody2D + move_and_slide for collision safety)
	velocity = movement / delta_time
	move_and_slide()
	
	# Rotate to face movement direction (snaps to 0°, 90°, 180°, -90°)
	if velocity.length_squared() > 0.0:
		rotation = velocity.angle()
	
	# Record path points for drawing
	_record_path_point()

func _record_path_point() -> void:
	var current_pos := global_position
	if _last_recorded_position == Vector2.INF:
		line_2d.add_point(Vector2.ZERO)
		_last_recorded_position = current_pos
		return
	
	var dist_sq := current_pos.distance_squared_to(_last_recorded_position)
	if dist_sq >= min_point_distance * min_point_distance:
		# Store point relative to this node's position so line follows the arrow
		line_2d.add_point(current_pos)
		_last_recorded_position = current_pos
		_update_total_length()

## Recomputes the total arc length of the Line2D and feeds it to the shader.
## This keeps dash sizes fixed in pixels regardless of how long the line grows,
## preventing the "pulsing" caused by Line2D's index-fraction UVs.
func _update_total_length() -> void:
	var pts := line_2d.points
	var len := 0.0
	for i in range(1, pts.size()):
		len += pts[i - 1].distance_to(pts[i])
	var mat := line_2d.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("total_length", len)
