extends Node
class_name GesturesController

## Reference to the owning camera, set in _ready() via get_parent().
var camera: Camera2D = null
## Reference to the sibling ZoomController, wired in _ready().
var zoom_controller: ZoomController = null
## Reference to the sibling Fitter, wired in _ready() so gestures cancel
## in-flight position glides.
var fitter: Fitter = null

## Defines the current camera gesture state machine.
enum GestureMode { NONE, PAN, PINCH }

# --- Mouse (desktop) state ---
var _dragging: bool = false
var _last_mouse_position: Vector2 = Vector2.ZERO

# --- Touch / gesture state ---
var _input_enabled: bool = true
var _gesture_mode: GestureMode = GestureMode.NONE
var _tracked_touches: Dictionary = {} # { index: Vector2 }
## Stable indices of the two touches forming the pinch.
var _touch_a: int = -1
var _touch_b: int = -1
var _last_pinch_distance: float = 0.0

# --- Pan / fling state ---
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

@export var drag_sensitivity: float = 1.0
@export var fling_enabled: bool = true
@export var fling_decay: float = 6.0
@export var fling_max_speed: float = 3000.0
@export var double_tap_zoom_enabled: bool = true
## Multiplier applied to the current zoom on a double-tap (typically > 1.0 to
## zoom in). Only used when double_tap_zoom_enabled is true.
@export_range(1.1, 3.0, 0.05) var double_tap_zoom_in_factor: float = 1.5
## Multiplier applied to the current zoom on a double-tap when already at max
## zoom (typically < 1.0 to zoom out instead).
@export_range(0.1, 0.9, 0.05) var double_tap_zoom_out_factor: float = 0.67
## When true, mouse-wheel zoom is anchored to the cursor position like touch
## pinch. When false (default), wheel zoom is anchored to the screen center.
@export var wheel_zoom_to_cursor: bool = false
@export var zoom_step: float = 0.1

func _ready() -> void:
	camera = get_parent() as Camera2D
	zoom_controller = _get_zoom_controller()
	fitter = _get_fitter()

func _get_zoom_controller() -> ZoomController:
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child is ZoomController:
			return child
	return null

func _get_fitter() -> Fitter:
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child is Fitter:
			return child
	return null

## Enables or disables the camera's own input handling (pan/zoom). The UI
## layer toggles this while a modal is open so scrolling/wheel can't zoom.
func set_input_enabled(enabled: bool) -> void:
	_input_enabled = enabled
	if not _input_enabled:
		_dragging = false
		_reset_gestures()

## Reverts all gesture state to idle.
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

## True when the given mouse button event is a wheel button.
func _is_wheel(mb: InputEventMouseButton) -> bool:
	return mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN

func unhandled_input(event: InputEvent) -> void:
	if not _input_enabled or camera == null or zoom_controller == null:
		return

	# --- Mouse (desktop) Controls ---
	if event is InputEventMouseButton:
		# On a touch device (emulate_mouse_from_touch=true) every touch also
		# arrives as a synthesized mouse button event. The touch branch below
		# handles those, so skip the synthesized mouse branch here.
		if Input.is_emulating_mouse_from_touch() \
			and not _is_wheel(event as InputEventMouseButton):
			return
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_cancel_interp()
				_dragging = true
				_last_mouse_position = mb.position
				_clear_fling()
			else:
				_dragging = false
		# Wheel zoom: anchored to the cursor when the toggle is enabled.
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if wheel_zoom_to_cursor:
				zoom_controller.zoom_to_focal(mb.position, zoom_controller.get_target_zoom() + zoom_step)
			else:
				_cancel_interp()
				zoom_controller.set_target_zoom(zoom_controller.get_target_zoom() + zoom_step)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if wheel_zoom_to_cursor:
				zoom_controller.zoom_to_focal(mb.position, zoom_controller.get_target_zoom() - zoom_step)
			else:
				_cancel_interp()
				zoom_controller.set_target_zoom(zoom_controller.get_target_zoom() - zoom_step)
	elif event is InputEventMouseMotion and _dragging:
		# Same de-duplication: synthesized mouse motion on a touch device is
		# also emitted as a touch drag, so the touch branch handles the pan.
		if Input.is_emulating_mouse_from_touch():
			return
		get_viewport().set_input_as_handled()
		var mm := event as InputEventMouseMotion
		var delta: Vector2 = (mm.position - _last_mouse_position) * drag_sensitivity / camera.zoom
		camera.position -= delta
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
				_cancel_interp()
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

# --- Pinch -------------------------------------------------------------------

## Enters PINCH mode using the two currently tracked touches.
func _begin_pinch() -> void:
	var keys := _tracked_touches.keys()
	if keys.size() < 2:
		return
	_cancel_interp()
	_touch_a = keys[0]
	_touch_b = keys[1]
	_last_pinch_distance = _tracked_touches[_touch_a].distance_to(_tracked_touches[_touch_b])
	_gesture_mode = GestureMode.PINCH
	_clear_fling()
	_pan_velocity = Vector2.ZERO
	_drag_history.clear()

## Applies proportional pinch zoom anchored to the current pinch midpoint.
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
		# Sensitivity: 1.0 = fully proportional; exp gives a gentler feel.
		var new_zoom := zoom_controller.get_target_zoom() * exp((log(ratio)) * zoom_controller.sensitivity_scale())
		zoom_controller.zoom_to_focal(center, new_zoom)

	_last_pinch_distance = current_distance

## Transition from PINCH to PAN when one of two fingers is lifted.
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
	if camera == null:
		return
	# Anchor-based panning: uses absolute position delta from anchor.
	var delta := (sd.position - _pan_anchor) * drag_sensitivity / camera.zoom
	camera.position -= delta
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

## Called when a one-finger pan ends. Hands velocity to the fling system.
func _finish_pan() -> void:
	if camera == null:
		return
	if fling_enabled and _pan_velocity.length() > 100.0:
		_fling_velocity = _pan_velocity.limit_length(fling_max_speed)
		_fling_active = true
	_pan_velocity = Vector2.ZERO
	_drag_history.clear()
	_gesture_mode = GestureMode.NONE

## Applies decaying fling momentum each frame.
func process_fling(delta: float) -> void:
	if camera == null:
		return
	if not _fling_active:
		return
	if _fling_velocity.length() < 5.0:
		_fling_velocity = Vector2.ZERO
		_fling_active = false
		return
	camera.position -= _fling_velocity * delta / camera.zoom
	_fling_velocity = _fling_velocity.lerp(Vector2.ZERO, fling_decay * delta)

## Stops any in-progress fling.
func _clear_fling() -> void:
	_fling_velocity = Vector2.ZERO
	_fling_active = false

# --- Double tap --------------------------------------------------------------

## Detects a double-tap and zooms in around the tap point; if already at max
## zoom, zoom out instead.
func _handle_double_tap(st: InputEventScreenTouch) -> void:
	if not double_tap_zoom_enabled or zoom_controller == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var time_since_tap := now - _last_tap_time
	var moved := st.position.distance_to(_last_tap_screen) <= DOUBLE_TAP_MAX_DISTANCE
	_last_tap_time = now
	_last_tap_screen = st.position

	if time_since_tap > 0.0 and time_since_tap <= DOUBLE_TAP_MAX_TIME and moved:
		if zoom_controller.get_target_zoom() >= zoom_controller.get_zoom_max() * 0.999:
			zoom_controller.zoom_to_focal(st.position, zoom_controller.get_target_zoom() * double_tap_zoom_out_factor)
		else:
			zoom_controller.zoom_to_focal(st.position, zoom_controller.get_target_zoom() * double_tap_zoom_in_factor)

## Cancels in-flight position interpolation (via Fitter).
func _cancel_interp() -> void:
	if fitter != null:
		fitter.cancel_interp()