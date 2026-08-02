extends Camera2D

var _dragging: bool = false
var _last_mouse_position: Vector2 = Vector2.ZERO
var _target_zoom: float = 1.0

# Touch handling
var _active_touches: Dictionary = {} # { index: position }
var _last_pinch_distance: float = 0.0

@export var drag_sensitivity: float = 1.0
@export var zoom_min: float = 0.2
@export var zoom_max: float = 3.0
@export var zoom_step: float = 0.1
@export var zoom_smoothness: float = 8.0

func _process(delta: float) -> void:
	zoom = zoom.lerp(Vector2(_target_zoom, _target_zoom), zoom_smoothness * delta)

func _unhandled_input(event: InputEvent) -> void:
	# Mouse Controls
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_last_mouse_position = mb.position
			else:
				_dragging = false
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_zoom = clampf(_target_zoom + zoom_step, zoom_min, zoom_max)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_zoom = clampf(_target_zoom - zoom_step, zoom_min, zoom_max)
	elif event is InputEventMouseMotion and _dragging:
		get_viewport().set_input_as_handled()
		var mm := event as InputEventMouseMotion
		var delta: Vector2 = (mm.position - _last_mouse_position) * drag_sensitivity / zoom
		position -= delta
		_last_mouse_position = mm.position
	
	# Touch Controls
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_active_touches[st.index] = st.position
			if _active_touches.size() == 2:
				var points := _active_touches.values()
				_last_pinch_distance = (points[0] as Vector2).distance_to(points[1] as Vector2)
		else:
			_active_touches.erase(st.index)
			# Reset pinch distance immediately when finger is lifted to prevent jumping
			_last_pinch_distance = 0.0
			
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if not _active_touches.has(sd.index):
			return
			
		_active_touches[sd.index] = sd.position
		get_viewport().set_input_as_handled()
		
		# Pinch Zoom (2 fingers)
		if _active_touches.size() == 2:
			var points := _active_touches.values()
			var current_distance: float = (points[0] as Vector2).distance_to(points[1] as Vector2)
			
			if _last_pinch_distance > 0.0:
				var pinch_delta: float = current_distance - _last_pinch_distance
				# Sensitivity multiplier for pinch zoom
				var zoom_change: float = pinch_delta * 0.005 
				_target_zoom = clampf(_target_zoom + zoom_change, zoom_min, zoom_max)
				
			_last_pinch_distance = current_distance
			
		# Single Finger Pan
		elif _active_touches.size() == 1:
			var delta: Vector2 = sd.relative * drag_sensitivity / zoom
			position -= delta
			
