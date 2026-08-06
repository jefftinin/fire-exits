extends Node
class_name MarkerAnimator

## Reference to the "you are here" marker control (a sibling of the Map root's
## children). Owned by this component via init(). All marker tweens live here.
var marker: Control = null
## Reference to the red EXIT destination panel control (a sibling of the Map
## root's children). Owned by this component via init(). All panel tweens
## live here.
var exit_panel: Control = null

var _marker_tween: Tween = null
var _marker_breath_tween: Tween = null
var _exit_tween: Tween = null
var _exit_breath_tween: Tween = null

## Points the component at the two animated controls and hides both.
func init(new_marker: Control, new_exit_panel: Control) -> void:
	marker = new_marker
	exit_panel = new_exit_panel
	hide_marker()
	hide_exit_panel()

## Pops the marker in with a bouncy scale-up from the pin tip, then starts
## the idle breathing loop.
func play_marker_pop() -> void:
	if marker == null:
		return
	# Kill any in-flight animation so rapid re-clicks don't conflict
	if _marker_tween != null:
		_marker_tween.kill()
	stop_breathing()
	marker.visible = true
	marker.scale = Vector2.ZERO
	_marker_tween = create_tween()
	_marker_tween.set_trans(Tween.TRANS_BACK)
	_marker_tween.set_ease(Tween.EASE_OUT)
	_marker_tween.tween_property(marker, "scale", Vector2.ONE, 0.35)
	_marker_tween.tween_callback(_start_breathing)

## Keeps the marker gently pulsing while idle.
func _start_breathing() -> void:
	if marker == null or not marker.visible or _marker_breath_tween != null:
		return
	_marker_breath_tween = create_tween().set_loops()
	_marker_breath_tween.set_trans(Tween.TRANS_SINE)
	_marker_breath_tween.set_ease(Tween.EASE_IN_OUT)
	_marker_breath_tween.tween_property(marker, "scale", Vector2(1.08, 1.08), 0.9)
	_marker_breath_tween.tween_property(marker, "scale", Vector2.ONE, 0.9)

## Stops the marker's idle breathing loop.
func stop_breathing() -> void:
	if _marker_breath_tween != null:
		_marker_breath_tween.kill()
		_marker_breath_tween = null

## Hides and resets the marker to zero scale.
func hide_marker() -> void:
	if marker == null:
		return
	stop_breathing()
	marker.visible = false
	marker.scale = Vector2.ZERO

## Pops the red EXIT panel in at the given world position using the same
## transition as the marker, then breathes the whole panel (circle + text)
## like the Marker node.
func show_exit_panel(world_pos: Vector2) -> void:
	if exit_panel == null:
		return
	# The panel mirrors the Marker layout: its origin is the sprite center, so
	# position directly at the point (like the Marker is positioned in
	# navigate_to).
	exit_panel.global_position = world_pos
	exit_panel.visible = true
	if _exit_tween != null:
		_exit_tween.kill()
	stop_exit_breathing()
	exit_panel.scale = Vector2.ZERO
	# Pop the panel as a whole with the marker's bounce.
	_exit_tween = create_tween()
	_exit_tween.set_trans(Tween.TRANS_BACK)
	_exit_tween.set_ease(Tween.EASE_OUT)
	_exit_tween.tween_property(exit_panel, "scale", Vector2.ONE, 0.35)
	_exit_tween.tween_callback(_start_exit_breathing)

## Keeps the whole EXIT panel gently pulsing while idle, matching the marker.
func _start_exit_breathing() -> void:
	if exit_panel == null or not exit_panel.visible or _exit_breath_tween != null:
		return
	_exit_breath_tween = create_tween().set_loops()
	_exit_breath_tween.set_trans(Tween.TRANS_SINE)
	_exit_breath_tween.set_ease(Tween.EASE_IN_OUT)
	_exit_breath_tween.tween_property(exit_panel, "scale", Vector2(1.08, 1.08), 0.9)
	_exit_breath_tween.tween_property(exit_panel, "scale", Vector2.ONE, 0.9)

## Stops the panel's idle breathing loop.
func stop_exit_breathing() -> void:
	if _exit_breath_tween != null:
		_exit_breath_tween.kill()
		_exit_breath_tween = null

## Hides the EXIT panel and kills any in-flight tween.
func hide_exit_panel() -> void:
	if exit_panel == null:
		return
	if _exit_tween != null:
		_exit_tween.kill()
		_exit_tween = null
	stop_exit_breathing()
	exit_panel.visible = false
	exit_panel.scale = Vector2.ZERO