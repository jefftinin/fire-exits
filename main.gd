extends Node2D

@onready var path_arrow: RigidBody2D = $PathArrow
@onready var trackline: Line2D = $Line2D
@onready var info_bubble: Control = $InfoBubble
@onready var vbox_container: VBoxContainer = $InfoBubble/VBoxContainer
@onready var room_name_label: Label = $InfoBubble/VBoxContainer/RoomName
@onready var room_info_label: Label = $InfoBubble/VBoxContainer/RoomInfo

func _ready() -> void:
	# Hide the info bubble initially
	info_bubble.visible = false
	
	# Connect to all room click signals
	var rooms_node := $Rooms
	for child in rooms_node.get_children():
		if child is Room:
			child.room_clicked.connect(_on_room_clicked)

func _on_room_clicked(room: Room) -> void:
	# Update the labels with room data
	room_name_label.text = "You are here!"
	room_info_label.text = room.room_name
	
	# Reset size to minimum to allow recalculation
	info_bubble.size = Vector2.ZERO
	
	# Wait for layout to update so we can get the correct combined minimum size
	await get_tree().process_frame
	
	# Resize bubble to fit content + padding
	var content_size := vbox_container.get_combined_minimum_size()
	info_bubble.size = content_size
	
	# Position the info bubble at the mouse click position (screen/viewport coordinates)
	# Since InfoBubble is a Control under Node2D, we need to account for camera transform
	var viewport := get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	
	# Convert viewport mouse position to global canvas coordinates
	# This ensures the bubble appears exactly where clicked regardless of camera zoom/pan
	var canvas_transform := viewport.get_canvas_transform()
	var global_mouse_pos := canvas_transform.affine_inverse() * mouse_pos
	
	# Position bubble centered above the clicked point
	var bubble_offset := Vector2(-content_size.x / 2.0, -content_size.y)
	info_bubble.global_position = global_mouse_pos + bubble_offset
	info_bubble.visible = true
	path_arrow.teleport_to(global_mouse_pos)
	path_arrow.visible = true
	trackline.visible = true

func _unhandled_input(event: InputEvent) -> void:
	# Handle left mouse button clicks
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# Hide the info bubble when clicking outside any room
			info_bubble.visible = false
