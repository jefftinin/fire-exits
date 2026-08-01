extends Node2D

@export var rooms_container_path: NodePath = "Rooms"
@export var exits_container_path: NodePath = "Exits"

var selected_room: Area2D = null
var rooms: Array[Area2D] = []
var exits: Array[Node2D] = []
var path_curve: Path2D = null
var arrow_sprite: Sprite2D = null

func _ready() -> void:
	var rooms_node = get_node_or_null(rooms_container_path)
	if rooms_node:
		for child in rooms_node.get_children():
			if child is Area2D and child.has_signal("room_selected"):
				child.room_selected.connect(_on_room_selected)
				rooms.append(child)

	var exits_node = get_node_or_null(exits_container_path)
	if exits_node:
		for child in exits_node.get_children():
			exits.append(child)

	path_curve = get_node_or_null("PathCurve")
	if path_curve:
		path_curve.curve.clear_points()
		arrow_sprite = Sprite2D.new()
		# Use icon.svg as placeholder arrow texture, or create a simple polygon
		var arrow_poly := Polygon2D.new()
		arrow_poly.polygon = PackedVector2Array([
			Vector2(-5, -5),
			Vector2(5, 0),
			Vector2(-5, 5)
		])
		arrow_poly.color = Color.RED
		arrow_sprite.add_child(arrow_poly)
		arrow_sprite.visible = false
		path_curve.add_child(arrow_sprite)

func _on_room_selected(room: Area2D) -> void:
	if selected_room == room:
		return
	deselect_current()
	selected_room = room
	selected_room.select()
	_show_path_to_nearest_exit(selected_room)

func deselect_current() -> void:
	if selected_room:
		selected_room.deselect()
		selected_room = null
	_clear_path()

func _clear_path() -> void:
	if path_curve:
		path_curve.curve.clear_points()
	if arrow_sprite:
		arrow_sprite.visible = false

func _show_path_to_nearest_exit(room: Area2D) -> void:
	if exits.is_empty():
		return
	var room_center = room.global_position
	var nearest_exit: Node2D = null
	var min_dist := INF
	for exit_node in exits:
		var d = room_center.distance_to(exit_node.global_position)
		if d < min_dist:
			min_dist = d
			nearest_exit = exit_node
	if nearest_exit:
		_draw_path(room_center, nearest_exit.global_position)

func _draw_path(from_pos: Vector2, to_pos: Vector2) -> void:
	if not path_curve:
		return
	path_curve.curve.clear_points()
	path_curve.curve.add_point(from_pos)
	path_curve.curve.add_point(to_pos)

	if arrow_sprite:
		arrow_sprite.global_position = to_pos
		arrow_sprite.rotation = (to_pos - from_pos).angle()
		arrow_sprite.visible = true

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if selected_room:
			pass
	elif event is InputEventScreenTouch and event.pressed:
		pass