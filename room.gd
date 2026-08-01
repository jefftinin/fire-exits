# room.gd
extends Area2D

class_name Room

@export var room_name: String = "Room"
@export var room_info: String = "This is a room."
@export var room_color: Color = Color(0.5, 0.5, 0.5, 0.3)

# Connection to adjacent rooms (for pathfinding)
@export var connected_rooms: Array[NodePath] = []

# For visual feedback
var is_hovered: bool = false
var default_modulate: Color

signal room_clicked(room: Room)

func _ready():
	default_modulate = modulate
	input_event.connect(_on_input_event)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

func _on_input_event(viewport, event, shape_idx):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			emit_signal("room_clicked", self)

func _on_mouse_entered():
	is_hovered = true
	modulate = Color(1.2, 1.2, 1.2, 1.0)  # Highlight when hovered

func _on_mouse_exited():
	is_hovered = false
	modulate = default_modulate
