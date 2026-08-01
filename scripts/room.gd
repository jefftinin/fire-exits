extends Area2D

signal room_selected(room_node)

@export var room_name: String = ""
@export var highlight_color: Color = Color(0.2, 0.6, 1.0, 0.4)

var is_selected: bool = false
var tween: Tween = null
var pulse_scale_min: float = 1.0
var pulse_scale_max: float = 1.05

func _ready() -> void:
	input_event.connect(_on_input_event)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

func _on_input_event(viewport: Node, event: InputEvent, shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		emit_signal("room_selected", self)
	elif event is InputEventScreenTouch and event.pressed:
		emit_signal("room_selected", self)

func _on_mouse_entered() -> void:
	if not is_selected:
		modulate = Color(1.2, 1.2, 1.2, 1.0)

func _on_mouse_exited() -> void:
	if not is_selected:
		modulate = Color.WHITE

func select() -> void:
	if is_selected:
		return
	is_selected = true
	modulate = highlight_color
	_start_pulse()

func deselect() -> void:
	if not is_selected:
		return
	is_selected = false
	modulate = Color.WHITE
	_stop_pulse()
	scale = Vector2.ONE

func _start_pulse() -> void:
	_stop_pulse()
	tween = create_tween().set_loops()
	tween.tween_property(self, "scale", Vector2(pulse_scale_max, pulse_scale_max), 0.4).set_trans(Tween.TRANS_SINE)
	tween.tween_property(self, "scale", Vector2(pulse_scale_min, pulse_scale_min), 0.4).set_trans(Tween.TRANS_SINE)

func _stop_pulse() -> void:
	if tween:
		tween.kill()
		tween = null