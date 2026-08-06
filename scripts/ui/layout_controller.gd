extends Node
class_name LayoutController

## Reference to the root Control of the UI layer (scaled/positioned by this
## component). Set via init().
var root_control: Control = null
## Reference to the logo VBox. Set via init().
var logo_vbox: VBoxContainer = null
## Reference to the logo sprites. Set via init().
var logo_sprite: TextureRect = null
var logo_sprite2: TextureRect = null
## Reference to the zoom controls container (positioned by this component).
var zoom_controls: Control = null
## Reference to the search suggestion list (geometry driven here).
var suggestions_list: ItemList = null
var search_panel: Panel = null
var search_input: LineEdit = null
## Reference to the About panel (sized here on open).
var about_panel: Control = null
var about_dialog: PanelContainer = null

# --- Layout state (owned by this component) ---
var _safe_area: Dictionary = {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
var _safe_area_cache: Dictionary = {}
var _last_viewport_size: Vector2 = Vector2.ZERO
## Current scale applied to the whole UI layer, recomputed in relayout().
var _ui_scale: float = 1.0

@export var screen_margin: float = 12.0
@export var scale_ui_with_viewport: bool = false
@export var base_resolution: Vector2 = Vector2(1920, 1080)
@export_range(0.4, 2.0, 0.05) var min_ui_scale: float = 0.75
@export_range(1.0, 4.0, 0.05) var max_ui_scale: float = 1.5
@export var list_width: float = 384.0
@export var list_bottom_gap: float = 8.0
@export var max_visible_rows: int = 10
@export var row_height: float = 30.0

## Points the component at all the UI controls it positions/sizes.
func init(ui: Dictionary) -> void:
	root_control = ui.get("root_control") as Control
	logo_vbox = ui.get("logo_vbox") as VBoxContainer
	logo_sprite = ui.get("logo_sprite") as TextureRect
	logo_sprite2 = ui.get("logo_sprite2") as TextureRect
	zoom_controls = ui.get("zoom_controls") as Control
	suggestions_list = ui.get("suggestions_list") as ItemList
	search_panel = ui.get("search_panel") as Panel
	search_input = ui.get("search_input") as LineEdit
	about_panel = ui.get("about_panel") as Control
	about_dialog = ui.get("about_dialog") as PanelContainer
	call_deferred("relayout")

func get_ui_scale() -> float:
	return _ui_scale

func get_safe_area() -> Dictionary:
	return _safe_area

func is_portrait() -> bool:
	if root_control == null:
		return false
	return root_control.size.y > root_control.size.x

## Reads the viewport size in CanvasLayer coordinates safely.
func viewport_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	return vp.get_visible_rect().size

## Reads platform safe-area insets. Desktop/some web never block and return 0;
## mobile caches per orientation so repeated queries don't stall startup.
func update_safe_area() -> void:
	var insets: Dictionary = {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
	if OS.has_feature("mobile") or OS.has_feature("web"):
		var key := "portrait" if is_portrait() else "landscape"
		if _safe_area_cache.has(key):
			_safe_area = _safe_area_cache[key]
			return
		if DisplayServer.get_name() in ["Android", "iOS", "Web"]:
			var area := DisplayServer.get_display_safe_area()
			var vp_size := viewport_size()
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

## Recomputes positions/widths for all responsive UI elements.
func relayout() -> void:
	if root_control == null:
		return
	var viewport := viewport_size()
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return
	if viewport == _last_viewport_size and not _safe_area_cache.is_empty():
		return
	_last_viewport_size = viewport

	# By default the UI keeps a constant size and simply re-anchors to the
	# screen edges on resize. Optionally apply a uniform scale.
	var scale_factor := 1.0
	if scale_ui_with_viewport:
		scale_factor = clampf(
			minf(viewport.x / base_resolution.x, viewport.y / base_resolution.y),
			min_ui_scale,
			max_ui_scale
		)
	_ui_scale = scale_factor

	# The root control's size covers the viewport. Pin to top-left and size
	# manually so container/anchor layout doesn't fight the scale.
	var design_size := viewport / scale_factor
	root_control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root_control.position = Vector2.ZERO
	root_control.pivot_offset = Vector2.ZERO
	root_control.scale = Vector2(scale_factor, scale_factor)
	root_control.size = design_size

	update_safe_area()

	var safe_top: float = _safe_area["top"]
	var safe_bottom: float = _safe_area["bottom"]
	var safe_right: float = _safe_area["right"]

	var w: float = design_size.x
	var h: float = design_size.y

	# Measure the logo stack once (used for both logo positioning and the
	# zoom controls' top offset below).
	var logo_rect := Vector2.ZERO

	# --- Logo stack (top-right) ---
	if logo_vbox != null:
		logo_rect = _measure_control(logo_vbox)
		var logo_w: float = minf(logo_rect.x, w * 0.45)
		logo_vbox.position = Vector2(w - safe_right - screen_margin - logo_w, safe_top + screen_margin)
		var scale_f: float = clampf(logo_w / maxf(1.0, logo_rect.x), 0.5, 1.0)
		if logo_sprite != null and logo_sprite.texture != null:
			logo_sprite.size = Vector2(logo_sprite.texture.get_width(), logo_sprite.texture.get_height()) * scale_f
		if logo_sprite2 != null and logo_sprite2.texture != null:
			logo_sprite2.size = Vector2(logo_sprite2.texture.get_width(), logo_sprite2.texture.get_height()) * scale_f
		logo_vbox.size = Vector2.ZERO  # VBox recomputes from children

	# --- Zoom controls (right edge, below logos) ---
	if zoom_controls != null:
		var logo_bottom: float = (logo_vbox.position.y + logo_rect.y) if logo_vbox != null else safe_top + screen_margin
		var zoom_top: float = maxf(logo_bottom + screen_margin, safe_top + screen_margin)
		var zoom_left: float = w - safe_right - 44.0 - screen_margin
		var zoom_height: float = minf(265.0, h - safe_bottom - zoom_top - screen_margin)
		zoom_height = maxf(160.0, zoom_height)
		zoom_controls.position = Vector2(zoom_left, zoom_top)
		zoom_controls.size = Vector2(44.0, zoom_height)

	# --- Search list reposition if visible ---
	if suggestions_list != null and suggestions_list.visible:
		update_list_geometry()

	apply_about_dialog_size()

## Approximates a control's intrinsic size (used before layout has run).
func _measure_control(c: Control) -> Vector2:
	var size := c.get_combined_minimum_size()
	if size.x <= 0.0:
		size.x = 254.0
	if size.y <= 0.0:
		size.y = 147.0
	return size

## Positions the suggestion list directly below the search input and sizes it
## to fit the number of returned rows (capped to keep it on screen).
func update_list_geometry() -> void:
	if suggestions_list == null or search_panel == null or search_input == null or root_control == null:
		return
	var panel := suggestions_list.get_parent() as Control
	if panel == null:
		return
	var input_bottom := search_input.position.y + search_input.size.y
	var row_count := suggestions_list.item_count
	var list_height: float = maxf(35.0, row_count * row_height)
	var search_ui: Control = search_panel.get_parent() as Control
	var design_h: float = root_control.size.y
	var max_below: float = maxf(0.0, design_h - _safe_area["bottom"] - 4.0 - search_ui.position.y - search_ui.size.y)
	list_height = minf(list_height, max_below)
	if list_height < 35.0:
		list_height = 35.0
	var half_width: float = minf(list_width, search_panel.size.x) * 0.5
	suggestions_list.set_anchor_and_offset(SIDE_LEFT, 0.5, -half_width)
	suggestions_list.set_anchor_and_offset(SIDE_RIGHT, 0.5, half_width)
	suggestions_list.set_anchor_and_offset(SIDE_TOP, 0.0, input_bottom + list_bottom_gap)
	suggestions_list.set_anchor_and_offset(SIDE_BOTTOM, 0.0, input_bottom + list_bottom_gap + list_height)

## Sizes and centers the About dialog so it fits within the viewport.
func apply_about_dialog_size() -> void:
	if about_panel == null or not about_panel.visible or about_dialog == null or root_control == null:
		return
	var vp := root_control.size
	var margin := 24.0
	var max_w: float = maxf(240.0, vp.x - margin * 2.0)
	var max_h: float = maxf(180.0, vp.y - margin * 2.0)
	var dlg_w: float = minf(640.0, max_w)
	var dlg_h: float = minf(500.0, max_h)
	about_dialog.size = Vector2(dlg_w, dlg_h)
	about_dialog.position = Vector2((vp.x - dlg_w) * 0.5, (vp.y - dlg_h) * 0.5)