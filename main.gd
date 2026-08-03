extends Node2D

# const DASHED_LINE_SHADER := preload("res://shaders/dashed_line.gdshader")

@onready var path_arrow: CharacterBody2D = $PathArrow
@onready var trackline: Line2D = $Line2D
@onready var marker: Control = $Marker
@onready var room_name_label: Label = $InfoBubble/VBoxContainer/RoomName
@onready var room_info_label: Label = $InfoBubble/VBoxContainer/RoomInfo
@onready var maplist: ItemList = $UILayer/Control/ItemList
@onready var camera: Camera2D = $Camera2D
@onready var ui_layer: UILayer = $UILayer

## Extra margin (world px) around the click->assembly bounds when fitting the
## camera. Larger values zoom out further so more of the map/path is shown.
@export var path_fit_padding: float = 160.0


const MAP_SCENES: Dictionary = {
	"Radar": preload("res://radar.tscn"),
	"Tower": preload("res://tower.tscn"),
}

var _current_map: Node2D = null
var _trackline_index: int = -1
var _camera_fit_rect: Rect2 = Rect2()
var _camera_fit_active: bool = false

func _ready() -> void:

	# Hide the info bubble initially
	marker.visible = false

	# Track drawn path points so the camera can keep the whole path in view
	path_arrow.path_point_added.connect(_on_path_point_added)
	path_arrow.path_completed.connect(_on_path_completed)

	# Navigate to a searched room when a suggestion is selected
	ui_layer.room_selected.connect(navigate_to)
	
	# Populate the map list
	for map_name in MAP_SCENES:
		maplist.add_item(map_name)
	maplist.item_selected.connect(_on_map_selected)
	
	# Select Radar by default (index 0)
	maplist.select(0)
	_trackline_index = trackline.get_index()
	_load_map("Radar")

	

func _on_room_clicked(room: Room, click_position: Vector2) -> void:
	# Convert viewport click position to global canvas coordinates
	# This ensures the bubble appears exactly where clicked regardless of camera zoom/pan
	var viewport := get_viewport()
	var canvas_transform := viewport.get_canvas_transform()
	
	# Use the click position passed from the room signal (works for both mouse and touch)
	var global_click_pos := canvas_transform.affine_inverse() * click_position
	navigate_to(global_click_pos)

## Navigates the marker/path arrow to a global world position and fits the
## camera to the resulting path. Used by both room clicks and search results.
func navigate_to(global_pos: Vector2) -> void:
	# Marker sprite center is at marker origin, so position directly at point
	marker.global_position = global_pos
	marker.visible = true
	path_arrow.teleport_to(global_pos)
	path_arrow.visible = true
	trackline.visible = true
	
	# Reset the camera-fit bounds to the start point, then expand to include
	# the assembly target. As the arrow draws its path, added points are also
	# included so the entire visible path stays on screen.
	_camera_fit_rect = Rect2(global_pos, Vector2.ZERO)
	_camera_fit_active = true
	var assembly_pos: Vector2 = path_arrow.get_assembly_target_position()
	_camera_fit_rect = _camera_fit_rect.expand(assembly_pos)
	_apply_camera_fit()

## Fits the camera to the accumulated path bounds if tracking is active.
func _apply_camera_fit() -> void:
	if not _camera_fit_active:
		return
	camera.fit_rect(_camera_fit_rect.grow(path_fit_padding))

## Called whenever the arrow records a new path point; expands the camera
## bounds so the growing path remains visible.
func _on_path_point_added(point: Vector2) -> void:
	if not _camera_fit_active:
		return
	_camera_fit_rect = _camera_fit_rect.expand(point)
	_apply_camera_fit()

## Called when the arrow reaches the assembly point; stops further refits.
func _on_path_completed() -> void:
	_camera_fit_active = false

func _on_map_selected(index: int) -> void:
	var selected_name := maplist.get_item_text(index)
	_load_map(selected_name)

func _load_map(map_name: String) -> void:
	if not MAP_SCENES.has(map_name):
		push_error("Unknown map: %s" % map_name)
		return
	
	# Hide UI elements when switching maps
	marker.visible = false
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
	
	# Populate the search input with searchable room entries from this map
	ui_layer.set_rooms(_gather_rooms(_current_map))
	
	# Zoom out to fit the full map sprite in view
	var map_sprite: Sprite2D = _current_map.get_node_or_null("MapSprite") as Sprite2D
	if map_sprite != null:
		camera.fit_sprite(map_sprite)

func _connect_room_signals(map_node: Node2D) -> void:
	_connect_signals_from_container(map_node, "TouchZone")
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
	_disconnect_signals_from_container(map_node, "TouchZone")
	_disconnect_signals_from_container(map_node, "Assembly Areas")

## Collects searchable room entries from the active map's "Rooms" container.
## Each entry is { "name": String, "position": Vector2, "aliases": Array[String] }.
## Room child node names are included as search aliases/alternate names.
func _gather_rooms(map_node: Node2D) -> Array[Dictionary]:
	var rooms: Array[Dictionary] = []
	var container := map_node.get_node_or_null("Rooms")
	if container == null:
		return rooms
	for child in container.get_children():
		if child is Node2D:
			var node2d := child as Node2D
			# Child node names act as search aliases/alternate names for this room
			var aliases: Array[String] = []
			for alias_node in node2d.get_children():
				aliases.append(alias_node.name)
			rooms.append({
				"name": node2d.name,
				"position": node2d.global_position,
				"aliases": aliases,
			})
	return rooms

func _disconnect_signals_from_container(map_node: Node2D, container_name: String) -> void:
	var container := map_node.get_node_or_null(container_name)
	if container == null:
		return
	for child in container.get_children():
		if child is Room:
			if child.room_clicked.is_connected(_on_room_clicked):
				child.room_clicked.disconnect(_on_room_clicked)
