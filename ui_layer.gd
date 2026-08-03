extends CanvasLayer
class_name UILayer

@onready var about_button: Button = $Control/VBoxContainer/PanelContainer/MenuButton
@onready var about_window: Window = $Control/Window

@onready var zoom_in_button: Button = $Control/ZoomControls/ZoomPanel/ZoomVBox/ZoomInButton
@onready var zoom_out_button: Button = $Control/ZoomControls/ZoomPanel/ZoomVBox/ZoomOutButton
@onready var zoom_slider: VSlider = $Control/ZoomControls/ZoomPanel/ZoomVBox/ZoomSlider
@onready var zoom_value_label: Label = $Control/ZoomControls/ZoomPanel/ZoomVBox/ZoomValueLabel

@onready var search_input: LineEdit = $Control/SearchUI/SearchPanel/SearchInput
@onready var suggestions_list: ItemList = $Control/SearchUI/SearchPanel/SuggestionsList

## Emitted when a search result is selected. `position` is the room's global
## world position so the main scene can navigate the marker/path arrow to it.
signal room_selected(position: Vector2)

var _camera: Camera2D = null
var _updating_slider: bool = false
var _rooms: Array[Dictionary] = []
var _matches: Array[Dictionary] = []

## Estimated pixel height of a single ItemList row. Used to size the list so
## it fits exactly the number of returned matches.
@export var row_height: float = 30.0
## Constant width of the suggestion list (matches the SearchInput width).
@export var list_width: float = 384.0
## Vertical gap between the list bottom and the top of the search input.
@export var list_bottom_gap: float = 8.0
## Maximum number of rows displayed before the list stops growing upward.
@export_range(1, 20, 1) var max_visible_rows: int = 10

func _ready() -> void:
	about_button.pressed.connect(_on_about_pressed)
	about_window.close_requested.connect(_on_about_close_requested)

	# Search wiring
	search_input.text_changed.connect(_on_search_text_changed)
	suggestions_list.item_selected.connect(_on_suggestion_activated)

	# Find the camera (sibling in main scene)
	_camera = get_parent().get_node_or_null("Camera2D") as Camera2D
	if _camera != null:
		_init_zoom_controls()

## Sets the searchable room entries for the active map.
## Each entry is { "name": String, "position": Vector2 }.
func set_rooms(rooms: Array[Dictionary]) -> void:
	_rooms = rooms
	suggestions_list.clear()
	suggestions_list.visible = false

func _on_search_text_changed(new_text: String) -> void:
	suggestions_list.clear()
	var query := new_text.strip_edges().to_lower()
	if query.is_empty() or _rooms.is_empty():
		suggestions_list.visible = false
		return
	
	_matches.clear()
	for room in _rooms:
		var name_lower: String = str(room["name"]).to_lower()
		if name_lower.contains(query):
			_matches.append(room)
			continue
		# Also match against any alias node names (alternate names) of the room
		for alias_name in room.get("aliases", []):
			if str(alias_name).to_lower().contains(query):
				_matches.append(room)
				break
	
	if _matches.is_empty():
		suggestions_list.visible = false
		return
	
	for i in range(mini(_matches.size(), max_visible_rows)):
		suggestions_list.add_item(str(_matches[i]["name"]))
	_update_list_geometry()
	suggestions_list.visible = true

## Positions the suggestion list directly above the search input and sizes it
## to fit the number of returned rows (capped to keep it on screen).
func _update_list_geometry() -> void:
	var panel := suggestions_list.get_parent() as Control
	if panel == null:
		return
	
	# SearchInput's top edge in the panel's local coordinate space
	var input_top := search_input.position.y
	
	var row_count := mini(_matches.size(), max_visible_rows)
	var list_height: float = maxf(35.0, row_count * row_height)
	
	# Anchor to the full panel rect, then shrink to the centered list width
	var half_width := list_width * 0.5
	suggestions_list.set_anchor_and_offset(SIDE_LEFT, 0.5, -half_width)
	suggestions_list.set_anchor_and_offset(SIDE_RIGHT, 0.5, half_width)
	suggestions_list.set_anchor_and_offset(SIDE_TOP, 0.0, input_top - list_height - list_bottom_gap)
	suggestions_list.set_anchor_and_offset(SIDE_BOTTOM, 0.0, input_top - list_bottom_gap)

func _on_suggestion_activated(index: int) -> void:
	if index < 0 or index >= _matches.size():
		return
	var found: Dictionary = _matches[index]
	
	search_input.text = str(found["name"])
	suggestions_list.visible = false
	room_selected.emit(found["position"])

func _init_zoom_controls() -> void:
	# Set slider range from camera's zoom limits
	zoom_slider.min_value = _camera.get_zoom_min()
	zoom_slider.max_value = _camera.get_zoom_max()
	zoom_slider.step = 0.01
	zoom_slider.value = _camera.get_zoom_value()

	# Connect signals
	zoom_in_button.pressed.connect(_on_zoom_in_pressed)
	zoom_out_button.pressed.connect(_on_zoom_out_pressed)
	zoom_slider.value_changed.connect(_on_zoom_slider_changed)

	# Update label
	_update_zoom_label()

func _on_about_pressed() -> void:
	about_window.popup_centered()

func _on_about_close_requested() -> void:
	about_window.hide()

func _on_zoom_slider_changed(value: float) -> void:
	if _camera == null or _updating_slider:
		return
	_camera.zoom_to(value)
	_update_zoom_label()

func _on_zoom_in_pressed() -> void:
	if _camera == null:
		return
	_camera.zoom_in()
	_updating_slider = true
	zoom_slider.value = _camera.get_zoom_value()
	_updating_slider = false
	_update_zoom_label()

func _on_zoom_out_pressed() -> void:
	if _camera == null:
		return
	_camera.zoom_out()
	_updating_slider = true
	zoom_slider.value = _camera.get_zoom_value()
	_updating_slider = false
	_update_zoom_label()

func _update_zoom_label() -> void:
	if _camera != null:
		var pct: int = roundi(_camera.get_zoom_value() * 100.0)
		zoom_value_label.text = "%d%%" % pct
