extends CanvasLayer
class_name UILayer

@onready var root_control: Control = $Control
@onready var about_button: Button = $"Control/VBoxContainer/About Button/MenuButton"
@onready var about_panel: Control = $Control/AboutPanel
@onready var about_dim: ColorRect = $Control/AboutPanel/Dim
@onready var about_dialog: PanelContainer = $Control/AboutPanel/AboutDialog
@onready var about_close_button: Button = $Control/AboutPanel/AboutDialog/MarginContainer/Content/CloseButton

@onready var zoom_controls: Control = $Control/ZoomControls
@onready var zoom_in_button: Button = $Control/ZoomControls/ZoomPanel/ZoomVBox/ZoomInButton
@onready var zoom_out_button: Button = $Control/ZoomControls/ZoomPanel/ZoomVBox/ZoomOutButton
@onready var zoom_slider: VSlider = $Control/ZoomControls/ZoomPanel/ZoomVBox/ZoomSlider
@onready var zoom_value_label: Label = $Control/ZoomControls/ZoomPanel/ZoomVBox/ZoomValueLabel

@onready var search_input: LineEdit = $Control/CenterUI/SearchUI/SearchPanel/SearchInput
@onready var search_panel: Panel = $Control/CenterUI/SearchUI/SearchPanel
@onready var suggestions_list: ItemList = $Control/CenterUI/SearchUI/SearchPanel/SuggestionsList

@onready var logo_vbox: VBoxContainer = $Control/VBoxContainer
@onready var logo_sprite: TextureRect = $Control/VBoxContainer/HBoxContainer/Sprite2D
@onready var logo_sprite2: TextureRect = $Control/VBoxContainer/HBoxContainer/Sprite2D2
@onready var map_list: ItemList = $Control/CenterUI/ItemList

@onready var layout_controller: LayoutController = $LayoutController

## Emitted when a search result is selected. `room_name` is the selected
## room's name and `position` is its global world position so the main scene
## can navigate the marker/path arrow to it and update the shareable URL.
signal room_selected(room_name: String, position: Vector2)

var _camera: Camera2D = null
## Controls that should be disabled (non-interactive) while the About modal
## is open so the user can only interact with the Close button.
var _disablable_controls: Array[Control] = []
var _updating_slider: bool = false
var _rooms: Array[Dictionary] = []
var _matches: Array[Dictionary] = []

## Pixel margin from each screen edge (before safe-area is applied).
@export var screen_margin: float = 12.0
## When true, the whole UI scales proportionally with the viewport.
@export var scale_ui_with_viewport: bool = false
## Reference resolution the layout was designed for.
@export var base_resolution: Vector2 = Vector2(1920, 1080)
## Minimum UI scale factor.
@export_range(0.4, 2.0, 0.05) var min_ui_scale: float = 0.75
## Maximum UI scale factor.
@export_range(1.0, 4.0, 0.05) var max_ui_scale: float = 1.5
## Maximum width of the search bar in px.
@export var search_max_width: float = 384.0
## Maximum width of the map list in px.
@export var map_list_width: float = 160.0
## Maximum height of the map list in px.
@export var map_list_height: float = 200.0
## Vertical gap between the list bottom and the top of the search input.
@export var list_bottom_gap: float = 8.0
## Maximum number of rows displayed before the list stops growing upward.
@export_range(1, 20, 1) var max_visible_rows: int = 10
## Estimated pixel height of a single ItemList row.
@export var row_height: float = 30.0
## Constant width of the suggestion list (matches the SearchInput width).
@export var list_width: float = 384.0

func _ready() -> void:
	about_button.pressed.connect(_on_about_pressed)
	about_close_button.pressed.connect(_on_about_close_requested)
	about_dim.gui_input.connect(_on_about_dim_input)

	# Search wiring
	search_input.text_changed.connect(_on_search_text_changed)
	suggestions_list.item_selected.connect(_on_suggestion_activated)

	# Relayout when the window/viewport resizes (orientation changes included)
	get_viewport().size_changed.connect(layout_controller.relayout)

	# Find the camera (sibling in main scene)
	_camera = get_parent().get_node_or_null("Camera2D") as Camera2D
	if _camera != null:
		_init_zoom_controls()

	# Hand all responsive layout / safe-area to the LayoutController child.
	layout_controller.init({
		"root_control": root_control,
		"logo_vbox": logo_vbox,
		"logo_sprite": logo_sprite,
		"logo_sprite2": logo_sprite2,
		"zoom_controls": zoom_controls,
		"suggestions_list": suggestions_list,
		"search_panel": search_panel,
		"search_input": search_input,
		"about_panel": about_panel,
		"about_dialog": about_dialog,
	})

func _on_about_pressed() -> void:
	about_panel.visible = true
	layout_controller.apply_about_dialog_size()
	_set_modal_blocking(true)

func _on_about_close_requested() -> void:
	about_panel.visible = false
	_set_modal_blocking(false)

## Consumes every input event that lands on the dim overlay so mouse/touch
## never reaches the world (camera pan/zoom) or any UI underneath the modal.
func _on_about_dim_input(event: InputEvent) -> void:
	about_dim.accept_event()

	# Tapping/clicking the dim background closes the dialog (mouse or touch)
	var pressed: bool = false
	if event is InputEventMouseButton:
		pressed = (event as InputEventMouseButton).pressed
	elif event is InputEventScreenTouch:
		pressed = (event as InputEventScreenTouch).pressed
	if pressed:
		about_panel.visible = false
		_set_modal_blocking(false)

## While the About modal is open, make every other UI control non-interactive
## so the only thing the user can operate is the dialog itself (scroll + Close).
func _set_modal_blocking(blocking: bool) -> void:
	# Build the list lazily on first use.
	if _disablable_controls.is_empty():
		_disablable_controls = [
			map_list,
			search_panel.get_parent() as Control,
			zoom_controls,
			logo_vbox,
		]
	for control in _disablable_controls:
		if control == null:
			continue
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE if blocking else Control.MOUSE_FILTER_STOP

	# Buttons/sliders/inputs also need to be explicitly disabled.
	if blocking:
		about_button.disabled = true
		search_input.editable = false
		search_input.focus_mode = Control.FOCUS_NONE
		zoom_in_button.disabled = true
		zoom_out_button.disabled = true
		zoom_slider.editable = false
	else:
		about_button.disabled = false
		search_input.editable = true
		search_input.focus_mode = Control.FOCUS_ALL
		zoom_in_button.disabled = false
		zoom_out_button.disabled = false
		zoom_slider.editable = true

	# Block the camera's own input (wheel zoom, drag pan, pinch) while the
	# modal is open so scrolling over the dialog can't zoom the world view.
	if _camera != null:
		_camera.set_input_enabled(not blocking)

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
	layout_controller.update_list_geometry()
	suggestions_list.visible = true

func _on_suggestion_activated(index: int) -> void:
	if index < 0 or index >= _matches.size():
		return
	var found: Dictionary = _matches[index]

	search_input.text = str(found["name"])
	suggestions_list.visible = false
	room_selected.emit(str(found["name"]), found["position"])

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
	_camera.zoom_changed.connect(_on_zoom_changed)

	# Update label
	_update_zoom_label()

## Called whenever the camera's target zoom changes from any source.
func _on_zoom_changed(value: float) -> void:
	if _updating_slider:
		return
	_updating_slider = true
	zoom_slider.value = value
	_updating_slider = false
	_update_zoom_label()

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