extends Area2D
class_name FireExitDoor

@export var is_exit: bool = false  # Check this for the final destination
@export var connected_rooms: Array[Area2D] = [] # Drag Room nodes here in Inspector

# Optional: Visual hint
func _ready():
	if is_exit:
		modulate = Color.GREEN # Turn green to indicate safety
	else:
		modulate = Color.WHITE
