extends Area2D

class_name Room

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
const CLICK_THRESHOLD: float = 10.0  # Max pixels mouse/touch can move to still count as click

# Touch hover tracking
var _touching: bool = false

signal room_clicked(room: Room, click_position: Vector2)

func _ready():
	default_modulate = modulate
	input_event.connect(_on_input_event)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

func _on_input_event(viewport: Viewport, event: InputEvent, _shape_idx: int) -> void:
	# Mouse click handling
	# On mobile web (emulate_mouse_from_touch=true) a single tap arrives as a
	# synthesized mouse button event, so this branch fires room_clicked directly
	# — no DisplayServer touch checks (unreliable on HTML5). Desktop mouse is
	# handled identically.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press_position = mb.position
			else:
				# Only emit click if mouse didn't move significantly (not a drag)
				if mb.position.distance_to(_press_position) <= CLICK_THRESHOLD:
					emit_signal("room_clicked", self, mb.position)
					viewport.set_input_as_handled()
	
	# Touch handling
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_press_position = st.position
			# Highlight when touched
			if not _touching:
				_touching = true
				modulate = Color(1.2, 1.2, 1.2, 1.0)
		else:
			# Only emit click if touch didn't move significantly (not a drag/swipe).
			# When emulate_mouse_from_touch is on, the synthesized mouse click
			# above already emitted room_clicked — skip to avoid double-firing.
			if st.position.distance_to(_press_position) <= CLICK_THRESHOLD \
				and not Input.is_emulating_mouse_from_touch():
				emit_signal("room_clicked", self, st.position)
				viewport.set_input_as_handled()
			# Remove highlight on touch release
			_touching = false
			modulate = default_modulate

func _on_mouse_entered():
	is_hovered = true
	modulate = Color(1.2, 1.2, 1.2, 1.0)  # Highlight when hovered

func _on_mouse_exited():
	is_hovered = false
	modulate = default_modulate
