extends RigidBody2D

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

var _last_recorded_position: Vector2 = Vector2.INF

func _ready() -> void:
	_last_recorded_position = global_position
	refresh_targets()

## Refreshes the cached exit and assembly target lists from scene groups.
## Call this after dynamically loading a new map so the agent can find new targets.
func refresh_targets() -> void:
	exits = get_tree().get_nodes_in_group("Exits").filter(func(n): return is_instance_valid(n))
	assemblies = get_tree().get_nodes_in_group("Assembly").filter(func(n): return is_instance_valid(n))
	# Reset navigation state since targets have changed
	_nav_state = NavState.SEEKING_EXIT
	navigation_agent_2d.target_position = Vector2.ZERO

func teleport_to(new_position: Vector2) -> void:
	# Clear the drawn path
	line_2d.clear_points()
	_last_recorded_position = new_position
	
	# Reset navigation state to start fresh
	_nav_state = NavState.SEEKING_EXIT
	
	# Reset physics state for clean RigidBody2D teleport
	linear_velocity = Vector2.ZERO
	angular_velocity = 0.0
	
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
			
			# Verify candidate is truly on the navmesh (strict check)
			var closest_to_candidate := NavigationServer2D.map_get_closest_point(map, candidate_node.global_position)
			var reach_tolerance := navigation_agent_2d.radius + 2.0
			if closest_to_candidate.distance_squared_to(candidate_node.global_position) > reach_tolerance * reach_tolerance:
				continue
			
			# Compute actual navigable path to this candidate
			var path := NavigationServer2D.map_get_path(
				map,
				global_position,
				candidate_node.global_position,
				true  # optimize: true for shortest path
			)
			
			# Skip unreachable candidates (empty path or only start point)
			if path.size() < 2:
				continue
			
			# Verify the path endpoint actually reaches near the candidate
			var path_endpoint := path[path.size() - 1]
			if path_endpoint.distance_squared_to(candidate_node.global_position) > reach_tolerance * reach_tolerance:
				continue
			
			# Calculate total path length
			var path_length: float = 0.0
			for i in range(path.size() - 1):
				path_length += path[i].distance_to(path[i + 1])
			if path_length < best_path_length:
				best_path_length = path_length
				best_target = candidate_node
	
	return best_target

func _physics_process(_delta: float) -> void:
	var map := navigation_agent_2d.get_navigation_map()
	if not map.is_valid():
		linear_velocity = Vector2.ZERO
		return
	
	match _nav_state:
		NavState.SEEKING_EXIT:
			if exits.is_empty():
				linear_velocity = Vector2.ZERO
				return
			
			var best_exit := _find_nearest_reachable_target(exits)
			if best_exit == null:
				linear_velocity = Vector2.ZERO
				return
			
			# Update target if changed or not yet set
			if navigation_agent_2d.target_position != best_exit.global_position:
				navigation_agent_2d.target_position = best_exit.global_position
			
			# Check if navigation is complete (arrived at exit)
			if navigation_agent_2d.is_navigation_finished():
				_nav_state = NavState.SEEKING_ASSEMBLY
				# Fall through to assembly seeking in same frame
				_handle_assembly_seeking()
				return
			
			_move_toward_target()
		
		NavState.SEEKING_ASSEMBLY:
			_handle_assembly_seeking()

func _handle_assembly_seeking() -> void:
	if assemblies.is_empty():
		linear_velocity = Vector2.ZERO
		return
	
	var best_assembly := _find_nearest_reachable_target(assemblies)
	if best_assembly == null:
		linear_velocity = Vector2.ZERO
		return
	
	# Update target if changed or not yet set
	if navigation_agent_2d.target_position != best_assembly.global_position:
		navigation_agent_2d.target_position = best_assembly.global_position
	
	# Check if navigation is complete (arrived at assembly)
	if navigation_agent_2d.is_navigation_finished():
		linear_velocity = Vector2.ZERO
		return
	
	_move_toward_target()

func _move_toward_target() -> void:
	# Get next path position from navigation agent
	var next_path_position := navigation_agent_2d.get_next_path_position()
	var nav_direction := (next_path_position - global_position).normalized()
	
	linear_velocity = nav_direction * speed
	
	# Rotate to face movement direction
	if linear_velocity.length_squared() > 0.0:
		rotation = linear_velocity.angle()
	
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
