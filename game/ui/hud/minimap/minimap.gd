extends Control

enum MapShape { CIRCLE, SQUARE }

@export var radius: float = 64.0
@export var bg_color: Color = Color(0.01, 0.025, 0.03, 0.42)
@export var border_color: Color = Color(0, 0, 0, 0)
@export var border_width: float = 0.0
@export var world_scale: float = 256.0
@export var map_shape: MapShape = MapShape.CIRCLE

@export_subgroup("Setup")
@export var player_node: Node
@export var map_root_node: Node3D

@export_subgroup("Behavior")
@export var enabled_auto_register: bool = true
@export var clamp_to_border: bool = true
@export var rotate_with_player: bool = true
@export var full_map_mode: bool = false

@export_subgroup("Icons")
@export var icons: Array[Resource]
#@export var icons := {
	#"player": Color("#e0e0e0"),
	#"enemy": Color("#e83f6a"),
	#"item": Color("#66c779")
#}
@export var icon_size: float = 16.0
@export var use_default_icons := true

@export_subgroup("Debug")
@export var show_debug: bool = false

@export_subgroup("Generated Map")
@export var use_generated_map: bool = false
@export var generated_map_resolution := Vector2i(512, 512)
@export var generated_map_padding := 1.12
@export var generated_map_camera_height := 30.0
@export var generated_map_cull_mask := 1
@export var generated_map_sample_step: float = 1.25
@export var generated_map_ground_tolerance: float = 1.25

var targets: Array = []
var _source_map_bounds := AABB()
var _has_source_map_bounds := false
var _map_bounds := AABB()
var _has_map_bounds := false
var _generated_map_viewport: SubViewport
var _generated_map_texture: Texture2D
var _generated_map_world_size := 1.0
var _generated_map_crop_rect := Rect2i()
var _generated_map_has_crop := false
var _tactical_routes: Array[PackedVector3Array] = []


func _ready() -> void:
	var diam := radius * 2.0
	custom_minimum_size = Vector2(diam, diam)
	size = Vector2(diam, diam)
	pivot_offset = Vector2(radius, radius)

	_auto_set_player()

	if enabled_auto_register: _auto_register()

	if use_default_icons and icons.is_empty():
		_load_default_icons()

	if use_generated_map:
		_setup_generated_map()

func _load_default_icons():
	var base_path := "res://ui/hud/minimap/icons/default/"

	var defaults = [
		load(base_path + "player.tres"),
		load(base_path + "enemy.tres"),
		load(base_path + "item.tres")
	]

	for d in defaults:
		if d != null:
			icons.append(d)

func _process(_delta):
	if player_node == null:
		_auto_set_player()

	targets = targets.filter(func(t):
		return is_instance_valid(t.node)
	)

	queue_redraw()

	if enabled_auto_register: _auto_register()

func _draw() -> void:
	var center = Vector2(radius, radius)
	var map_rect := Rect2(Vector2.ZERO, Vector2(radius * 2.0, radius * 2.0))

	if map_shape == MapShape.SQUARE:
		draw_rect(map_rect, bg_color, true)
	else:
		draw_circle(center, radius, bg_color, true, -1.0, true)

	if _generated_map_texture != null:
		draw_texture_rect(_generated_map_texture, map_rect, false)

	_draw_tactical_routes()

	if map_shape == MapShape.SQUARE:
		draw_rect(map_rect, border_color, false, border_width)
	else:
		draw_arc(center, radius, 0, TAU, 64, border_color, border_width, true)

	for t in targets:
		var node = t.node
		var type = t.type

		var world_pos = _get_world_2d_pos(node)
		var pos = _world_to_minimap(world_pos)

		if pos == null:
			continue

		pos = _clamp_to_map_shape(pos, center)
		if pos == null:
			continue

		var data = _get_icon_data(type)
		var override_color: Color = t.color if t.has("color") else Color.YELLOW
		var label_text: String = t.label if t.has("label") else ""

		if type == "player":
			if data != null and data.texture != null:
				_draw_icon_texture(pos, data.texture)
			else:
				_draw_player_icon(pos)
		elif data != null and data.texture != null:
			_draw_icon_texture(pos, data.texture)
		elif data != null and label_text == "":
			draw_circle(pos, 3.0, data.color, true, -1.0, true)
		elif label_text == "":
			draw_circle(pos, max(icon_size * 0.34, 4.0), override_color, true, -1.0, true)

		if label_text != "":
			draw_string(
				ThemeDB.fallback_font,
				pos + Vector2(-icon_size * 0.25, icon_size * 0.2),
				label_text,
				HORIZONTAL_ALIGNMENT_LEFT,
				icon_size * 1.2,
				max(icon_size * 0.78, 10.0),
				override_color
			)

func _draw_player_icon(pos: Vector2):
	var size = 6.0

	# direção (pra cima)
	var points = [
		Vector2(0, -size),      # ponta
		Vector2(size * 0.6, size),
		Vector2(-size * 0.6, size)
	]

	# pegar rotação do player
	var angle := 0.0

	if not rotate_with_player:
		if player_node is Node3D:
			angle = player_node.global_rotation.y
		elif player_node is Node2D:
			angle = player_node.rotation

	# rotacionar pontos
	for i in range(points.size()):
		points[i] = points[i].rotated(angle) + pos

	var player_data = _get_icon_data("player")
	var color = player_data.color if player_data else Color.WHITE

	draw_colored_polygon(points, color)
	draw_polyline(points + [points[0]], Color.WHITE, 1.0, true)

func _draw_icon_texture(pos: Vector2, texture: Texture2D):
	var size = Vector2(icon_size, icon_size)

	draw_texture_rect(
		texture,
		Rect2(pos - size * 0.5, size),
		false
	)

func _get_icon_data(type: String) -> Resource:
	for i in icons:
		if i.type == type:
			return i
	return null

func _world_to_minimap(world_pos: Vector2):
	if player_node == null:
		return null

	if full_map_mode and _has_map_bounds:
		return _world_to_full_map(world_pos)

	var center_pos = _get_world_2d_pos(player_node)
	var offset = world_pos - center_pos

	var angle := 0.0

	if player_node is Node3D:
		angle = player_node.global_rotation.y
	elif player_node is Node2D:
		angle = player_node.rotation

	var rotated = offset
	if rotate_with_player:
		rotated = offset.rotated(-angle)

	var scale = radius / world_scale

	return rotated * scale + Vector2(radius, radius)

func _clamp_to_map_shape(pos: Vector2, center: Vector2):
	var margin = 2.0
	var half_extent = max(radius - border_width - margin, 0.0)

	if map_shape == MapShape.SQUARE:
		var min_x = center.x - half_extent
		var max_x = center.x + half_extent
		var min_y = center.y - half_extent
		var max_y = center.y + half_extent
		if clamp_to_border:
			return Vector2(clampf(pos.x, min_x, max_x), clampf(pos.y, min_y, max_y))
		if pos.x < min_x or pos.x > max_x or pos.y < min_y or pos.y > max_y:
			return null
		return pos

	var offset = pos - center
	if offset.length() > half_extent:
		if clamp_to_border:
			offset = offset.normalized() * half_extent
			return center + offset
		return null
	return pos

func _world_to_full_map(world_pos: Vector2) -> Vector2:
	var center_3d := _map_center()
	var half_size := _generated_map_world_size * 0.5
	var viewport_size := Vector2(generated_map_resolution)
	var x_ratio := clampf((world_pos.x - (center_3d.x - half_size)) / _generated_map_world_size, 0.0, 1.0)
	var z_ratio := clampf((world_pos.y - (center_3d.z - half_size)) / _generated_map_world_size, 0.0, 1.0)
	var map_pos := Vector2(x_ratio * viewport_size.x, z_ratio * viewport_size.y)
	if _generated_map_has_crop and _generated_map_crop_rect.size.x > 0 and _generated_map_crop_rect.size.y > 0:
		map_pos.x = ((map_pos.x - float(_generated_map_crop_rect.position.x)) / float(_generated_map_crop_rect.size.x)) * viewport_size.x
		map_pos.y = ((map_pos.y - float(_generated_map_crop_rect.position.y)) / float(_generated_map_crop_rect.size.y)) * viewport_size.y
	return map_pos * (radius * 2.0 / viewport_size.x)

func _get_world_2d_pos(node) -> Vector2:
	if node is Node3D:
		return Vector2(node.global_position.x, node.global_position.z)
	elif node is Node2D:
		return node.global_position
	return Vector2.ZERO

func _auto_set_player():
	if player_node != null:
		# garante que está no grupo
		if not player_node.is_in_group("player"):
			player_node.add_to_group("player")
		return

	var players = get_tree().get_nodes_in_group("player")

	if players.size() > 0:
		player_node = players[0]
	else:
		if show_debug:
			print("Minimap: No player found in group 'player'")

func _auto_register():
	for icon_data in icons:
		var type = icon_data.type

		var nodes = get_tree().get_nodes_in_group(type)

		for n in nodes:
			add_target(n, type)

func add_target(node: Node, type: String):
	for t in targets:
		if t.node == node:
			return
	targets.append({ "node": node, "type": type })

func add_labeled_target(node: Node, type: String, label: String, color: Color) -> void:
	for t in targets:
		if t.node == node:
			t.type = type
			t.label = label
			t.color = color
			return
	targets.append({ "node": node, "type": type, "label": label, "color": color })


func configure_tactical_routes(routes: Array[PackedVector3Array]) -> void:
	_tactical_routes = routes
	var has_bounds := false
	var bounds := AABB()
	for route in _tactical_routes:
		for point in route:
			if not has_bounds:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(point)
	if has_bounds:
		bounds.position -= Vector3(4.0, 0.0, 4.0)
		bounds.size += Vector3(8.0, 0.0, 8.0)
		_map_bounds = bounds
		_has_map_bounds = true
		_generated_map_world_size = maxf(bounds.size.x, bounds.size.z) * generated_map_padding
	queue_redraw()


func _draw_tactical_routes() -> void:
	if not _has_map_bounds or _tactical_routes.is_empty():
		return
	var colors := [Color(0.16, 0.82, 0.92, 0.68), Color(0.95, 0.7, 0.2, 0.62), Color(1.0, 0.3, 0.18, 0.62)]
	for route_index in _tactical_routes.size():
		var route := _tactical_routes[route_index]
		var points := PackedVector2Array()
		for point in route:
			points.append(_world_to_full_map(Vector2(point.x, point.z)))
		if points.size() >= 2:
			draw_polyline(points, colors[mini(route_index, colors.size() - 1)], 2.0, true)
		for point in points:
			draw_circle(point, 1.6, colors[mini(route_index, colors.size() - 1)], true, -1.0, true)

func generate_from_map(map_root: Node3D) -> void:
	map_root_node = map_root
	use_generated_map = true
	_setup_generated_map()

func _setup_generated_map() -> void:
	if map_root_node == null or not is_inside_tree():
		return

	if is_instance_valid(_generated_map_viewport):
		_generated_map_viewport.queue_free()
		_generated_map_viewport = null

	_source_map_bounds = AABB()
	_has_source_map_bounds = false
	_collect_source_map_bounds(map_root_node)
	if not _has_source_map_bounds:
		return

	_map_bounds = _collect_playable_map_bounds(_source_map_bounds)
	if not _has_map_bounds:
		_map_bounds = _source_map_bounds
		_has_map_bounds = true

	_generated_map_world_size = max(_map_bounds.size.x, _map_bounds.size.z) * generated_map_padding
	_generated_map_crop_rect = Rect2i()
	_generated_map_has_crop = false

	var viewport := SubViewport.new()
	viewport.name = "GeneratedMapViewport"
	viewport.size = generated_map_resolution
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.world_3d = get_viewport().world_3d
	add_child(viewport)
	_generated_map_viewport = viewport

	var camera := Camera3D.new()
	camera.name = "GeneratedMapCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.cull_mask = generated_map_cull_mask
	camera.near = 0.05
	camera.far = max(_map_bounds.size.y + generated_map_camera_height + 10.0, 80.0)
	camera.size = _generated_map_world_size
	viewport.add_child(camera)

	var center := _map_center()
	camera.global_position = Vector3(
		center.x,
		_map_bounds.position.y + _map_bounds.size.y + generated_map_camera_height,
		center.z
	)
	camera.look_at(center, Vector3.FORWARD)
	camera.make_current()
	_generated_map_texture = viewport.get_texture()
	call_deferred("_trim_generated_map_texture")


func _trim_generated_map_texture() -> void:
	if not is_inside_tree() or not is_instance_valid(_generated_map_viewport):
		return
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	if not is_instance_valid(_generated_map_viewport):
		return

	var texture := _generated_map_viewport.get_texture()
	if texture == null:
		return

	var image := texture.get_image()
	if image == null or image.is_empty():
		return

	var crop_rect := _find_content_rect(image)
	if crop_rect.size.x <= 0 or crop_rect.size.y <= 0:
		return

	if crop_rect.size == Vector2i(image.get_width(), image.get_height()):
		_generated_map_texture = texture
		_generated_map_crop_rect = Rect2i()
		_generated_map_has_crop = false
		return

	var cropped := image.get_region(crop_rect)
	if cropped.is_empty():
		return

	_generated_map_texture = ImageTexture.create_from_image(cropped)
	_generated_map_crop_rect = crop_rect
	_generated_map_has_crop = true


func _find_content_rect(image: Image) -> Rect2i:
	var width := image.get_width()
	var height := image.get_height()
	if width <= 0 or height <= 0:
		return Rect2i()

	image.lock()
	var bg := Color(0, 0, 0, 0)
	var corners := [
		image.get_pixel(0, 0),
		image.get_pixel(width - 1, 0),
		image.get_pixel(0, height - 1),
		image.get_pixel(width - 1, height - 1),
	]
	for corner in corners:
		bg += corner
	bg /= float(corners.size())

	var min_x := width
	var min_y := height
	var max_x := -1
	var max_y := -1
	var threshold := 0.055
	for y in height:
		for x in width:
			var pixel := image.get_pixel(x, y)
			if _color_distance(pixel, bg) > threshold:
				if x < min_x:
					min_x = x
				if y < min_y:
					min_y = y
				if x > max_x:
					max_x = x
				if y > max_y:
					max_y = y
	image.unlock()

	if max_x < min_x or max_y < min_y:
		return Rect2i(Vector2i.ZERO, Vector2i(width, height))

	var margin := 10
	min_x = maxi(min_x - margin, 0)
	min_y = maxi(min_y - margin, 0)
	max_x = mini(max_x + margin, width - 1)
	max_y = mini(max_y + margin, height - 1)
	return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1))


func _color_distance(a: Color, b: Color) -> float:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) + absf(a.a - b.a)

func _collect_source_map_bounds(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			_include_transformed_aabb(mesh_instance.mesh.get_aabb(), mesh_instance.global_transform)

	for child in node.get_children():
		_collect_source_map_bounds(child)

func _collect_playable_map_bounds(search_bounds: AABB) -> AABB:
	var sampled_points: Array[Vector3] = []
	var viewport_world := get_viewport().world_3d
	if viewport_world == null:
		return AABB()
	var space_state: PhysicsDirectSpaceState3D = viewport_world.direct_space_state
	var step: float = max(generated_map_sample_step, min(search_bounds.size.x, search_bounds.size.z) / 48.0)
	var top_y := search_bounds.position.y + search_bounds.size.y + generated_map_camera_height + 8.0
	var bottom_y := search_bounds.position.y - 8.0
	var end_x := search_bounds.position.x + search_bounds.size.x
	var end_z := search_bounds.position.z + search_bounds.size.z

	var x := search_bounds.position.x
	while x <= end_x + 0.001:
		var z := search_bounds.position.z
		while z <= end_z + 0.001:
			var point := _find_walkable_point(space_state, Vector3(x, 0.0, z), top_y, bottom_y)
			if point.x < 9.0e5:
				sampled_points.append(point)
			z += step
		x += step

	if sampled_points.is_empty():
		return AABB()

	var ground_y := sampled_points[0].y
	for point in sampled_points:
		if point.y < ground_y:
			ground_y = point.y

	var filtered_points: Array[Vector3] = []
	var height_limit := ground_y + generated_map_ground_tolerance
	for point in sampled_points:
		if point.y <= height_limit:
			filtered_points.append(point)

	if filtered_points.is_empty():
		filtered_points = sampled_points

	var bounds := AABB()
	var has_bounds := false
	for point in filtered_points:
		if not has_bounds:
			bounds = AABB(point, Vector3.ZERO)
			has_bounds = true
		else:
			bounds = bounds.expand(point)

	_has_map_bounds = has_bounds
	return bounds

func _include_transformed_aabb(local_aabb: AABB, transform: Transform3D) -> void:
	var min_corner: Vector3 = local_aabb.position
	var max_corner: Vector3 = local_aabb.position + local_aabb.size
	var points: Array[Vector3] = [
		Vector3(min_corner.x, min_corner.y, min_corner.z),
		Vector3(min_corner.x, min_corner.y, max_corner.z),
		Vector3(min_corner.x, max_corner.y, min_corner.z),
		Vector3(min_corner.x, max_corner.y, max_corner.z),
		Vector3(max_corner.x, min_corner.y, min_corner.z),
		Vector3(max_corner.x, min_corner.y, max_corner.z),
		Vector3(max_corner.x, max_corner.y, min_corner.z),
		Vector3(max_corner.x, max_corner.y, max_corner.z),
	]
	for point in points:
		var world_point: Vector3 = transform * point
		if not _has_map_bounds:
			_map_bounds = AABB(world_point, Vector3.ZERO)
			_has_map_bounds = true
		else:
			_map_bounds = _map_bounds.expand(world_point)

func _find_walkable_point(space_state: PhysicsDirectSpaceState3D, probe: Vector3, top_y: float, bottom_y: float) -> Vector3:
	var cast_from := Vector3(probe.x, top_y, probe.z)
	var excluded: Array[RID] = []
	var best_point := Vector3(999999.0, 999999.0, 999999.0)
	for _attempt in range(12):
		var query := PhysicsRayQueryParameters3D.create(
			cast_from,
			Vector3(probe.x, bottom_y, probe.z)
		)
		query.collision_mask = 1
		query.exclude = excluded
		var hit := space_state.intersect_ray(query)
		if hit.is_empty():
			break

		var collider := hit.get("collider") as Node
		var hit_position: Vector3 = hit["position"]
		var hit_normal: Vector3 = hit["normal"]
		if hit_normal.y > 0.45:
			var source_name := _resolve_source_name(collider)
			if _is_walkable_source_name(source_name):
				var candidate := hit_position + hit_normal * 0.08
				if candidate.y < best_point.y:
					best_point = candidate

		if collider is CollisionObject3D:
			excluded.append((collider as CollisionObject3D).get_rid())
		cast_from = hit_position - Vector3.UP * 0.01

	return best_point

func _is_walkable_source_name(source_name: String) -> bool:
	if source_name.contains("sky") or source_name.contains("sphere") or source_name.contains("dome"):
		return false
	if source_name.contains("roof") or source_name.contains("rooftop"):
		return false
	if source_name.contains("street") or source_name.contains("alley") or source_name.contains("road") or source_name.contains("plaza") or source_name.contains("ground") or source_name.contains("floor") or source_name.contains("terrain"):
		return true
	return true

func _resolve_source_name(collider: Node) -> String:
	var current := collider
	var fallback := ""
	for _depth in range(8):
		if current == null:
			break
		var name_text := current.name.to_lower()
		if name_text != "":
			if fallback == "":
				fallback = name_text
			if not name_text.begins_with("object_") and not name_text.ends_with("_col") and not name_text.contains("collision"):
				return name_text
		current = current.get_parent()
	return fallback

func _map_center() -> Vector3:
	return Vector3(
		_map_bounds.position.x + _map_bounds.size.x * 0.5,
		_map_bounds.position.y + _map_bounds.size.y * 0.5,
		_map_bounds.position.z + _map_bounds.size.z * 0.5
	)
