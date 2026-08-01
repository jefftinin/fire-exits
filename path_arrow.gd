extends RigidBody2D

@onready var navigation_agent_2d: NavigationAgent2D = $NavigationAgent2D

@export var speed: float = 500.0

func _physics_process(_delta: float) -> void:
	var exits := get_tree().get_nodes_in_group("Exits")
	
	if exits.is_empty():
		linear_velocity = Vector2.ZERO
		return
	
	var nearest_exit: Node2D = null
	var min_dist_sq: float = INF
	
	for exit in exits:
		if exit is Node2D:
			var dist_sq := global_position.distance_squared_to((exit as Node2D).global_position)
			if dist_sq < min_dist_sq:
				min_dist_sq = dist_sq
				nearest_exit = exit as Node2D
	
	if nearest_exit == null:
		linear_velocity = Vector2.ZERO
		return
	
	# Update target if changed or not yet set
	if navigation_agent_2d.target_position != nearest_exit.global_position:
		navigation_agent_2d.target_position = nearest_exit.global_position
	
	# Check if navigation is complete (arrived at target)
	if navigation_agent_2d.is_navigation_finished():
		linear_velocity = Vector2.ZERO
		return
	
	# Get next path position from navigation agent
	var next_path_position := navigation_agent_2d.get_next_path_position()
	var direction := (next_path_position - global_position).normalized()
	linear_velocity = direction * speed
	
	# Rotate to face movement direction
	if linear_velocity.length_squared() > 0.0:
		rotation = linear_velocity.angle()
