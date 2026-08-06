extends Node
class_name Fitter

## Reference to the owning camera, set in _ready() via get_parent().
var camera: Camera2D = null
## Reference to the sibling ZoomController, wired in _ready().
var zoom_controller: ZoomController = null
## References the owning camera's LimitsController so fits apply position
## clamping. Wired in _ready().
var limits_controller: Node = null

## When true (default), programmatic fits glide the camera position toward
## the new center instead of snapping. User gestures immediately cancel this
## interpolation and take control.
@export var smooth_position_fit: bool = true
## Speed of the position glide. Matches the zoom lerp feel (higher = snappier).
@export var position_smoothness: float = 8.0
@export_range(0.5, 2.0, 0.01) var fit_zoom_scale: float = 1.0

# --- Position interpolation state ---
## Target world position the camera glides toward while interpolation is
## armed. Updated by fit_rect; cleared on any user gesture takeover.
var _target_position: Vector2 = Vector2.ZERO
## True while the camera is gliding toward `_target_position`.
var _position_interp_active: bool = false

func _ready() -> void:
	camera = get_parent() as Camera2D
	zoom_controller = _get_zoom_controller()
	limits_controller = get_parent().get_node_or_null("LimitsController")

## Finds the sibling ZoomController node (may be named differently).
func _get_zoom_controller() -> ZoomController:
	var parent := get_parent()
	if parent == null:
		return null
	# Check children directly for one of our component types.
	for child in parent.get_children():
		if child is ZoomController:
			return child
	return null

## Glides the camera position toward `_target_position` when armed. Stops once
## essentially there (keeps tiny floating-point jitter from running forever).
func process_glide(delta: float) -> void:
	if not _position_interp_active or camera == null:
		return
	camera.position = camera.position.lerp(_target_position, position_smoothness * delta)
	if camera.position.distance_to(_target_position) < 0.01:
		camera.position = _target_position
		_position_interp_active = false

## Disarms position interpolation (user gesture takeover). The camera snaps to
## full user control; the next fit_rect re-arms the glide.
func cancel_interp() -> void:
	_position_interp_active = false

## Arms the position glide toward `target_pos` when `smooth_position_fit` is
## on (default), otherwise snaps immediately.
func _arm_fit(target_pos: Vector2) -> void:
	if camera == null:
		return
	if smooth_position_fit:
		_target_position = target_pos
		_position_interp_active = true
	else:
		cancel_interp()
		camera.position = target_pos

## Fits the camera to a world rect. Grows/clamps the zoom via the zoom
## controller's `set_fit_zoom` (no user-facing floor).
func fit_rect(world_rect: Rect2) -> void:
	if camera == null or zoom_controller == null:
		return
	var viewport_size := camera.get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	var fit_zoom: float = minf(viewport_size.x / world_rect.size.x, viewport_size.y / world_rect.size.y)
	zoom_controller.set_fit_zoom(fit_zoom * fit_zoom_scale)
	_arm_fit(world_rect.get_center())
	_apply_limits()

## Fits the camera to `world_rect` while reserving `right_screen_margin` px of
## empty screen space along the right edge and (optionally) `top_screen_margin`
## px along the top edge. The zoom is computed so the rect fits within the
## viewport width minus the right margin AND the viewport height minus the top
## margin, and the camera shifts so the rect's center lands in the center of
## the remaining "usable" region. Margins are in screen pixels.
func fit_rect_with_right_margin(world_rect: Rect2, right_screen_margin: float, top_screen_margin: float = 0.0) -> void:
	if camera == null or zoom_controller == null:
		return
	var viewport_size := camera.get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	var right_margin := maxf(right_screen_margin, 0.0)
	var top_margin := maxf(top_screen_margin, 0.0)
	var usable_width := maxf(viewport_size.x - right_margin, 1.0)
	var usable_height := maxf(viewport_size.y - top_margin, 1.0)
	var target_zoom: float = minf(usable_width / world_rect.size.x, usable_height / world_rect.size.y) * fit_zoom_scale
	zoom_controller.set_fit_zoom(target_zoom)
	# Shift the fit center right/down so the rect sits toward the top-left of the
	# viewport, reserving the right and top margins.
	var center := world_rect.get_center()
	center.x += right_margin / (2.0 * target_zoom)
	center.y -= top_margin / (2.0 * target_zoom)
	_arm_fit(center)
	_apply_limits()

func fit_sprite(sprite: Sprite2D) -> void:
	var texture := sprite.texture
	if texture == null:
		return
	fit_rect(BoundsUtils.get_sprite_world_rect(sprite))

## Fits the camera to the sprite's bounds including its descendants.
func fit_sprite_including_children(sprite: Sprite2D) -> void:
	if sprite.texture == null:
		return
	fit_rect(BoundsUtils.get_sprite_bounds_including_children(sprite))

## Applies position clamping via the LimitsController (if present).
func _apply_limits() -> void:
	if limits_controller != null and limits_controller.has_method("apply_limits"):
		limits_controller.apply_limits()