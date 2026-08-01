# map_manager.gd
extends Node2D

@onready var rooms_container = $Rooms
@onready var path_arrow = $PathCurve
@onready var info_bubble = $InfoBubble
@onready var room_name_label = $InfoBubble/RoomName
@onready var room_info_label = $InfoBubble/RoomInfo
@onready var search_input = $SearchUI/SearchInput
@onready var suggestions_list = $SearchUI/SuggestionsList
@onready var search_button = $SearchUI/SearchButton

var rooms: Dictionary = {}  # Store rooms by name
var room_names: Array = []  # For search suggestions
var current_room: Room = null
var selected_room: Room = null  # Room selected from search
var exit_room: Room = null
var path_line: Line2D
var search_timer: Timer

func _ready():
	
		# Create arrow polygon
	var arrow_polygon = Polygon2D.new()
	var points = PackedVector2Array([
		Vector2(0, -5),
		Vector2(20, 0),
		Vector2(0, 5)
	])
	arrow_polygon.polygon = points
	arrow_polygon.color = Color.RED
	path_arrow.add_child(arrow_polygon)

	# Collect all rooms
	for child in rooms_container.get_children():
		if child is Room:
			rooms[child.room_name] = child
			room_names.append(child.room_name)
			child.room_clicked.connect(_on_room_clicked)
	
	# Sort room names alphabetically for better suggestions
	room_names.sort()
	
	# Set exit room
	exit_room = rooms.get("Exit")
	
	# Create line for path visualization
	path_line = Line2D.new()
	path_line.width = 3
	path_line.default_color = Color.GREEN
	path_line.z_index = 10
	add_child(path_line)
	
	# Setup search
	info_bubble.visible = false
	path_arrow.visible = false
	suggestions_list.visible = false
	
	# Connect search signals
	search_input.text_changed.connect(_on_search_text_changed)
	search_input.text_submitted.connect(_on_search_submitted)
	search_button.pressed.connect(_on_search_button_pressed)
	suggestions_list.item_selected.connect(_on_suggestion_selected)
	
	# Create timer for debouncing search (optional)
	search_timer = Timer.new()
	search_timer.wait_time = 0.3
	search_timer.one_shot = true
	search_timer.timeout.connect(_update_suggestions)
	add_child(search_timer)

func _on_search_text_changed(new_text: String):
	# Reset timer for debounced search
	search_timer.start()

func _update_suggestions():
	var search_term = search_input.text.strip_edges().to_lower()
	
	suggestions_list.clear()
	
	if search_term.length() == 0:
		suggestions_list.visible = false
		return
	
	# Filter rooms matching search term
	var matches = []
	for room_name in room_names:
		if search_term in room_name.to_lower():
			matches.append(room_name)
	
	# Add matches to suggestion list
	if matches.size() > 0:
		for match in matches:
			suggestions_list.add_item(match)
		suggestions_list.visible = true
		
		# Position suggestions list below search input
		suggestions_list.position = Vector2(
			search_input.position.x,
			search_input.position.y + search_input.size.y + 5
		)
	else:
		suggestions_list.visible = false
		# Optionally show "No results" feedback
		suggestions_list.add_item("No rooms found")
		suggestions_list.visible = true

func _on_suggestion_selected(index: int):
	var room_name = suggestions_list.get_item_text(index)
	if room_name != "No rooms found":
		search_input.text = room_name
		suggestions_list.visible = false
		_select_room(room_name)

func _on_search_submitted(text: String):
	suggestions_list.visible = false
	_select_room(text)

func _on_search_button_pressed():
	suggestions_list.visible = false
	_select_room(search_input.text)

func _select_room(room_name: String):
	if rooms.has(room_name):
		var room = rooms[room_name]
		_on_room_clicked(room)
		
		# Optional: Center camera on the room
		# $Camera2D.position = room.position
		
		# Optional: Highlight the selected room
		_highlight_room(room)
	else:
		# Show error feedback
		search_input.text = ""
		search_input.placeholder_text = "Room not found: " + room_name
		await get_tree().create_timer(2.0).timeout
		search_input.placeholder_text = "Search rooms..."

func _highlight_room(room: Room):
	# Reset all rooms to default
	for r in rooms.values():
		r.modulate = r.default_modulate
	
	# Highlight selected room (pulse effect)
	var tween = create_tween()
	tween.tween_property(room, "modulate", Color(1.5, 1.5, 0.5, 1.0), 0.3)
	tween.tween_property(room, "modulate", room.default_modulate, 0.3)

func _on_room_clicked(room: Room):
	current_room = room
	show_room_info(room)
	
	if exit_room and room != exit_room:
		find_and_show_path(room, exit_room)
	else:
		path_line.clear_points()
		path_arrow.visible = false

func show_room_info(room: Room):
	room_name_label.text = room.room_name
	room_info_label.text = room.room_info
	
	# Position info bubble near the room but offset
	info_bubble.position = room.position + Vector2(20, -50)
	info_bubble.visible = true

func find_and_show_path(from_room: Room, to_room: Room):
	var path = bfs_find_path(from_room, to_room)
	
	if path:
		draw_path(path)
		update_arrow(path)
	else:
		print("No path found!")
		path_line.clear_points()
		path_arrow.visible = false

func bfs_find_path(start: Room, goal: Room) -> Array:
	var queue = [start]
	var visited = {start: null}
	
	while queue.size() > 0:
		var current = queue.pop_front()
		
		if current == goal:
			var path = []
			var node = goal
			while node != null:
				path.push_front(node)
				node = visited[node]
			return path
		
		for connection_path in current.connected_rooms:
			var neighbor = get_node(connection_path) as Room
			if neighbor and not visited.has(neighbor):
				visited[neighbor] = current
				queue.push_back(neighbor)
	
	return []

func draw_path(path: Array):
	path_line.clear_points()
	for room in path:
		path_line.add_point(room.position)

func update_arrow(path: Array):
	if path.size() >= 2:
		var from_pos = path[0].position
		var to_pos = path[1].position
		
		path_arrow.position = from_pos
		path_arrow.rotation = from_pos.angle_to_point(to_pos)
		path_arrow.visible = true

func _input(event):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# Hide suggestions if clicking elsewhere
			if not _is_mouse_over_search_ui():
				suggestions_list.visible = false
			
			# Close info bubble when clicking empty space
			var space_state = get_world_2d().direct_space_state
			var query = PhysicsPointQueryParameters2D.new()
			query.position = get_global_mouse_position()
			var result = space_state.intersect_point(query)
			
			if result.is_empty() and not _is_mouse_over_search_ui():
				info_bubble.visible = false
				path_line.clear_points()
				path_arrow.visible = false

func _is_mouse_over_search_ui() -> bool:
	var mouse_pos = get_global_mouse_position()
	var search_ui = $SearchUI
	var rect = Rect2(search_ui.global_position, search_ui.size)
	return rect.has_point(mouse_pos)
	
