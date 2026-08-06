extends Node2D

## Set to true to enable the F12 "copy all deep-link URLs" debug feature
## (web exports only).
@export var f12_copy_deep_links_enabled: bool = false

@onready var path_arrow: CharacterBody2D = $PathArrow
@onready var trackline: Line2D = $Line2D
@onready var marker: Control = $Marker
@onready var exit_panel: Control = $ExitPanel
@onready var circle_indicator: TextureRect = $ExitPanel/MarkerSprite
@onready var maplist: ItemList = $UILayer/Control/CenterUI/ItemList
@onready var camera: Camera2D = $Camera2D
@onready var ui_layer: UILayer = $UILayer

## Extra margin (world px) around the click->assembly bounds when fitting the
## camera. Larger values zoom out further so more of the map/path is shown.
@export var path_fit_padding: float = 160.0

## Right-edge screen margin (px) reserved when the camera fits the probe route
## extents (start → end points). The route's horizontal center lands in the
## center of the viewport width minus this margin, keeping the path clear of
## the right-side UI (e.g. the zoom controls panel).
@export var route_fit_right_margin: float = 250.0

## Top-edge screen margin (px) reserved when the camera fits the probe route
## extents (start → end points). The route's vertical center lands in the
## center of the viewport height minus this margin, keeping the path clear of
## a top header bar (e.g. the map/title bar).
@export var route_fit_top_margin: float = 0.0


## Map name → scene path. Scenes are loaded lazily on first use so the web
## export only downloads the active map, not all of them at startup. Populated
## automatically at runtime by scanning MAPS_DIR for .tscn files.
const MAPS_DIR := "res://floors/"

var MAP_SCENES: Dictionary = {}

## Cache of loaded map scenes by name. Populated on demand to keep the
## initial download small.
var _map_scenes_loaded: Dictionary = {}

var _current_map: Node2D = null
var _trackline_index: int = -1
var _marker_tween: Tween = null
var _marker_breath_tween: Tween = null
var _exit_tween: Tween = null
var _exit_breath_tween: Tween = null

func _ready() -> void:

	# Scan res://floors/ for map scenes before anything else uses MAP_SCENES.
	_populate_map_scenes()

	# White background for the whole 2D world (fills any resolution automatically,
	# never tied to UI or world-element backgrounds).
	RenderingServer.set_default_clear_color(Color.WHITE)

	# Hide the info bubble initially
	marker.visible = false
	marker.scale = Vector2.ZERO
	_stop_breathing()
	_hide_exit_panel()

	# Zoom out to the full route extents (from the invisible probe) before the
	# visible arrow animates, and show the exit panel when the arrow arrives.
	path_arrow.probe_completed.connect(_on_probe_completed)
	path_arrow.path_completed.connect(_on_path_completed)

	# Navigate to a searched room when a suggestion is selected
	ui_layer.room_selected.connect(_on_room_selected)
	
	# Populate the map list
	for map_name in MAP_SCENES:
		maplist.add_item(map_name)
	# Arrange the items in a single horizontal row (one column per map).
	maplist.max_columns = MAP_SCENES.size()
	maplist.item_selected.connect(_on_map_selected)
	
	_trackline_index = trackline.get_index()
	
	# Read URL params for deep-linking (web export). Only read on initial load.
	var params := _get_url_params()
	
	# Map selection: ?map=<name>, defaulting to the first map found in
	# MAP_SCENES if the param is missing or unknown.
	var map_name: String = str(params.get("map", ""))
	if not MAP_SCENES.has(map_name):
		map_name = MAP_SCENES.keys()[0] if not MAP_SCENES.is_empty() else ""
		if map_name.is_empty():
			push_error("No map scenes found in %s" % MAPS_DIR)
			return
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

## Scans MAPS_DIR for .tscn files and populates MAP_SCENES with
## "display name" → "path". Called early in _ready() so the map list,
## deep-link handling, and map loading all see the same entries.
##
## The display name is the filename sans ".tscn", first letter capitalized,
## everything else preserved verbatim — so "radar.tscn" → "Radar",
## "Tower 1.tscn" → "Tower 1", "assembly_area.tscn" → "Assembly_area",
## "lobby&hall.tscn" → "Lobby&hall". Filenames with spaces, hyphens, or
## other symbols keep those characters in the name. The dropdown label and
## the deep-link (?map=...) both use this exact string.
func _populate_map_scenes() -> void:
	MAP_SCENES.clear()
	var dir := DirAccess.open(MAPS_DIR)
	if dir == null:
		push_error("Could not open map scenes directory: %s" % MAPS_DIR)
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tscn"):
			var scene_name := file_name.get_basename()
			if scene_name.length() > 0:
				scene_name = scene_name[0].to_upper() + scene_name.substr(1)
			MAP_SCENES[scene_name] = MAPS_DIR + file_name
		file_name = dir.get_next()
	dir.list_dir_end()

## Handles the F12 shortcut: collects every shareable deep-link URL for each
## map + room combination and copies them all to the clipboard (web exports).
func _unhandled_key_input(event: InputEvent) -> void:
	if not f12_copy_deep_links_enabled:
		return
	if not OS.has_feature("web"):
		return
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_F12:
			var urls := _collect_all_deep_link_urls()
			if urls.is_empty():
				push_warning("F12: no deep-link URLs to copy")
				return
			var joined := "\n".join(urls)
			DisplayServer.clipboard_set(joined)
			get_viewport().set_input_as_handled()

## Builds the full list of shareable deep-link URLs for every map/room
## combination. Base is the current page origin+path, so links work regardless
## of where the app is hosted. Room names are URI-encoded as in the live
## navigation URL updates.
func _collect_all_deep_link_urls() -> PackedStringArray:
	var urls: PackedStringArray = []
	var base: String = str(JavaScriptBridge.eval("window.location.origin + window.location.pathname"))
	# Strip a trailing "/" so we never build "page/?map=...".
	if base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	for map_name in MAP_SCENES:
		var scene := _get_map_scene(map_name)
		if scene == null:
			continue
		var instance := scene.instantiate() as Node2D
		for room in _gather_rooms(instance):
			var map_param := str(map_name).uri_encode()
			var room_param := str(room["name"]).uri_encode()
			urls.append("%s?map=%s&room=%s" % [base, map_param, room_param])
		instance.free()
	return urls

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
## The route is first measured by an invisible probe so the camera can zoom
## out to the full extents before the visible arrow animates.
func navigate_to(global_pos: Vector2) -> void:
	# Marker sprite center is at marker origin, so position directly at point
	marker.global_position = global_pos
	_play_marker_pop()
	_hide_exit_panel()
	# Keep the arrow/track hidden while the probe measures the route; they are
	# re-shown once the camera has fit the full path (in _on_probe_completed).
	path_arrow.visible = false
	trackline.visible = false
	path_arrow.start_probe(global_pos)

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

## Called when the invisible probe finishes measuring the route. Zooms the
## camera out to the traveled path's full extents (reserving the right-screen
## margin so the start/end points clear the right-side UI), then re-shows the
## arrow and track and launches the visible animated run (which drops its own
## low-density turn points and swaps them in on completion).
func _on_probe_completed(bounds: Rect2) -> void:
	camera.fit_rect_with_right_margin(bounds.grow(path_fit_padding), _get_route_fit_margin(), route_fit_top_margin)
	path_arrow.end_probe()
	path_arrow.teleport_to(marker.global_position)
	path_arrow.visible = true
	trackline.visible = true

## Right-edge margin (px) reserved for the route fit. On wide/landscape
## screens it is the configured `route_fit_right_margin`; on narrow/portrait
## screens it scales down proportionally so the right margin never swallows a
## big chunk of the small viewport width (keeping the whole route in view).
func _get_route_fit_margin() -> float:
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0:
		return route_fit_right_margin
	return minf(route_fit_right_margin, viewport_size.x * 0.3)

## Called when the arrow reaches the assembly point; shows the EXIT destination
## panel over the final resting spot.
func _on_path_completed() -> void:
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
	
	# Zoom out to fit the full map sprite (including any child overlays like
	# the "ASSEMBLY AREA" label) in view, and clamp camera movement so users
	# can't pan past the map's combined bounds.
	var map_sprite: Sprite2D = _current_map.get_node_or_null("MapSprite") as Sprite2D
	if map_sprite != null:
		var map_rect: Rect2 = camera.get_sprite_bounds_including_children(map_sprite)
		camera.set_limits(map_rect)
		camera.fit_sprite_including_children(map_sprite)

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
