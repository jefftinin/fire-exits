extends Node2D

@onready var path_arrow: CharacterBody2D = $PathArrow
@onready var trackline: Line2D = $Line2D
@onready var marker: Control = $Marker
@onready var exit_panel: Control = $ExitPanel
@onready var circle_indicator: TextureRect = $ExitPanel/MarkerSprite
@onready var maplist: ItemList = $UILayer/Control/ItemList
@onready var camera: Camera2D = $Camera2D
@onready var ui_layer: UILayer = $UILayer

## Extra margin (world px) around the click->assembly bounds when fitting the
## camera. Larger values zoom out further so more of the map/path is shown.
@export var path_fit_padding: float = 160.0


## Map name → scene path. Scenes are loaded lazily on first use so the web
## export only downloads the active map, not all of them at startup.
const MAP_SCENES: Dictionary = {
	"Radar": "res://radar.tscn",
	"Tower": "res://tower.tscn",
}

## Cache of loaded map scenes by name. Populated on demand to keep the
## initial download small.
var _map_scenes_loaded: Dictionary = {}

var _current_map: Node2D = null
var _trackline_index: int = -1
var _camera_fit_rect: Rect2 = Rect2()
var _camera_fit_active: bool = false
var _marker_tween: Tween = null
var _marker_breath_tween: Tween = null
var _exit_tween: Tween = null
var _exit_breath_tween: Tween = null

func _ready() -> void:

	# White background for the whole 2D world (fills any resolution automatically,
	# never tied to UI or world-element backgrounds).
	RenderingServer.set_default_clear_color(Color.WHITE)

	# Hide the info bubble initially
	marker.visible = false
	marker.scale = Vector2.ZERO
	_stop_breathing()
	_hide_exit_panel()

	# Track drawn path points so the camera can keep the whole path in view
	path_arrow.path_point_added.connect(_on_path_point_added)
	path_arrow.path_completed.connect(_on_path_completed)

	# Navigate to a searched room when a suggestion is selected
	ui_layer.room_selected.connect(_on_room_selected)
	
	# Populate the map list
	for map_name in MAP_SCENES:
		maplist.add_item(map_name)
	maplist.item_selected.connect(_on_map_selected)
	
	_trackline_index = trackline.get_index()
	
	# Read URL params for deep-linking (web export). Only read on initial load.
	var params := _get_url_params()
	
	# Map selection: ?map=Radar or ?map=Tower
	var map_name: String = str(params.get("map", "Radar"))
	if not MAP_SCENES.has(map_name):
		map_name = "Radar"
	# Select it in the map list dropdown
	for i in range(maplist.item_count):
		if maplist.get_item_text(i) == map_name:
			maplist.select(i)
			break
	_load_map(map_name)
	
	# Room selection: ?room=Office — navigate after a short delay so the map
	# has time to render before the path/marker animation kicks in.
	var room_name: String = str(params.get("room", ""))
	if not room_name.is_empty():
		get_tree().create_timer(0.0).timeout.connect(
			func() -> void: _navigate_to_room_by_name(room_name)
		)

func _get_url_params() -> Dictionary:
	if not OS.has_feature("web"):
		return {}
	var raw: String = JavaScriptBridge.eval("window.location.search")
	var params := {}
	var query := raw.trim_prefix("?")
	if query.is_empty():
		return params
	for pair in query.split("&"):
		var parts := pair.split("=", true, 1)
		if parts.size() == 2:
			params[parts[0].uri_decode()] = parts[1].uri_decode()
	return params

## Navigates to a room by name/alias on the currently loaded map. Matching is
## case-insensitive and also checks alias names, consistent with search.
func _navigate_to_room_by_name(room_name: String) -> void:
	var target := room_name.strip_edges()
	if target.is_empty() or _current_map == null:
		return
	for room in _gather_rooms(_current_map):
		if str(room["name"]).to_lower() == target.to_lower():
			navigate_to(room["position"])
			return
		for alias in room.get("aliases", []):
			if str(alias).to_lower() == target.to_lower():
				navigate_to(room["position"])
				return

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
	_play_marker_pop()
	_hide_exit_panel()
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

## Pops the marker in with a bouncy scale-up from the pin tip, then starts
## the idle breathing loop.
func _play_marker_pop() -> void:
	# Kill any in-flight animation so rapid re-clicks don't conflict
	if _marker_tween != null:
		_marker_tween.kill()
	_stop_breathing()
	marker.visible = true
	marker.scale = Vector2.ZERO
	_marker_tween = create_tween()
	_marker_tween.set_trans(Tween.TRANS_BACK)
	_marker_tween.set_ease(Tween.EASE_OUT)
	_marker_tween.tween_property(marker, "scale", Vector2.ONE, 0.35)
	_marker_tween.tween_callback(_start_breathing)

## Keeps the marker gently pulsing while idle.
func _start_breathing() -> void:
	if not marker.visible or _marker_breath_tween != null:
		return
	_marker_breath_tween = create_tween().set_loops()
	_marker_breath_tween.set_trans(Tween.TRANS_SINE)
	_marker_breath_tween.set_ease(Tween.EASE_IN_OUT)
	_marker_breath_tween.tween_property(marker, "scale", Vector2(1.08, 1.08), 0.9)
	_marker_breath_tween.tween_property(marker, "scale", Vector2.ONE, 0.9)

## Stops the idle breathing loop.
func _stop_breathing() -> void:
	if _marker_breath_tween != null:
		_marker_breath_tween.kill()
		_marker_breath_tween = null

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

## Called when the arrow reaches the assembly point; stops further refits and
## shows the EXIT destination panel over the final resting spot.
func _on_path_completed() -> void:
	_camera_fit_active = false
	_show_exit_panel(path_arrow.global_position)

func _on_map_selected(index: int) -> void:
	var selected_name := maplist.get_item_text(index)
	_load_map(selected_name)
	_update_url_for_map(selected_name)

## Called when a search result is selected: navigates the marker/path arrow to
## the room and updates the shareable URL so the selection is deep-linkable.
func _on_room_selected(room_name: String, position: Vector2) -> void:
	navigate_to(position)
	_update_url_for_room(room_name)

## Updates the URL's `map` parameter on web exports (uses history.replaceState
## so the selection becomes deep-linkable without adding a history entry).
func _update_url_for_map(map_name: String) -> void:
	if not OS.has_feature("web"):
		return
	_update_url_query("map", map_name)

## Updates the URL's `room` parameter on web exports.
func _update_url_for_room(room_name: String) -> void:
	if not OS.has_feature("web"):
		return
	_update_url_query("room", room_name)

## Rebuilds ?map=...&room=... keeping existing params, then updates the URL.
func _update_url_query(key: String, value: String) -> void:
	var params := _get_url_params()
	if value.is_empty():
		params.erase(key)
	else:
		params[key] = value
	var query_parts: PackedStringArray = []
	for k in params:
		query_parts.append("%s=%s" % [str(k).uri_encode(), str(params[k]).uri_encode()])
	var new_query := "?" + "&".join(query_parts)
	JavaScriptBridge.eval("history.replaceState(null, '', '%s')" % new_query)

## Pops the red EXIT panel in at the given world position using the same
## transition as the marker, then breathes the whole panel (circle + text)
## like the Marker node.
func _show_exit_panel(world_pos: Vector2) -> void:
	# The panel mirrors the Marker layout: its origin is the sprite center, so
	# position directly at the point (like the Marker is positioned in
	# navigate_to).
	exit_panel.global_position = world_pos
	exit_panel.visible = true
	if _exit_tween != null:
		_exit_tween.kill()
	_stop_exit_breathing()
	exit_panel.scale = Vector2.ZERO
	# Pop the panel as a whole with the marker's bounce.
	_exit_tween = create_tween()
	_exit_tween.set_trans(Tween.TRANS_BACK)
	_exit_tween.set_ease(Tween.EASE_OUT)
	_exit_tween.tween_property(exit_panel, "scale", Vector2.ONE, 0.35)
	_exit_tween.tween_callback(_start_exit_breathing)

## Keeps the whole EXIT panel gently pulsing while idle, matching the marker.
func _start_exit_breathing() -> void:
	if not exit_panel.visible or _exit_breath_tween != null:
		return
	_exit_breath_tween = create_tween().set_loops()
	_exit_breath_tween.set_trans(Tween.TRANS_SINE)
	_exit_breath_tween.set_ease(Tween.EASE_IN_OUT)
	_exit_breath_tween.tween_property(exit_panel, "scale", Vector2(1.08, 1.08), 0.9)
	_exit_breath_tween.tween_property(exit_panel, "scale", Vector2.ONE, 0.9)

## Stops the panel's idle breathing loop.
func _stop_exit_breathing() -> void:
	if _exit_breath_tween != null:
		_exit_breath_tween.kill()
		_exit_breath_tween = null

## Hides the EXIT panel and kills any in-flight tween.
func _hide_exit_panel() -> void:
	if _exit_tween != null:
		_exit_tween.kill()
		_exit_tween = null
	_stop_exit_breathing()
	exit_panel.visible = false
	exit_panel.scale = Vector2.ZERO

## Loads (and caches) the map scene for `map_name`. Loads on first use so the
## web export fetches only the maps the user actually opens.
func _get_map_scene(map_name: String) -> PackedScene:
	if _map_scenes_loaded.has(map_name):
		return _map_scenes_loaded[map_name]
	var scene := load(MAP_SCENES[map_name]) as PackedScene
	_map_scenes_loaded[map_name] = scene
	return scene

func _load_map(map_name: String) -> void:
	if not MAP_SCENES.has(map_name):
		push_error("Unknown map: %s" % map_name)
		return
	
	# Hide UI elements when switching maps
	marker.visible = false
	marker.scale = Vector2.ZERO
	_stop_breathing()
	_hide_exit_panel()
	path_arrow.visible = false
	trackline.visible = false
	
	# Free the current map if one exists
	if _current_map != null:
		_current_map.queue_free()
		_current_map = null
	
	# Instantiate and add the new map
	var scene: PackedScene = _get_map_scene(map_name)
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
