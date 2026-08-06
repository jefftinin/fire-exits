extends Node
class_name ZoomController

## Emitted whenever the target zoom changes (wheel, pinch, buttons, slider,
## or fit). The UI layer listens (via the parent camera's re-emitted signal)
## to keep the zoom slider/label in sync.
signal zoom_changed(value: float)

## Reference to the owning camera, set in _ready() via get_parent().
var camera: Camera2D = null

var _target_zoom: float = 1.0

@export var zoom_min: float = 0.2
## Lower zoom floor used when the viewport is taller than wide (portrait, e.g.
## phones). Lets the camera zoom out further so the full map fits on narrow
## screens. Landscape/desktop keep the regular `zoom_min`.
@export var portrait_zoom_min: float = 0.05
@export var zoom_max: float = 3.0
@export var zoom_step: float = 0.1
@export var zoom_smoothness: float = 8.0
## Multiplier for proportional pinch zoom. Higher = zoom changes faster with
## the same finger spread. (1/mean_px_per_step tuned for a natural feel.)
@export var pinch_zoom_sensitivity: float = 0.01

func _ready() -> void:
	camera = get_parent() as Camera2D

## Returns the lowest zoom allowed given the current viewport orientation:
## `portrait_zoom_min` when the viewport is taller than wide, otherwise the
## regular `zoom_min` (landscape/desktop floor).
func get_allowed_min_zoom() -> float:
	if camera == null:
		return zoom_min
	var viewport_size := camera.get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return zoom_min
	if viewport_size.y > viewport_size.x:
		return portrait_zoom_min
	return zoom_min

func get_target_zoom() -> float:
	return _target_zoom

func set_target_zoom(value: float) -> void:
	_target_zoom = clampf(value, get_allowed_min_zoom(), zoom_max)
	zoom_changed.emit(_target_zoom)

## Sets the target zoom for programmatic fits (`fit_rect`, `fit_sprite*`).
## Unlike `set_target_zoom`, this is NOT clamped by the user-facing zoom-out
## floor, so fits can always zoom out far enough to show the whole rect
## regardless of screen size/orientation. Only a tiny safety floor and
## `zoom_max` cap apply.
func set_fit_zoom(value: float) -> void:
	_target_zoom = clampf(value, 0.01, zoom_max)
	zoom_changed.emit(_target_zoom)

func zoom_in() -> void:
	set_target_zoom(_target_zoom + zoom_step)

func zoom_out() -> void:
	set_target_zoom(_target_zoom - zoom_step)

func zoom_to(value: float) -> void:
	set_target_zoom(value)

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
## NOTE: Uses `_target_zoom` (not the smoothed `zoom`) for the focal math.
func zoom_to_focal(screen_pos: Vector2, new_target_zoom: float) -> void:
	if camera == null:
		return
	var viewport_size := camera.get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		set_target_zoom(new_target_zoom)
		return
	var old_zoom: float = _target_zoom
	var clamped_new := clampf(new_target_zoom, get_allowed_min_zoom(), zoom_max)
	if is_equal_approx(clamped_new, old_zoom):
		return
	var focal_offset := screen_pos - viewport_size * 0.5
	# position moves so the world point under screen_pos stays put.
	camera.position += focal_offset * (1.0 / old_zoom - 1.0 / clamped_new)
	set_target_zoom(clamped_new)

## Returns a per-step multiplier so the pinch feels similar across zoom
## ranges. Cheap approximation: lower sensitivity at high zoom, higher at low.
func sensitivity_scale() -> float:
	return clampf(1.0 / maxf(0.1, _target_zoom), 0.5, 2.0) * pinch_zoom_sensitivity * 100.0

## Clamps `value` to the current user-facing zoom range (respecting portrait
## floor). Used by external callers (e.g. fitter) that must respect the floor.
func clamp_user_zoom(value: float) -> float:
	return clampf(value, get_allowed_min_zoom(), zoom_max)