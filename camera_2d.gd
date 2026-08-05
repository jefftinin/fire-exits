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
## Lower zoom floor used when the viewport is taller than wide (portrait, e.g.
## phones). Lets the camera zoom out further so the full map fits on narrow
## screens. Landscape/desktop keep the regular `zoom_min`.
@export var portrait_zoom_min: float = 0.05
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

## When true, clamps the camera position so the visible world area stays
## within the limits rect (set via `set_limits` or `manual_limits_rect`).
## Useful to keep the view contained within a map sprite's bounds.
@export var limits_enabled: bool = false

## Extra margin (world px) added around the limits rect on each side. Positive
## values expand the clamped area (allow panning a bit past the map's edges),
## negative values inset it (tighter clamp). Editable in the inspector.
@export var limits_margin: Vector2 = Vector2.ZERO

## Optional rect used directly as the camera limits. If non-zero, this takes
## precedence over the rect passed to `set_limits()` (which is normally the
## map sprite's bounds). Lets you define custom clamp bounds in the editor
## without touching the map sprite.
@export var manual_limits_rect: Rect2 = Rect2()

## When true, zooming out cannot exceed the limits rect: the camera's minimum
## zoom becomes the largest zoom that still fits the viewport entirely inside
## the limits on both axes. At that minimum the camera is pinned to center
## (no slack to pan). When false (default), the camera can zoom out all the
## way to `zoom_min` and empty space shows past the map edges on any axis
## where the viewport is larger than the limits rect.
@export var limit_zoom_to_limits: bool = false

## When true (default), programmatic fits (`fit_rect`, and therefore every new
## path point, navigation, and map-load fit) glide the camera position toward
## the new center instead of snapping. User gestures (pan/pinch/wheel/zoom
## buttons/slider) immediately cancel this interpolation and take control.
## When false, fits snap instantly (the original behavior).
@export var smooth_position_fit: bool = true

## Speed of the position glide when `smooth_position_fit` is on. Matches the
## zoom lerp feel (higher = snappier).
@export var position_smoothness: float = 8.0

## World-space rect the camera is clamped inside while limits_enabled is true.
var _limits_rect: Rect2 = Rect2()

# --- Position interpolation state ---
## Target world position the camera glides toward while interpolation is
## armed. Updated by `fit_rect`; cleared on any user gesture takeover.
var _target_position: Vector2 = Vector2.ZERO
## True while the camera is gliding toward `_target_position`. Disabled the
## moment the user pans/zooms, re-armed on the next `fit_rect`.
var _position_interp_active: bool = false

func _process(delta: float) -> void:
	zoom = zoom.lerp(Vector2(_target_zoom, _target_zoom), zoom_smoothness * delta)
	_process_glide(delta)
	_process_fling(delta)
	_apply_limits()

## Glides the camera position toward `_target_position` when armed. Stops once
## essentially there (keeps tiny floating-point jitter from running forever).
func _process_glide(delta: float) -> void:
	if not _position_interp_active:
		return
	position = position.lerp(_target_position, position_smoothness * delta)
	if position.distance_to(_target_position) < 0.01:
		position = _target_position
		_position_interp_active = false

## Disarms position interpolation (user gesture takeover). The camera snaps to
## full user control; the next `fit_rect` re-arms the glide.
func _cancel_interp() -> void:
	_position_interp_active = false

# --- Zoom API ---------------------------------------------------------------

## Returns the lowest zoom allowed given the current viewport orientation:
## `portrait_zoom_min` when the viewport is taller than wide, otherwise the
## regular `zoom_min` (landscape/desktop floor).
func _get_allowed_min_zoom() -> float:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return zoom_min
	if viewport_size.y > viewport_size.x:
		return portrait_zoom_min
	return zoom_min

func _set_target_zoom(value: float) -> void:
	_target_zoom = clampf(value, _get_allowed_min_zoom(), zoom_max)
	zoom_changed.emit(_target_zoom)

## Sets the target zoom for programmatic fits (`fit_rect`, `fit_sprite*`).
## Unlike `_set_target_zoom`, this is NOT clamped by the user-facing zoom-out
## floor (`_get_allowed_min_zoom`), so fits can always zoom out far enough to
## show the whole rect regardless of screen size/orientation. Only a tiny
## safety floor and `zoom_max` cap apply.
func _set_fit_zoom(value: float) -> void:
	_target_zoom = clampf(value, 0.01, zoom_max)
	zoom_changed.emit(_target_zoom)

func zoom_in() -> void:
	_cancel_interp()
	_set_target_zoom(_target_zoom + zoom_step)

func zoom_out() -> void:
	_cancel_interp()
	_set_target_zoom(_target_zoom - zoom_step)

func zoom_to(value: float) -> void:
	_cancel_interp()
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
	_cancel_interp()
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		_set_target_zoom(new_target_zoom)
		return
	var old_zoom: float = _target_zoom
	var clamped_new := clampf(new_target_zoom, _get_allowed_min_zoom(), zoom_max)
	if is_equal_approx(clamped_new, old_zoom):
		return
	var focal_offset := screen_pos - viewport_size * 0.5
	# position moves so the world point under screen_pos stays put:
	#   pos + (s - c)/z_old == pos' + (s - c)/z_new
	position += focal_offset * (1.0 / old_zoom - 1.0 / clamped_new)
	_set_target_zoom(clamped_new)

# --- Fitting -----------------------------------------------------------------

## Local-space rect of a Sprite2D in the sprite's own (pre-transform) frame,
## accounting for its texture size, region cropping, centered flag, and offset.
## The sprite's transform (position/rotation/scale) is NOT yet applied — callers
## transform this by `sprite.global_transform` (or use get_sprite_world_rect).
func _get_sprite_local_rect(sprite: Sprite2D) -> Rect2:
	var texture := sprite.texture
	if texture == null:
		return Rect2()
	var rect_size: Vector2
	if sprite.region_enabled:
		rect_size = sprite.region_rect.size
	else:
		rect_size = texture.get_size()
	var offset := sprite.offset
	if not sprite.centered:
		offset += rect_size / 2.0
	return Rect2(offset - rect_size / 2.0, rect_size)

## Transforms the 4 corners of `rect` by `xform` and returns the min/max
## axis-aligned rect. Correct for rotation and non-uniform scale.
func _transform_rect(rect: Rect2, xform: Transform2D) -> Rect2:
	var bounds := Rect2(xform * rect.position, Vector2.ZERO)
	bounds = bounds.expand(xform * (rect.position + Vector2(rect.size.x, 0.0)))
	bounds = bounds.expand(xform * (rect.position + Vector2(rect.size.x, rect.size.y)))
	bounds = bounds.expand(xform * (rect.position + Vector2(0.0, rect.size.y)))
	return bounds

## Returns the world-space rect occupied by `sprite`, accounting for its
## texture, region cropping, offset, scale, and centered setting. Correct for
## nested sprites (uses the sprite's global transform).
func get_sprite_world_rect(sprite: Sprite2D) -> Rect2:
	return _transform_rect(_get_sprite_local_rect(sprite), sprite.global_transform)

## Returns the world-space visual bounds of `node` plus all of its descendants
## by merging applicable node types recursively:
##   - Sprite2D  → texture/region rect via its global transform
##   - Control   → its global rect (e.g. Labels, TextureRects)
##   - Polygon2D → its AABB via its global transform
## Returns an empty Rect2 when no visual bounds are found.
func _get_node_world_bounds(node: Node) -> Rect2:
	var bounds := Rect2()
	var has_bounds := false
	if node is Sprite2D:
		var sprite := node as Sprite2D
		bounds = _transform_rect(_get_sprite_local_rect(sprite), sprite.global_transform)
		has_bounds = true
	elif node is Control:
		var control := node as Control
		bounds = control.get_global_rect()
		has_bounds = true
	elif node is Polygon2D:
		var polygon := node as Polygon2D
		var points: PackedVector2Array = polygon.polygon
		if points.size() > 0:
			var aabb := Rect2(points[0], Vector2.ZERO)
			for i in range(1, points.size()):
				aabb = aabb.expand(points[i])
			aabb.position += polygon.offset
			bounds = _transform_rect(aabb, polygon.global_transform)
			has_bounds = true
	for child in node.get_children():
		var child_bounds := _get_node_world_bounds(child)
		if child_bounds.size.x > 0.0 or child_bounds.size.y > 0.0:
			if has_bounds:
				bounds = bounds.merge(child_bounds)
			else:
				bounds = child_bounds
				has_bounds = true
	return bounds if has_bounds else Rect2()

## Returns the combined world-space bounds of `sprite` and all of its
## descendants (e.g. overlay labels that extend past the texture), so camera
## limits/fits keep every visual child fully in view.
func get_sprite_bounds_including_children(sprite: Sprite2D) -> Rect2:
	var bounds := get_sprite_world_rect(sprite)
	for child in sprite.get_children():
		var child_bounds := _get_node_world_bounds(child)
		if child_bounds.size.x > 0.0 or child_bounds.size.y > 0.0:
			bounds = bounds.merge(child_bounds)
	return bounds

func fit_sprite(sprite: Sprite2D) -> void:
	var texture := sprite.texture
	if texture == null:
		return
	fit_rect(get_sprite_world_rect(sprite))

## Fits the camera to the sprite's bounds including its descendants, so
## overlay labels and other children are kept fully in view.
func fit_sprite_including_children(sprite: Sprite2D) -> void:
	if sprite.texture == null:
		return
	fit_rect(get_sprite_bounds_including_children(sprite))

## Enables position limits, clamping the camera so its visible world-rect
## stays within `rect`. Call `clear_limits()` to release the clamp.
func set_limits(rect: Rect2) -> void:
	_limits_rect = rect
	limits_enabled = true
	_apply_limits()

## Disables camera position limits (previously set via `set_limits`).
func clear_limits() -> void:
	limits_enabled = false
	_limits_rect = Rect2()

## Returns the rect the camera is clamped inside: `manual_limits_rect` when
## non-zero, otherwise the rect passed to `set_limits()` (e.g. the map sprite
## bounds), then scaled by `limits_margin`.
func _get_effective_limits_rect() -> Rect2:
	var effective := _limits_rect
	if manual_limits_rect.size.x != 0.0 or manual_limits_rect.size.y != 0.0:
		effective = manual_limits_rect
	# Expand/shrink on each side by the margin (negative insets the clamp).
	return Rect2(
		effective.position - limits_margin,
		effective.size + limits_margin * 2.0
	)

## Returns the smallest zoom at which the viewport still fits entirely inside
## `rect` on both axes. Used when `limit_zoom_to_limits` is enabled so the
## camera can never zoom out past the limits (which would otherwise reveal
## empty space around the map edges). Falls back to `zoom_min` on degenerate
## sizes.
func _get_limits_min_zoom(rect: Rect2) -> float:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return _get_allowed_min_zoom()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return _get_allowed_min_zoom()
	return maxf(viewport_size.x / rect.size.x, viewport_size.y / rect.size.y)

## Clamps `position` so the camera's visible viewport stays within the limits
## rect. If the viewport is larger than the limits rect on an axis, that axis
## is centered on the rect (so the camera can't show empty space past the map
## edges).
func _apply_limits() -> void:
	if not limits_enabled:
		return
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var effective_rect := _get_effective_limits_rect()
	if effective_rect.size.x <= 0.0 or effective_rect.size.y <= 0.0:
		return
	# When the toggle is on, keep the target zoom from going further out than
	# the viewport fitting inside the limits. `_set_target_zoom` fires the
	# `zoom_changed` signal so the UI slider/label stay in sync automatically.
	if limit_zoom_to_limits and _target_zoom < _get_limits_min_zoom(effective_rect):
		_set_target_zoom(_get_limits_min_zoom(effective_rect))
	var half := viewport_size * 0.5 / zoom
	var clamped_pos := position
	# Horizontal clamp
	var min_x := effective_rect.position.x + half.x
	var max_x := effective_rect.end.x - half.x
	if max_x < min_x:
		# Viewport wider than the map rect → center on that axis.
		clamped_pos.x = effective_rect.get_center().x
	else:
		clamped_pos.x = clampf(position.x, min_x, max_x)
	# Vertical clamp
	var min_y := effective_rect.position.y + half.y
	var max_y := effective_rect.end.y - half.y
	if max_y < min_y:
		clamped_pos.y = effective_rect.get_center().y
	else:
		clamped_pos.y = clampf(position.y, min_y, max_y)
	position = clamped_pos

## Arms the position glide toward `target_pos` when `smooth_position_fit` is
## on (default), otherwise snaps immediately. Shared by all fit helpers so they
## all honor the same smoothing toggle.
func _arm_fit(target_pos: Vector2) -> void:
	if smooth_position_fit:
		_target_position = target_pos
		_position_interp_active = true
	else:
		_cancel_interp()
		position = target_pos

func fit_rect(world_rect: Rect2) -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	var fit_zoom: float = minf(viewport_size.x / world_rect.size.x, viewport_size.y / world_rect.size.y)
	_set_fit_zoom(fit_zoom * fit_zoom_scale)
	_arm_fit(world_rect.get_center())
	_apply_limits()

## Fits the camera to `world_rect` while reserving `right_screen_margin` px of
## empty screen space along the right edge (e.g. for the zoom/UI panel). The
## zoom is computed so the rect fits within the viewport width minus the margin,
## and the camera shifts right so the rect's horizontal center lands in the
## center of the left "usable" region. Margin is in screen pixels.
func fit_rect_with_right_margin(world_rect: Rect2, right_screen_margin: float) -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	var right_margin := maxf(right_screen_margin, 0.0)
	var usable_width := maxf(viewport_size.x - right_margin, 1.0)
	var target_zoom: float = minf(usable_width / world_rect.size.x, viewport_size.y / world_rect.size.y) * fit_zoom_scale
	_set_fit_zoom(target_zoom)
	# Shift the fit center right so the rect sits toward the left of the viewport,
	# reserving the right margin: the rect's horizontal center should land on
	# screen at usable_width/2 (i.e. `right_margin/2` from the left edge).
	var center := world_rect.get_center()
	center.x += right_margin / (2.0 * target_zoom)
	_arm_fit(center)
	_apply_limits()

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
		# On a touch device (emulate_mouse_from_touch=true) every touch also
		# arrives as a synthesized mouse button event. The touch branch below
		# handles those, so skip the synthesized mouse branch here. Desktop
		# mouse (no touchscreen) is handled directly. Wheel zoom always passes
		# since it's never emulated. No DisplayServer touch checks here — they
		# are unreliable on HTML5/mobile web.
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
		# Wheel zoom: anchored to the cursor when the toggle is enabled,
		# otherwise the classic center-anchored zoom around the screen center.
		# Center-anchored wheel zoom cancels interpolation so the user's zoom
		# isn't fought by an in-flight glide.
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if wheel_zoom_to_cursor:
				_zoom_to_focal(mb.position, _target_zoom + zoom_step)
			else:
				_cancel_interp()
				_set_target_zoom(_target_zoom + zoom_step)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if wheel_zoom_to_cursor:
				_zoom_to_focal(mb.position, _target_zoom - zoom_step)
			else:
				_cancel_interp()
				_set_target_zoom(_target_zoom - zoom_step)
	elif event is InputEventMouseMotion and _dragging:
		# Same de-duplication: synthesized mouse motion on a touch device is
		# also emitted as a touch drag, so the touch branch handles the pan.
		# Desktop mouse never hits this guard.
		if Input.is_emulating_mouse_from_touch():
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
	_cancel_interp()
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
