extends Camera2D

## Emitted whenever the target zoom changes (wheel, pinch, buttons, slider,
## or fit). The UI layer listens to keep the zoom slider/label in sync when
## the user zooms via scroll or pinch.
signal zoom_changed(value: float)

## Defines the current camera gesture. A clean state machine (rather than
## branching on raw touch counts) lets us transition between pan and pinch
## without the map jumping when a finger is lifted.
enum GestureMode { NONE, PAN, PINCH }

# --- Mouse (desktop) state ---
var _dragging: bool = false
var _last_mouse_position: Vector2 = Vector2.ZERO

# --- Touch / gesture state ---
var _input_enabled: bool = true
var _gesture_mode: GestureMode = GestureMode.NONE
var _tracked_touches: Dictionary = {} # { index: Vector2 }
## Stable indices of the two touches forming the pinch. Explicitly tracked so
## we never rely on Dictionary insertion order (which can change when a finger
## is lifted mid-pinch and re-placed).
var _touch_a: int = -1
var _touch_b: int = -1
var _last_pinch_distance: float = 0.0

# --- Pan / fling state ---
## Screen-space anchor for anchor-based panning (absolute position deltas).
var _pan_anchor: Vector2 = Vector2.ZERO
var _pan_velocity: Vector2 = Vector2.ZERO
var _fling_velocity: Vector2 = Vector2.ZERO
var _fling_active: bool = false
## Recent (position, time) samples used to estimate the pan velocity for fling.
var _drag_history: Array[Dictionary] = []

# --- Double-tap state ---
var _last_tap_time: float = 0.0
var _last_tap_screen: Vector2 = Vector2.ZERO

const DOUBLE_TAP_MAX_TIME: float = 0.3
const DOUBLE_TAP_MAX_DISTANCE: float = 40.0

var _target_zoom: float = 1.0

@export var drag_sensitivity: float = 1.0
@export var zoom_min: float = 0.2
@export var zoom_max: float = 3.0
@export var zoom_step: float = 0.1
@export var zoom_smoothness: float = 8.0
@export_range(0.5, 2.0, 0.01) var fit_zoom_scale: float = 1.0
@export var double_tap_zoom_enabled: bool = true
## Multiplier applied to the current zoom on a double-tap (typically > 1.0 to
## zoom in). Only used when double_tap_zoom_enabled is true.
@export_range(1.1, 3.0, 0.05) var double_tap_zoom_in_factor: float = 1.5
## Multiplier applied to the current zoom on a double-tap when already at max
## zoom (typically < 1.0 to zoom out instead). Only used when
## double_tap_zoom_enabled is true.
@export_range(0.1, 0.9, 0.05) var double_tap_zoom_out_factor: float = 0.67
@export var fling_enabled: bool = true
@export var fling_decay: float = 6.0
@export var fling_max_speed: float = 3000.0
## Multiplier for proportional pinch zoom. Higher = zoom changes faster with
## the same finger spread. (1/mean_px_per_step tuned for a natural feel.)
@export var pinch_zoom_sensitivity: float = 0.01
## When true, mouse-wheel zoom is anchored to the cursor position like touch
## pinch. When false (default), wheel zoom is anchored to the screen center
## (the original desktop behavior).
@export var wheel_zoom_to_cursor: bool = false

func _process(delta: float) -> void:
	zoom = zoom.lerp(Vector2(_target_zoom, _target_zoom), zoom_smoothness * delta)
	_process_fling(delta)

# --- Zoom API ---------------------------------------------------------------

func _set_target_zoom(value: float) -> void:
	_target_zoom = clampf(value, zoom_min, zoom_max)
	zoom_changed.emit(_target_zoom)

func zoom_in() -> void:
	_set_target_zoom(_target_zoom + zoom_step)

func zoom_out() -> void:
	_set_target_zoom(_target_zoom - zoom_step)

func zoom_to(value: float) -> void:
	_set_target_zoom(value)

func get_zoom_value() -> float:
	return _target_zoom

func get_zoom_min() -> float:
	return zoom_min

func get_zoom_max() -> float:
	return zoom_max

## Changes the target zoom while keeping the world point under `screen_pos`
## fixed on screen (focal-point zoom). This keeps the gesture anchored to the
## fingers (pinch midpoint) or mouse cursor (wheel) instead of the screen
## center, so content doesn't drift away from where the user is zooming.
## NOTE: Uses `_target_zoom` (not the smoothed `zoom`) for the focal math so
## discrete wheel ticks and pinch steps correct position by the full target
## delta without compounding errors from the smoothing lerp.
func _zoom_to_focal(screen_pos: Vector2, new_target_zoom: float) -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		_set_target_zoom(new_target_zoom)
		return
	var old_zoom: float = _target_zoom
	var clamped_new := clampf(new_target_zoom, zoom_min, zoom_max)
	if is_equal_approx(clamped_new, old_zoom):
		return
	var focal_offset := screen_pos - viewport_size * 0.5
	# position moves so the world point under screen_pos stays put:
	#   pos + (s - c)/z_old == pos' + (s - c)/z_new
	position += focal_offset * (1.0 / old_zoom - 1.0 / clamped_new)
	_set_target_zoom(clamped_new)

# --- Fitting -----------------------------------------------------------------

func fit_sprite(sprite: Sprite2D) -> void:
	var texture := sprite.texture
	if texture == null:
		return
	var rect_size: Vector2
	if sprite.region_enabled:
		rect_size = sprite.region_rect.size
	else:
		rect_size = texture.get_size()
	var world_size := rect_size * sprite.scale
	var center_offset := sprite.offset
	if not sprite.centered:
		center_offset += rect_size / 2.0
	var world_center := sprite.position + center_offset * sprite.scale
	var world_rect := Rect2(world_center - world_size / 2.0, world_size)
	fit_rect(world_rect)

func fit_rect(world_rect: Rect2) -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	var fit_zoom: float = minf(viewport_size.x / world_rect.size.x, viewport_size.y / world_rect.size.y)
	_set_target_zoom(fit_zoom * fit_zoom_scale)
	position = world_rect.get_center()

# --- Input control -----------------------------------------------------------

## Enables or disables the camera's own input handling (pan/zoom). The UI
## layer toggles this while a modal is open so scrolling/wheel can't zoom.
func set_input_enabled(enabled: bool) -> void:
	_input_enabled = enabled
	if not _input_enabled:
		_dragging = false
		_reset_gestures()

## Reverts all gesture state to idle. Called when input is disabled.
func _reset_gestures() -> void:
	_gesture_mode = GestureMode.NONE
	_tracked_touches.clear()
	_touch_a = -1
	_touch_b = -1
	_last_pinch_distance = 0.0
	_pan_anchor = Vector2.ZERO
	_pan_velocity = Vector2.ZERO
	_drag_history.clear()
	_fling_velocity = Vector2.ZERO
	_fling_active = false

## True when the given mouse button event is a wheel button (never emulated
## as a touch, so it must be processed directly rather than via the touch
## branch).
func _is_wheel(mb: InputEventMouseButton) -> bool:
	return mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN

func _unhandled_input(event: InputEvent) -> void:
	if not _input_enabled:
		return

	# --- Mouse (desktop) Controls ---
	if event is InputEventMouseButton:
		# On a real touch device (emulate_mouse_from_touch=true) every touch
		# also arrives as a synthesized mouse button event. The touch branch
		# below handles those, so skip the synthesized mouse branch here.
		# On desktop (no touchscreen) the mouse branch handles the drag
		# directly. Wheel zoom always passes since it's never emulated.
		if Input.is_emulating_mouse_from_touch() and DisplayServer.is_touchscreen_available() \
			and not _is_wheel(event as InputEventMouseButton):
			return
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_last_mouse_position = mb.position
				_clear_fling()
			else:
				_dragging = false
		# Wheel zoom: anchored to the cursor when the toggle is enabled,
		# otherwise the classic center-anchored zoom around the screen center.
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if wheel_zoom_to_cursor:
				_zoom_to_focal(mb.position, _target_zoom + zoom_step)
			else:
				_set_target_zoom(_target_zoom + zoom_step)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if wheel_zoom_to_cursor:
				_zoom_to_focal(mb.position, _target_zoom - zoom_step)
			else:
				_set_target_zoom(_target_zoom - zoom_step)
	elif event is InputEventMouseMotion and _dragging:
		# Same de-duplication: synthesized mouse motion on a real touch
		# device is also emitted as a touch drag, so the touch branch handles
		# the pan. Desktop mouse never hits this guard.
		if Input.is_emulating_mouse_from_touch() and DisplayServer.is_touchscreen_available():
			return
		get_viewport().set_input_as_handled()
		var mm := event as InputEventMouseMotion
		var delta: Vector2 = (mm.position - _last_mouse_position) * drag_sensitivity / zoom
		position -= delta
		_last_mouse_position = mm.position

	# --- Touch Controls ---
	elif event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)

# --- Touch gesture handlers ---------------------------------------------------

func _handle_screen_touch(st: InputEventScreenTouch) -> void:
	if st.pressed:
		_tracked_touches[st.index] = st.position
		match _gesture_mode:
			GestureMode.NONE:
				_gesture_mode = GestureMode.PAN
				_pan_anchor = st.position
				_pan_velocity = Vector2.ZERO
				_drag_history.clear()
				_clear_fling()
			GestureMode.PAN:
				# A second finger lands mid-pan → switch to pinch cleanly.
				if _tracked_touches.size() >= 2:
					_begin_pinch()
			_:
				pass
		# Double-tap detection on finger press.
		_handle_double_tap(st)
		get_viewport().set_input_as_handled()
	else:
		_tracked_touches.erase(st.index)
		if _gesture_mode == GestureMode.PINCH:
			# The broken finger-up case: one of two pinch fingers lifted with
			# the other still down. Transition to PAN and re-anchor to the
			# remaining finger so it continues panning WITHOUT a jump.
			_finish_pinch_transition()
		elif _gesture_mode == GestureMode.PAN:
			if _tracked_touches.is_empty():
				_finish_pan()
		get_viewport().set_input_as_handled()

func _handle_screen_drag(sd: InputEventScreenDrag) -> void:
	if not _tracked_touches.has(sd.index):
		return
	_tracked_touches[sd.index] = sd.position

	match _gesture_mode:
		GestureMode.PINCH:
			if _tracked_touches.size() >= 2:
				_update_pinch()
		GestureMode.PAN:
			if _tracked_touches.size() >= 2:
				# Second finger joins mid-pan → pinch.
				_begin_pinch()
			else:
				_update_pan(sd)
		_:
			pass
	get_viewport().set_input_as_handled()

## Stable helper: converts a screen (viewport) position to world coordinates
## using the current camera transform. Used for focal-point math.
func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return position + (screen_pos - get_viewport_rect().size * 0.5) / zoom.x

# --- Pinch -------------------------------------------------------------------

## Enters PINCH mode using the two currently tracked touches. Stores stable
## finger indices and the initial distance/center so subsequent updates are
## order-independent.
func _begin_pinch() -> void:
	var keys := _tracked_touches.keys()
	if keys.size() < 2:
		return
	_touch_a = keys[0]
	_touch_b = keys[1]
	_last_pinch_distance = _tracked_touches[_touch_a].distance_to(_tracked_touches[_touch_b])
	_gesture_mode = GestureMode.PINCH
	_clear_fling()
	_pan_velocity = Vector2.ZERO
	_drag_history.clear()

## Applies proportional pinch zoom anchored to the current pinch midpoint.
## Zoom scales by the ratio of finger distance (not an absolute delta), so it
## feels natural at any zoom level, and the focal point stays under the fingers.
func _update_pinch() -> void:
	if _touch_a == -1 or _touch_b == -1 or not _tracked_touches.has(_touch_a) or not _tracked_touches.has(_touch_b):
		_begin_pinch()
		return
	var dist_a: Vector2 = _tracked_touches[_touch_a]
	var dist_b: Vector2 = _tracked_touches[_touch_b]
	var current_distance := dist_a.distance_to(dist_b)
	var center := (dist_a + dist_b) * 0.5

	if _last_pinch_distance > 0.0:
		var ratio := current_distance / _last_pinch_distance
		var new_zoom := _target_zoom * ratio
		# Sensitivity: 1.0 = fully proportional; exp gives a gentler feel.
		new_zoom = _target_zoom * exp((log(ratio)) * _sensitivity_scale())
		_zoom_to_focal(center, new_zoom)

	_last_pinch_distance = current_distance

## Returns a per-step multiplier so the pinch feels similar across zoom
## ranges. Cheap approximation: lower sensitivity at high zoom, higher at low.
func _sensitivity_scale() -> float:
	return clampf(1.0 / maxf(0.1, _target_zoom), 0.5, 2.0) * pinch_zoom_sensitivity * 100.0

## Transition from PINCH to PAN when one of two fingers is lifted. Re-anchors
## the pan to the remaining finger so the very next drag doesn't jump.
func _finish_pinch_transition() -> void:
	_gesture_mode = GestureMode.PAN
	_last_pinch_distance = 0.0
	_touch_a = -1
	_touch_b = -1
	_pan_velocity = Vector2.ZERO
	_drag_history.clear()
	if _tracked_touches.is_empty():
		_gesture_mode = GestureMode.NONE
		return
	# Anchor to the remaining finger's current screen position → zero movement
	# on the first post-transition drag.
	var remaining_keys := _tracked_touches.keys()
	_pan_anchor = _tracked_touches[remaining_keys[0]]

# --- Pan / fling -------------------------------------------------------------

func _update_pan(sd: InputEventScreenDrag) -> void:
	# Anchor-based panning: uses absolute position delta from anchor, so a
	# transition re-anchor cleanly zeroes out any leftover movement.
	var delta := (sd.position - _pan_anchor) * drag_sensitivity / zoom
	position -= delta
	_pan_anchor = sd.position
	_record_velocity(sd)

## Samples recent drag positions with timestamps to estimate a smooth pan
## velocity, used for fling inertia on release.
func _record_velocity(sd: InputEventScreenDrag) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_drag_history.append({"pos": sd.position, "time": now})
	# Keep only the last ~0.1s of samples.
	while _drag_history.size() > 2 and now - _drag_history[0]["time"] > 0.1:
		_drag_history.pop_front()
	if _drag_history.size() < 2:
		_pan_velocity = Vector2.ZERO
		return
	var newest: Dictionary = _drag_history[_drag_history.size() - 1]
	var oldest: Dictionary = _drag_history[0]
	var dt: float = newest["time"] - oldest["time"]
	if dt > 0.0:
		_pan_velocity = ((newest["pos"] as Vector2) - (oldest["pos"] as Vector2)) / dt

## Called when a one-finger pan ends (finger lifted). Hands velocity to the
## fling system if fling is enabled and the user was moving fast enough.
func _finish_pan() -> void:
	if fling_enabled and _pan_velocity.length() > 100.0:
		_fling_velocity = _pan_velocity.limit_length(fling_max_speed)
		_fling_active = true
	_pan_velocity = Vector2.ZERO
	_drag_history.clear()
	_gesture_mode = GestureMode.NONE

## Applies decaying fling momentum each frame.
func _process_fling(delta: float) -> void:
	if not _fling_active:
		return
	if _fling_velocity.length() < 5.0:
		_fling_velocity = Vector2.ZERO
		_fling_active = false
		return
	position -= _fling_velocity * delta / zoom
	_fling_velocity = _fling_velocity.lerp(Vector2.ZERO, fling_decay * delta)

## Stops any in-progress fling (called when the user touches or drags again).
func _clear_fling() -> void:
	_fling_velocity = Vector2.ZERO
	_fling_active = false

# --- Double tap --------------------------------------------------------------

## Detects a double-tap (two taps within time/distance thresholds) and zooms
## in around the tap point; if already at max zoom, zoom out instead.
func _handle_double_tap(st: InputEventScreenTouch) -> void:
	if not double_tap_zoom_enabled:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var time_since_tap := now - _last_tap_time
	var moved := st.position.distance_to(_last_tap_screen) <= DOUBLE_TAP_MAX_DISTANCE
	_last_tap_time = now
	_last_tap_screen = st.position

	if time_since_tap > 0.0 and time_since_tap <= DOUBLE_TAP_MAX_TIME and moved:
		if _target_zoom >= zoom_max * 0.999:
			_zoom_to_focal(st.position, _target_zoom * double_tap_zoom_out_factor)
		else:
			_zoom_to_focal(st.position, _target_zoom * double_tap_zoom_in_factor)
