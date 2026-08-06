class_name BoundsUtils
extends Object

## Local-space rect of a Sprite2D in the sprite's own (pre-transform) frame,
## accounting for its texture size, region cropping, centered flag, and offset.
## The sprite's transform (position/rotation/scale) is NOT yet applied — callers
## transform this by `sprite.global_transform` (or use get_sprite_world_rect).
static func get_sprite_local_rect(sprite: Sprite2D) -> Rect2:
	var texture := sprite.texture
	if texture == null:
		return Rect2()
	var rect_size: Vector2
	if sprite.region_enabled:
		rect_size = sprite.region_rect.size
	else:
		rect_size = texture.get_size()
	var offset := sprite.offset
	if not sprite.centered:
		offset += rect_size / 2.0
	return Rect2(offset - rect_size / 2.0, rect_size)

## Transforms the 4 corners of `rect` by `xform` and returns the min/max
## axis-aligned rect. Correct for rotation and non-uniform scale.
static func transform_rect(rect: Rect2, xform: Transform2D) -> Rect2:
	var bounds := Rect2(xform * rect.position, Vector2.ZERO)
	bounds = bounds.expand(xform * (rect.position + Vector2(rect.size.x, 0.0)))
	bounds = bounds.expand(xform * (rect.position + Vector2(rect.size.x, rect.size.y)))
	bounds = bounds.expand(xform * (rect.position + Vector2(0.0, rect.size.y)))
	return bounds

## Returns the world-space rect occupied by `sprite`, accounting for its
## texture, region cropping, offset, scale, and centered setting. Correct for
## nested sprites (uses the sprite's global transform).
static func get_sprite_world_rect(sprite: Sprite2D) -> Rect2:
	return transform_rect(get_sprite_local_rect(sprite), sprite.global_transform)

## Returns the world-space visual bounds of `node` plus all of its descendants
## by merging applicable node types recursively:
##   - Sprite2D  → texture/region rect via its global transform
##   - Control   → its global rect (e.g. Labels, TextureRects)
##   - Polygon2D → its AABB via its global transform
## Returns an empty Rect2 when no visual bounds are found.
static func get_node_world_bounds(node: Node) -> Rect2:
	var bounds := Rect2()
	var has_bounds := false
	if node is Sprite2D:
		var sprite := node as Sprite2D
		bounds = transform_rect(get_sprite_local_rect(sprite), sprite.global_transform)
		has_bounds = true
	elif node is Control:
		var control := node as Control
		bounds = control.get_global_rect()
		has_bounds = true
	elif node is Polygon2D:
		var polygon := node as Polygon2D
		var points: PackedVector2Array = polygon.polygon
		if points.size() > 0:
			var aabb := Rect2(points[0], Vector2.ZERO)
			for i in range(1, points.size()):
				aabb = aabb.expand(points[i])
			aabb.position += polygon.offset
			bounds = transform_rect(aabb, polygon.global_transform)
			has_bounds = true
	for child in node.get_children():
		var child_bounds := get_node_world_bounds(child)
		if child_bounds.size.x > 0.0 or child_bounds.size.y > 0.0:
			if has_bounds:
				bounds = bounds.merge(child_bounds)
			else:
				bounds = child_bounds
				has_bounds = true
	return bounds if has_bounds else Rect2()

## Returns the combined world-space bounds of `sprite` and all of its
## descendants (e.g. overlay labels that extend past the texture), so camera
## limits/fits keep every visual child fully in view.
static func get_sprite_bounds_including_children(sprite: Sprite2D) -> Rect2:
	var bounds := get_sprite_world_rect(sprite)
	for child in sprite.get_children():
		var child_bounds := get_node_world_bounds(child)
		if child_bounds.size.x > 0.0 or child_bounds.size.y > 0.0:
			bounds = bounds.merge(child_bounds)
	return bounds