extends CanvasLayer
class_name UILayer

@onready var about_button: Button = $Control/VBoxContainer/PanelContainer/MenuButton
@onready var about_window: Window = $Control/Window

@onready var search_ui: Control = $Control/SearchUI
@onready var search_panel: Panel = $Control/SearchUI/SearchPanel
@onready var search_button: Button = $Control/SearchUI/SearchPanel/SearchButton
@onready var zoom_controls: Control = $Control/ZoomControls
@onready var zoom_panel: PanelContainer = $Control/ZoomControls/ZoomPanel
@onready var options_vbox: VBoxContainer = $Control/VBoxContainer
@onready var legend_list: ItemList = $Control/ItemList

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
## Maximum number of rows displayed before the list stops growing upward.
@export_range(1, 20, 1) var max_visible_rows: int = 10
## Margin (px) between the search panel and the bottom of the viewport.
@export var bottom_margin: float = 12.0
## Margin (px) between UI widgets and screen edges on all sides.
@export var edge_margin: float = 12.0
## Minimum width of the search box, in pixels.
@export var search_min_width: float = 220.0
## Maximum width of the search box, in pixels.
@export var search_max_width: float = 460.0
## Fraction of the viewport width the search box may occupy at most.
@export_range(0.1, 1.0, 0.05) var search_width_fraction: float = 0.7

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

	# Responsive layout
	get_viewport().size_changed.connect(_update_responsive_layout)
	_update_responsive_layout()

## Lays out all UI widgets based on the current viewport size and orientation.
## Called initially and whenever the viewport is resized (e.g. device rotation,
## window resize, or aspect-ratio changes from the canvas-items stretch mode).
func _update_responsive_layout() -> void:
	var vp_size := get_viewport().get_visible_rect().size
	var safe := _get_safe_area_insets()
	var is_landscape := vp_size.x > vp_size.y

	# ---- Search bar: bottom-center, shrinks on narrow screens ----
	var search_width := clampf(vp_size.x * search_width_fraction, search_min_width, search_max_width)
	# Account for safe-area bottom inset so the panel never sits under a home bar
	var search_bottom: float = vp_size.y - bottom_margin - float(safe["bottom"])
	search_ui.set_anchor_and_offset(SIDE_LEFT, 0.5, -search_width * 0.5)
	search_ui.set_anchor_and_offset(SIDE_RIGHT, 0.5, search_width * 0.5)
	search_ui.set_anchor_and_offset(SIDE_TOP, 0.0, search_bottom - 40.0)
	search_ui.set_anchor_and_offset(SIDE_BOTTOM, 0.0, search_bottom)

	# ---- Zoom controls: right-middle in landscape, right-bottom in portrait ----
	# Read the panel's size from its anchor offsets (timing-independent, works
	# even before the first layout pass).
	var zoom_w: float = zoom_panel.offset_right - zoom_panel.offset_left
	var zoom_h: float = zoom_panel.offset_bottom - zoom_panel.offset_top
	var zoom_margin: float = edge_margin + float(safe["right"])
	if is_landscape:
		# Vertical panel pinned to the right edge, vertically centered
		zoom_controls.set_anchor_and_offset(SIDE_LEFT, 0.0, vp_size.x - zoom_w - zoom_margin)
		zoom_controls.set_anchor_and_offset(SIDE_RIGHT, 0.0, vp_size.x - zoom_margin)
		zoom_controls.set_anchor_and_offset(SIDE_TOP, 0.0, (vp_size.y - zoom_h) * 0.5)
		zoom_controls.set_anchor_and_offset(SIDE_BOTTOM, 0.0, (vp_size.y + zoom_h) * 0.5)
	else:
		# Portrait: pin to bottom-right corner, above the search bar
		var below_search: float = vp_size.y - bottom_margin - 40.0 - float(safe["bottom"])
		zoom_controls.set_anchor_and_offset(SIDE_LEFT, 0.0, vp_size.x - zoom_w - zoom_margin)
		zoom_controls.set_anchor_and_offset(SIDE_RIGHT, 0.0, vp_size.x - zoom_margin)
		zoom_controls.set_anchor_and_offset(SIDE_TOP, 0.0, below_search - zoom_h - edge_margin)
		zoom_controls.set_anchor_and_offset(SIDE_BOTTOM, 0.0, below_search - edge_margin)

	# ---- Options/logos (top-right) ----
	var opt_w: float = options_vbox.offset_right - options_vbox.offset_left
	var opt_h: float = options_vbox.offset_bottom - options_vbox.offset_top
	options_vbox.set_anchor_and_offset(SIDE_LEFT, 1.0, -opt_w - edge_margin - safe["right"])
	options_vbox.set_anchor_and_offset(SIDE_RIGHT, 1.0, -edge_margin - safe["right"])
	options_vbox.set_anchor_and_offset(SIDE_TOP, 0.0, edge_margin + safe["top"])
	options_vbox.set_anchor_and_offset(SIDE_BOTTOM, 0.0, edge_margin + safe["top"] + opt_h)

	# ---- Legend list (top-left) ----
	var leg_w: float = legend_list.offset_right - legend_list.offset_left
	var leg_h: float = legend_list.offset_bottom - legend_list.offset_top
	legend_list.set_anchor_and_offset(SIDE_LEFT, 0.0, edge_margin + safe["left"])
	legend_list.set_anchor_and_offset(SIDE_RIGHT, 0.0, edge_margin + safe["left"] + leg_w)
	legend_list.set_anchor_and_offset(SIDE_TOP, 0.0, edge_margin + safe["top"])
	legend_list.set_anchor_and_offset(SIDE_BOTTOM, 0.0, edge_margin + safe["top"] + leg_h)

	# ---- About window: clamp so it never overflows the viewport ----
	var max_w := int(minf(804.0, vp_size.x - (edge_margin + safe["left"] + safe["right"]) * 2.0))
	var max_h := int(minf(368.0, vp_size.y - (edge_margin + safe["top"] + safe["bottom"]) * 2.0))
	if max_w > 0 and max_h > 0:
		about_window.min_size = Vector2i(max_w, max_h)
		about_window.size = Vector2i(max_w, max_h)

## Returns the safe-area insets (px) from display cutouts (notches/camera cutouts
## on mobile) as a { "left": int, "top": int, "right": int, "bottom": int }
## dictionary. Returns all zeros on desktop or when no cutouts are present.
func _get_safe_area_insets() -> Dictionary:
	var zero := {"left": 0, "top": 0, "right": 0, "bottom": 0}
	if DisplayServer.get_name() == "headless":
		return zero
	var cutouts := DisplayServer.get_display_cutouts()
	if cutouts.is_empty():
		return zero
	var safe := DisplayServer.get_display_safe_area()
	var vp_size := get_viewport().get_visible_rect().size
	return {
		"left": safe.position.x,
		"top": safe.position.y,
		"right": maxi(0, int(vp_size.x) - safe.position.x - safe.size.x),
		"bottom": maxi(0, int(vp_size.y) - safe.position.y - safe.size.y),
	}

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
## The list width follows the search panel width so it always lines up.
func _update_list_geometry() -> void:
	var panel := suggestions_list.get_parent() as Control
	if panel == null:
		return

	# SearchInput's top edge in the panel's local coordinate space
	var input_top := search_input.position.y
	# Clamp the list so its top never goes off the viewport top edge
	var max_list_height := maxf(35.0, search_ui.position.y - edge_margin)

	var row_count := mini(_matches.size(), max_visible_rows)
	var list_height: float = maxf(35.0, row_count * row_height)
	list_height = minf(list_height, max_list_height)

	# Overlay the full panel rect (panel covers search bar) and center horizontally
	suggestions_list.set_anchor_and_offset(SIDE_LEFT, 0.0, 0.0)
	suggestions_list.set_anchor_and_offset(SIDE_RIGHT, 0.0, search_panel.size.x)
	suggestions_list.set_anchor_and_offset(SIDE_TOP, 0.0, input_top - list_height - 8.0)
	suggestions_list.set_anchor_and_offset(SIDE_BOTTOM, 0.0, input_top - 8.0)

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