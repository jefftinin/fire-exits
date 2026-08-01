extends Camera2D

var active_touches := {}
var is_pinching := false
var last_pinch_distance := 0.0
var pan_start_pos := Vector2()
var camera_start_pos := Vector2()
var drag_threshold := 10.0
var is_dragging := false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			active_touches[event.index] = event.position
			if active_touches.size() == 1:
				pan_start_pos = event.position
				camera_start_pos = position
			elif active_touches.size() == 2:
				is_pinching = true
				last_pinch_distance = _get_pinch_distance()
		else:
			active_touches.erase(event.index)
			if active_touches.size() < 2:
				is_pinching = false
			if active_touches.size() == 1:
				var remaining_key = active_touches.keys()[0]
				pan_start_pos = active_touches[remaining_key]
				camera_start_pos = position
				is_dragging = false
			elif active_touches.is_empty():
				is_pinching = false
				is_dragging = false

	elif event is InputEventMouseButton:
		if event.pressed:
			var zoom_factor := 0.1
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				zoom = Vector2(clamp(zoom.x + zoom_factor, 0.5, 2.0), clamp(zoom.y + zoom_factor, 0.5, 2.0))
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				zoom = Vector2(clamp(zoom.x - zoom_factor, 0.5, 2.0), clamp(zoom.y - zoom_factor, 0.5, 2.0))

	elif event is InputEventScreenDrag:
		active_touches[event.index] = event.position

		if not is_pinching and active_touches.size() == 1:
			if not is_dragging:
				if event.position.distance_to(pan_start_pos) > drag_threshold:
					is_dragging = true
			if is_dragging:
				position -= event.relative / zoom
				get_viewport().set_input_as_handled()
			return

		if is_pinching and active_touches.size() >= 2:
			var current_distance = _get_pinch_distance()
			var delta = current_distance - last_pinch_distance
			var zoom_factor = delta * 0.005
			var new_zoom = clamp(zoom.x + zoom_factor, 0.5, 2.0)
			zoom = Vector2(new_zoom, new_zoom)
			last_pinch_distance = current_distance

func _get_pinch_distance() -> float:
	var keys = active_touches.keys()
	if keys.size() < 2:
		return 0.0
	var p1 = active_touches[keys[0]]
	var p2 = active_touches[keys[1]]
	return p1.distance_to(p2)

func _ready() -> void:
	pass

func _process(delta: float) -> void:
	pass
