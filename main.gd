extends Node2D

@onready var path_arrow: RigidBody2D = $PathArrow
@onready var trackline: Line2D = $Line2D
@onready var info_bubble: Control = $InfoBubble
@onready var vbox_container: VBoxContainer = $InfoBubble/VBoxContainer
@onready var room_name_label: Label = $InfoBubble/VBoxContainer/RoomName
@onready var room_info_label: Label = $InfoBubble/VBoxContainer/RoomInfo
@onready var maplist: ItemList = $UILayer/ItemList


const MAP_SCENES: Dictionary = {
	"Radar": preload("res://radar.tscn"),
	"Tower": preload("res://tower.tscn"),
}

var _current_map: Node2D = null
var _trackline_index: int = -1

func _ready() -> void:
	# Hide the info bubble initially
	info_bubble.visible = false
	
	# Populate the map list
	for map_name in MAP_SCENES:
		maplist.add_item(map_name)
	maplist.item_selected.connect(_on_map_selected)
	
	# Select Radar by default (index 0)
	maplist.select(0)
	_trackline_index = trackline.get_index()
	_load_map("Radar")

	

func _on_room_clicked(room: Room, click_position: Vector2) -> void:
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
	
	# Convert viewport click position to global canvas coordinates
	# This ensures the bubble appears exactly where clicked regardless of camera zoom/pan
	var viewport := get_viewport()
	var canvas_transform := viewport.get_canvas_transform()
	
	# Use the click position passed from the room signal (works for both mouse and touch)
	var global_click_pos := canvas_transform.affine_inverse() * click_position
	
	# Position bubble centered above the clicked point
	var bubble_offset := Vector2(-content_size.x / 2.0, -content_size.y)
	info_bubble.global_position = global_click_pos + bubble_offset
	info_bubble.visible = true
	path_arrow.teleport_to(global_click_pos)
	path_arrow.visible = true
	trackline.visible = true

func _on_map_selected(index: int) -> void:
	var selected_name := maplist.get_item_text(index)
	_load_map(selected_name)

func _load_map(map_name: String) -> void:
	if not MAP_SCENES.has(map_name):
		push_error("Unknown map: %s" % map_name)
		return
	
	# Hide UI elements when switching maps
	info_bubble.visible = false
	path_arrow.visible = false
	trackline.visible = false
	
	# Free the current map if one exists
	if _current_map != null:
		_current_map.queue_free()
		_current_map = null
	
	# Instantiate and add the new map
	var scene: PackedScene = MAP_SCENES[map_name]
	_current_map = scene.instantiate() as Node2D
	add_child(_current_map)
	move_child(_current_map, _trackline_index -1 )
	
	# Connect room signals for the new map
	_connect_room_signals(_current_map)
	
	# Refresh navigation targets so PathArrow can find exits/assemblies in the new map
	path_arrow.refresh_targets()

func _connect_room_signals(map_node: Node2D) -> void:
	_connect_signals_from_container(map_node, "Rooms")
	_connect_signals_from_container(map_node, "Assembly Areas")

func _connect_signals_from_container(map_node: Node2D, container_name: String) -> void:
	var container := map_node.get_node_or_null(container_name)
	if container == null:
		return
	for child in container.get_children():
		if child is Room:
			if not child.room_clicked.is_connected(_on_room_clicked):
				child.room_clicked.connect(_on_room_clicked)

func _disconnect_room_signals(map_node: Node2D) -> void:
	_disconnect_signals_from_container(map_node, "Rooms")
	_disconnect_signals_from_container(map_node, "Assembly Areas")

func _disconnect_signals_from_container(map_node: Node2D, container_name: String) -> void:
	var container := map_node.get_node_or_null(container_name)
	if container == null:
		return
	for child in container.get_children():
		if child is Room:
			if child.room_clicked.is_connected(_on_room_clicked):
				child.room_clicked.disconnect(_on_room_clicked)

func _unhandled_input(event: InputEvent) -> void:
	# Handle left mouse button clicks and touch input
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# Hide the info bubble when clicking outside any room
			info_bubble.visible = false
	elif event is InputEventScreenTouch and not event.pressed:
		# Hide the info bubble when touching outside any room (touch end)
		info_bubble.visible = false
