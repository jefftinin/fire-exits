extends Area2D

class_name Room
@onready var label: Label = $Label

@export var room_name: String = "Room"
@export var room_info: String = "This is a room."
@export var room_color: Color = Color(0, 0, 0, 0,)

# Connection to adjacent rooms (for pathfinding)
#@export var connected_rooms: Array[NodePath] = []

# For visual feedback
var is_hovered: bool = false
var default_modulate: Color

# Drag detection
var _press_position: Vector2 = Vector2.ZERO
const CLICK_THRESHOLD: float = 10.0  # Max pixels mouse can move to still count as click

signal room_clicked(room: Room)

func _ready():
	default_modulate = modulate
	input_event.connect(_on_input_event)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	label.text = room_name

func _on_input_event(viewport: Viewport, event: InputEvent, shape_idx: int) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_position = event.position
			else:
				# Only emit click if mouse didn't move significantly (not a drag)
				if event.position.distance_to(_press_position) <= CLICK_THRESHOLD:
					emit_signal("room_clicked", self)
					viewport.set_input_as_handled()

func _on_mouse_entered():
	is_hovered = true
	modulate = Color(1.2, 1.2, 1.2, 1.0)  # Highlight when hovered

func _on_mouse_exited():
	is_hovered = false
	modulate = default_modulate
