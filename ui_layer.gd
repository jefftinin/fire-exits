extends CanvasLayer

@onready var about_button: Button = $Control/VBoxContainer/PanelContainer/MenuButton
@onready var about_window: Window = $Control/Window

func _ready() -> void:
	about_button.pressed.connect(_on_about_pressed)
	about_window.close_requested.connect(_on_about_close_requested)

func _on_about_pressed() -> void:
	about_window.popup_centered()

func _on_about_close_requested() -> void:
	about_window.hide()
