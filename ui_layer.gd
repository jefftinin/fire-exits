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

@onready var search_input: LineEdit = $Control/SearchUI/SearchPanel/SearchInput
@onready var search_panel: Panel = $Control/SearchUI/SearchPanel
@onready var suggestions_list: ItemList = $Control/SearchUI/SearchPanel/SuggestionsList

@onready var logo_vbox: VBoxContainer = $Control/VBoxContainer
@onready var logo_sprite: TextureRect = $Control/VBoxContainer/HBoxContainer/Sprite2D
@onready var logo_sprite2: TextureRect = $Control/VBoxContainer/HBoxContainer/Sprite2D2
@onready var map_list: ItemList = $Control/CenterUI/ItemList

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
## When true, the whole UI scales proportionally with the viewport
## (relative to base_resolution, clamped by min/max_ui_scale). When false
## (default), UI elements keep a constant size and only re-anchor to their
## screen edges as the window resizes.
@export var scale_ui_with_viewport: bool = false
## Reference resolution the layout was designed for. Only used when
## scale_ui_with_viewport is true.
@export var base_resolution: Vector2 = Vector2(1920, 1080)
## Minimum UI scale factor. Prevents the UI from becoming unreadably small on
## narrow portrait phones where a pure "fit" factor would shrink it too much.
@export_range(0.4, 2.0, 0.05) var min_ui_scale: float = 0.75
## Maximum UI scale factor. Prevents the UI from becoming comically large on
## very large monitors.
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
## Estimated pixel height of a single ItemList row. Used to size the list so
## it fits exactly the number of returned matches.
@export var row_height: float = 30.0
## Constant width of the suggestion list (matches the SearchInput width).
@export var list_width: float = 384.0

## Cached safe-area insets for the current orientation, in px:
## { "top": float, "bottom": float, "left": float, "right": float }
var _safe_area: Dictionary = {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
var _safe_area_cache: Dictionary = {}
var _last_viewport_size: Vector2 = Vector2.ZERO
## Current scale applied to the whole UI layer, recomputed in _relayout().
var _ui_scale: float = 1.0

func _ready() -> void:
	about_button.pressed.connect(_on_about_pressed)
	about_close_button.pressed.connect(_on_about_close_requested)
	about_dim.gui_input.connect(_on_about_dim_input)

	# Search wiring
	search_input.text_changed.connect(_on_search_text_changed)
	suggestions_list.item_selected.connect(_on_suggestion_activated)

	# Relayout when the window/viewport resizes (orientation changes included)
	get_viewport().size_changed.connect(_on_viewport_resized)

	# Find the camera (sibling in main scene)
	_camera = get_parent().get_node_or_null("Camera2D") as Camera2D
	if _camera != null:
		_init_zoom_controls()

	# Defer first layout so the viewport size is valid on all platforms.
	call_deferred("_relayout")

func _on_viewport_resized() -> void:
	_relayout()

## Reads platform safe-area insets. Desktop/some web never block and return 0;
## mobile caches per orientation so repeated queries don't stall startup.
func _update_safe_area() -> void:
	var insets: Dictionary = {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
	if OS.has_feature("mobile") or OS.has_feature("web"):
		var key := "portrait" if _is_portrait() else "landscape"
		if _safe_area_cache.has(key):
			_safe_area = _safe_area_cache[key]
			return
		# Query DisplayServer once; gate to platforms that actually report
		# insets so desktop never blocks.
		if DisplayServer.get_name() in ["Android", "iOS", "Web"]:
			var area := DisplayServer.get_display_safe_area()
			# Both the safe-area rect and the viewport size below are in
			# physical pixels, so the inset math stays physical.
			var vp_size := _viewport_size()
			insets = {
				"top": area.position.y,
				"bottom": vp_size.y - (area.position.y + area.size.y),
				"left": area.position.x,
				"right": vp_size.x - (area.position.x + area.size.x),
			}
			# Convert physical-pixel insets to design space (divide by the UI
			# scale) and add a small breathing margin before caching.
			for k in insets:
				insets[k] = maxf(0.0, insets[k] / _ui_scale + 4.0)
		_safe_area_cache[key] = insets
	_safe_area = insets

func _is_portrait() -> bool:
	var size := root_control.size
	return size.y > size.x

## Reads the viewport size in CanvasLayer coordinates safely.
func _viewport_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	return vp.get_visible_rect().size

## Recomputes positions/widths for all responsive UI elements.
func _relayout() -> void:
	var viewport_size := _viewport_size()
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	if viewport_size == _last_viewport_size and not _safe_area_cache.is_empty():
		return
	_last_viewport_size = viewport_size

	# By default the UI keeps a constant size and simply re-anchors to the
	# screen edges on resize. Optionally (scale_ui_with_viewport) apply a
	# uniform scale so everything grows/shrinks proportionally, clamped to
	# avoid an unreadable or comically large UI.
	var scale_factor := 1.0
	if scale_ui_with_viewport:
		scale_factor = clampf(
			minf(viewport_size.x / base_resolution.x, viewport_size.y / base_resolution.y),
			min_ui_scale,
			max_ui_scale
		)
	_ui_scale = scale_factor

	# The root control's size covers the viewport (in its own design space,
	# which equals viewport size when unscaled). Pin to the top-left corner
	# and size it manually so container/anchor layout doesn't fight the scale.
	var design_size := viewport_size / scale_factor
	root_control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root_control.position = Vector2.ZERO
	root_control.pivot_offset = Vector2.ZERO
	root_control.scale = Vector2(scale_factor, scale_factor)
	root_control.size = design_size

	_update_safe_area()

	var safe_top: float = _safe_area["top"]
	var safe_bottom: float = _safe_area["bottom"]
	var safe_left: float = _safe_area["left"]
	var safe_right: float = _safe_area["right"]

	var w: float = design_size.x
	var h: float = design_size.y

	# --- Logo stack (top-right) ---
	var logo_rect := _measure_control(logo_vbox)
	var logo_w: float = minf(logo_rect.x, w * 0.45)
	logo_vbox.position = Vector2(w - safe_right - screen_margin - logo_w, safe_top + screen_margin)
	# Scale the two logo sprites so the whole stack fits on narrow screens.
	var scale_f: float = clampf(logo_w / maxf(1.0, logo_rect.x), 0.5, 1.0)
	if logo_sprite.texture != null:
		logo_sprite.size = Vector2(logo_sprite.texture.get_width(), logo_sprite.texture.get_height()) * scale_f
	if logo_sprite2.texture != null:
		logo_sprite2.size = Vector2(logo_sprite2.texture.get_width(), logo_sprite2.texture.get_height()) * scale_f
	logo_vbox.size = Vector2.ZERO  # VBox recomputes from children

	# --- Zoom controls (right edge, below logos) ---
	# Everything is laid out in design space (root_control is scaled to cover
	# the viewport and sits at position Vector2.ZERO), so the logo stack's
	# design-space bottom is its top plus its measured height (from
	# _measure_control above). We can't use logo_vbox.size here because the
	# container hasn't run a layout pass yet (its size is set to Vector2.ZERO
	# below so the VBox recomputes it from its children).
	var logo_bottom: float = logo_vbox.position.y + logo_rect.y
	var zoom_top: float = maxf(logo_bottom + screen_margin, safe_top + screen_margin)
	var zoom_left: float = w - safe_right - 44.0 - screen_margin
	# Fit zoom panel into remaining vertical space
	var zoom_height: float = minf(265.0, h - safe_bottom - zoom_top - screen_margin)
	zoom_height = maxf(160.0, zoom_height)
	zoom_controls.position = Vector2(zoom_left, zoom_top)
	zoom_controls.size = Vector2(44.0, zoom_height)

	# --- Search bar (top-left) ---
	var search_w: float = minf(search_max_width, w - safe_left - safe_right - 2.0 * screen_margin)
	var search_h: float = 40.0
	var search_x: float = safe_left + screen_margin
	var search_y: float = safe_top + screen_margin
	search_panel.get_parent().position = Vector2(search_x, search_y)
	search_panel.get_parent().size = Vector2(search_w, search_h)

	# Reclamp suggestion list if it is currently visible
	if suggestions_list.visible:
		_update_list_geometry()

	_apply_about_dialog_size()

## Approximates a control's intrinsic size (used before layout has run).
func _measure_control(c: Control) -> Vector2:
	var size := c.get_combined_minimum_size()
	if size.x <= 0.0:
		size.x = 254.0
	if size.y <= 0.0:
		size.y = 147.0
	return size

## Sizes and centers the About dialog so it fits within the viewport.
func _apply_about_dialog_size() -> void:
	if not about_panel.visible:
		return
	# Layout is in design space (root_control is scaled to cover the viewport).
	var vp := root_control.size
	var margin := 24.0
	var max_w: float = maxf(240.0, vp.x - margin * 2.0)
	var max_h: float = maxf(180.0, vp.y - margin * 2.0)
	var dlg_w: float = minf(640.0, max_w)
	var dlg_h: float = minf(500.0, max_h)
	about_dialog.size = Vector2(dlg_w, dlg_h)
	about_dialog.position = Vector2((vp.x - dlg_w) * 0.5, (vp.y - dlg_h) * 0.5)

func _on_about_pressed() -> void:
	about_panel.visible = true
	_apply_about_dialog_size()
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

	# Buttons/sliders/inputs also need to be explicitly disabled (not just
	# ignoring mouse) so keyboard focus and wheel can't reach them either.
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
	_update_list_geometry()
	suggestions_list.visible = true

## Positions the suggestion list directly below the search input and sizes it
## to fit the number of returned rows (capped to keep it on screen).
func _update_list_geometry() -> void:
	var panel := suggestions_list.get_parent() as Control
	if panel == null:
		return

	# SearchInput's bottom edge in the panel's local coordinate space
	var input_bottom := search_input.position.y + search_input.size.y

	var row_count := mini(_matches.size(), max_visible_rows)
	var list_height: float = maxf(35.0, row_count * row_height)
	# Cap so the list doesn't run off the bottom of the screen. Everything here
	# is in design space because root_control is scaled to cover the viewport.
	var search_ui: Control = search_panel.get_parent() as Control
	var search_ui_bottom: float = search_ui.position.y + search_ui.size.y
	var design_h: float = root_control.size.y
	var max_below: float = maxf(0.0, design_h - _safe_area["bottom"] - 4.0 - search_ui_bottom)
	list_height = minf(list_height, max_below)
	if list_height < 35.0:
		list_height = 35.0

	# Anchor to the full panel rect, then shrink to the centered list width
	var half_width := list_width * 0.5
	if suggestions_list.size.x <= 0.0:
		half_width = search_panel.size.x * 0.5
	suggestions_list.set_anchor_and_offset(SIDE_LEFT, 0.5, -half_width)
	suggestions_list.set_anchor_and_offset(SIDE_RIGHT, 0.5, half_width)
	suggestions_list.set_anchor_and_offset(SIDE_TOP, 0.0, input_bottom + list_bottom_gap)
	suggestions_list.set_anchor_and_offset(SIDE_BOTTOM, 0.0, input_bottom + list_bottom_gap + list_height)

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

## Called whenever the camera's target zoom changes from any source
## (scroll wheel, pinch, zoom buttons, fit-to-map). Keeps the slider and
## label in sync with the live zoom level.
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
