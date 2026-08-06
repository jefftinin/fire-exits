class_name URLUtils
extends Object

## Reads and parses the current page's query string (web exports only).
## Returns a Dictionary of decoded key → value pairs.
static func get_params() -> Dictionary:
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

## Rebuilds ?key=...&... keeping existing params, then updates the URL via
## history.replaceState (web exports only) so the selection becomes
## deep-linkable without adding a history entry.
static func update_query(key: String, value: String) -> void:
	if not OS.has_feature("web"):
		return
	var params := get_params()
	if value.is_empty():
		params.erase(key)
	else:
		params[key] = value
	var query_parts: PackedStringArray = []
	for k in params:
		query_parts.append("%s=%s" % [str(k).uri_encode(), str(params[k]).uri_encode()])
	var new_query := "?" + "&".join(query_parts)
	JavaScriptBridge.eval("history.replaceState(null, '', '%s')" % new_query)

## Builds the full list of shareable deep-link URLs for every map/room
## combination. Base is the current page origin+path, so links work regardless
## of where the app is hosted. Room names are URI-encoded as in the live
## navigation URL updates.
##
## `map_scenes` is the "display name" → scene path dictionary. `gather_rooms`
## is a Callable that takes an instanced map Node2D and returns its room
## entries (name/position/aliases).
static func collect_deep_link_urls(map_scenes: Dictionary, gather_rooms: Callable) -> PackedStringArray:
	var urls: PackedStringArray = []
	var base: String = str(JavaScriptBridge.eval("window.location.origin + window.location.pathname"))
	# Strip a trailing "/" so we never build "page/?map=...".
	if base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	for map_name in map_scenes:
		var scene := load(map_scenes[map_name]) as PackedScene
		if scene == null:
			continue
		var instance := scene.instantiate() as Node2D
		for room in gather_rooms.call(instance):
			var map_param := str(map_name).uri_encode()
			var room_param := str(room["name"]).uri_encode()
			urls.append("%s?map=%s&room=%s" % [base, map_param, room_param])
		instance.free()
	return urls