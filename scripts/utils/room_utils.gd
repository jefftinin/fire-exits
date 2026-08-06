class_name RoomUtils
extends Object

## Collects searchable room entries from the given map's "Rooms" container.
## Each entry is { "name": String, "position": Vector2, "aliases": Array[String] }.
## Room child node names are included as search aliases/alternate names.
static func gather_rooms(map_node: Node2D) -> Array[Dictionary]:
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

## Connects every Room's `room_clicked` signal in the given containers to
## `callback`. `callback` must take (room: Room, click_position: Vector2).
static func connect_room_signals(map_node: Node2D, callback: Callable) -> void:
	_connect_signals_from_container(map_node, "TouchZone", callback)
	_connect_signals_from_container(map_node, "Assembly Areas", callback)

## Disconnects every Room's `room_clicked` signal in the given containers
## from `callback`.
static func disconnect_room_signals(map_node: Node2D, callback: Callable) -> void:
	_disconnect_signals_from_container(map_node, "TouchZone", callback)
	_disconnect_signals_from_container(map_node, "Assembly Areas", callback)

static func _connect_signals_from_container(map_node: Node2D, container_name: String, callback: Callable) -> void:
	var container := map_node.get_node_or_null(container_name)
	if container == null:
		return
	for child in container.get_children():
		if child is Room:
			if not child.room_clicked.is_connected(callback):
				child.room_clicked.connect(callback)

static func _disconnect_signals_from_container(map_node: Node2D, container_name: String, callback: Callable) -> void:
	var container := map_node.get_node_or_null(container_name)
	if container == null:
		return
	for child in container.get_children():
		if child is Room:
			if child.room_clicked.is_connected(callback):
				child.room_clicked.disconnect(callback)