extends Camera2D

## Emitted whenever the target zoom changes (wheel, pinch, buttons, slider,
## or fit). Re-emitted from the ZoomController child so the UI layer can keep
## the zoom slider/label in sync.
signal zoom_changed(value: float)

@onready var zoom_controller: ZoomController = $ZoomController
@onready var fitter: Fitter = $Fitter
@onready var limits_controller: LimitsController = $LimitsController
@onready var gestures_controller: GesturesController = $GesturesController

func _ready() -> void:
	# Re-emit the zoom controller's signal so external listeners (UI layer)
	# don't need to reach into the child node.
	zoom_controller.zoom_changed.connect(func(value: float) -> void: zoom_changed.emit(value))

func _process(delta: float) -> void:
	zoom = zoom.lerp(Vector2(zoom_controller.get_target_zoom(), zoom_controller.get_target_zoom()), zoom_controller.zoom_smoothness * delta)
	fitter.process_glide(delta)
	gestures_controller.process_fling(delta)
	limits_controller.apply_limits()

func _unhandled_input(event: InputEvent) -> void:
	gestures_controller.unhandled_input(event)

# --- Zoom API (delegated) -----------------------------------------------------

func zoom_in() -> void:
	zoom_controller.zoom_in()

func zoom_out() -> void:
	zoom_controller.zoom_out()

func zoom_to(value: float) -> void:
	zoom_controller.zoom_to(value)

func get_zoom_value() -> float:
	return zoom_controller.get_zoom_value()

func get_zoom_min() -> float:
	return zoom_controller.get_zoom_min()

func get_zoom_max() -> float:
	return zoom_controller.get_zoom_max()

# --- Fitting (delegated) ------------------------------------------------------

func fit_sprite(sprite: Sprite2D) -> void:
	fitter.fit_sprite(sprite)

func fit_sprite_including_children(sprite: Sprite2D) -> void:
	fitter.fit_sprite_including_children(sprite)

func fit_rect(world_rect: Rect2) -> void:
	fitter.fit_rect(world_rect)

func fit_rect_with_right_margin(world_rect: Rect2, right_screen_margin: float, top_screen_margin: float = 0.0) -> void:
	fitter.fit_rect_with_right_margin(world_rect, right_screen_margin, top_screen_margin)

# --- Limits (delegated) -------------------------------------------------------

func set_limits(rect: Rect2) -> void:
	limits_controller.set_limits(rect)

func clear_limits() -> void:
	limits_controller.clear_limits()

# --- Input control (delegated) ------------------------------------------------

func set_input_enabled(enabled: bool) -> void:
	gestures_controller.set_input_enabled(enabled)