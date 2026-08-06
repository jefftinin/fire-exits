extends Node
class_name LimitsController

## Reference to the owning camera, set in _ready() via get_parent().
var camera: Camera2D = null
## Reference to the sibling ZoomController, wired in _ready().
var zoom_controller: ZoomController = null

## When true, clamps the camera position so the visible world area stays
## within the limits rect (set via set_limits or manual_limits_rect).
@export var limits_enabled: bool = false
## Extra margin (world px) added around the limits rect on each side.
@export var limits_margin: Vector2 = Vector2.ZERO
## Optional rect used directly as the camera limits. If non-zero, this takes
## precedence over the rect passed to set_limits().
@export var manual_limits_rect: Rect2 = Rect2()
## When true, zooming out cannot exceed the limits rect.
@export var limit_zoom_to_limits: bool = false

## World-space rect the camera is clamped inside while limits_enabled is true.
var _limits_rect: Rect2 = Rect2()

func _ready() -> void:
	camera = get_parent() as Camera2D
	zoom_controller = _get_zoom_controller()

## Finds the sibling ZoomController node.
func _get_zoom_controller() -> ZoomController:
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child is ZoomController:
			return child
	return null

## Enables position limits, clamping the camera so its visible world-rect
## stays within `rect`. Call clear_limits() to release the clamp.
func set_limits(rect: Rect2) -> void:
	_limits_rect = rect
	limits_enabled = true
	apply_limits()

## Disables camera position limits.
func clear_limits() -> void:
	limits_enabled = false
	_limits_rect = Rect2()

## Returns the rect the camera is clamped inside: `manual_limits_rect` when
## non-zero, otherwise the rect passed to set_limits(), then scaled by
## `limits_margin`.
func get_effective_limits_rect() -> Rect2:
	var effective := _limits_rect
	if manual_limits_rect.size.x != 0.0 or manual_limits_rect.size.y != 0.0:
		effective = manual_limits_rect
	# Expand/shrink on each side by the margin (negative insets the clamp).
	return Rect2(
		effective.position - limits_margin,
		effective.size + limits_margin * 2.0
	)

## Returns the smallest zoom at which the viewport still fits entirely inside
## `rect` on both axes. Used when `limit_zoom_to_limits` is enabled.
func get_limits_min_zoom(rect: Rect2) -> float:
	if camera == null:
		return 1.0
	var viewport_size := camera.get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return _base_min_zoom()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return _base_min_zoom()
	return maxf(viewport_size.x / rect.size.x, viewport_size.y / rect.size.y)

func _base_min_zoom() -> float:
	if zoom_controller != null:
		return zoom_controller.get_allowed_min_zoom()
	return 1.0

## Clamps `camera.position` so the camera's visible viewport stays within the
## limits rect. If the viewport is larger than the limits rect on an axis,
## that axis is centered on the rect.
func apply_limits() -> void:
	if camera == null:
		return
	if not limits_enabled:
		return
	var viewport_size := camera.get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var effective_rect := get_effective_limits_rect()
	if effective_rect.size.x <= 0.0 or effective_rect.size.y <= 0.0:
		return
	# When the toggle is on, keep the target zoom from going further out than
	# the viewport fitting inside the limits.
	if limit_zoom_to_limits and zoom_controller != null:
		var min_zoom := get_limits_min_zoom(effective_rect)
		if zoom_controller.get_target_zoom() < min_zoom:
			zoom_controller.set_target_zoom(min_zoom)
	var half := viewport_size * 0.5 / camera.zoom
	var clamped_pos := camera.position
	# Horizontal clamp
	var min_x := effective_rect.position.x + half.x
	var max_x := effective_rect.end.x - half.x
	if max_x < min_x:
		# Viewport wider than the map rect → center on that axis.
		clamped_pos.x = effective_rect.get_center().x
	else:
		clamped_pos.x = clampf(camera.position.x, min_x, max_x)
	# Vertical clamp
	var min_y := effective_rect.position.y + half.y
	var max_y := effective_rect.end.y - half.y
	if max_y < min_y:
		clamped_pos.y = effective_rect.get_center().y
	else:
		clamped_pos.y = clampf(camera.position.y, min_y, max_y)
	camera.position = clamped_pos