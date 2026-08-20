extends Node3D

signal walkable_topology_bound(report: Dictionary)

const EXPECTED_SOURCE_SHA256 := "6298ee68eb4df52d4fe8bdd332a1813492de600f595c214ef934f35fd3ee3e1a"
const EXPECTED_WORLD_EXTENTS := Vector3(217.404864, 24.222379, 232.932841)

@onready var map_wrapper: Node3D = $NavigationRegion3D/AuthoredEnvironmentWrapper
@onready var map_instance: Node3D = $NavigationRegion3D/AuthoredEnvironmentWrapper/StandoffArena
@onready var map_collision: StaticBody3D = $MapCollision
@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D

var map_bounds := AABB()
var visible_mesh_count := 0
var material_slot_count := 0
var collision_triangle_count := 0
var collision_ready := false
var navigation_bake_started := false
var navigation_ready := false
var navigation_vertex_count := 0
var navigation_polygon_count := 0
var topology_binding_report: Dictionary = {}
var route_corner_chains: Dictionary = {}
var route_clearance: Dictionary = {}


func _ready() -> void:
	navigation_region.bake_finished.connect(_on_navigation_bake_finished)
	await get_tree().process_frame
	_configure_map_materials()
	_measure_map()
	_build_map_collision()
	_start_navigation_bake()


func _configure_map_materials() -> void:
	for node in map_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			material_slot_count += 1
			var source_material := mesh_instance.get_active_material(surface_index) as BaseMaterial3D
			if source_material == null:
				continue
			var material := source_material.duplicate() as BaseMaterial3D
			material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			mesh_instance.set_surface_override_material(surface_index, material)


func _measure_map() -> void:
	var has_bounds := false
	for node in map_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null or not mesh_instance.visible:
			continue
		visible_mesh_count += 1
		var world_aabb := _transform_aabb(mesh_instance.mesh.get_aabb(), mesh_instance.global_transform)
		if not has_bounds:
			map_bounds = world_aabb
			has_bounds = true
		else:
			map_bounds = map_bounds.merge(world_aabb)


func _transform_aabb(local_aabb: AABB, world_transform: Transform3D) -> AABB:
	var minimum := world_transform * local_aabb.position
	var maximum := minimum
	for x_index in 2:
		for y_index in 2:
			for z_index in 2:
				var corner := local_aabb.position + Vector3(
					local_aabb.size.x * x_index,
					local_aabb.size.y * y_index,
					local_aabb.size.z * z_index
				)
				var world_corner := world_transform * corner
				minimum = minimum.min(world_corner)
				maximum = maximum.max(world_corner)
	return AABB(minimum, maximum - minimum)


func _build_map_collision() -> void:
	var faces := PackedVector3Array()
	var collision_inverse := map_collision.global_transform.affine_inverse()
	for node in map_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var to_collision := collision_inverse * mesh_instance.global_transform
		for vertex in mesh_instance.mesh.get_faces():
			faces.append(to_collision * vertex)
	if faces.size() < 3:
		push_error("Standoff Arena exposed no usable mesh faces for collision.")
		return
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var collision_shape := CollisionShape3D.new()
	collision_shape.name = "AuthoredMapConcaveCollision"
	collision_shape.shape = shape
	map_collision.add_child(collision_shape)
	collision_triangle_count = faces.size() / 3
	collision_ready = true
	print("Arena collision built from %d triangles." % collision_triangle_count)


func _start_navigation_bake() -> void:
	if navigation_region.navigation_mesh == null:
		push_error("Arena NavigationRegion3D has no NavigationMesh resource.")
		return
	navigation_bake_started = true
	navigation_region.bake_navigation_mesh(true)


func _on_navigation_bake_finished() -> void:
	var navigation_mesh := navigation_region.navigation_mesh
	navigation_vertex_count = navigation_mesh.get_vertices().size()
	navigation_polygon_count = navigation_mesh.get_polygon_count()
	if navigation_polygon_count <= 0:
		push_warning("Arena navigation bake completed without walkable polygons.")
		return
	# Region baking finishes before the default navigation map necessarily owns
	# the new iteration. Give NavigationServer3D two physics syncs, then bind all
	# product anchors against the same live map in one transaction.
	for _sync_frame in 90:
		await get_tree().physics_frame
		NavigationServer3D.map_force_update(navigation_region.get_navigation_map())
		if _bind_product_anchors():
			break
	navigation_ready = true


func _bind_product_anchors() -> bool:
	var nav_map := navigation_region.get_navigation_map()
	NavigationServer3D.map_force_update(nav_map)
	var player := get_tree().get_first_node_in_group(&"player") as CharacterBody3D
	var hints := {
		"spawn": Vector3(0.0, 0.9, 0.0),
		"alpha": $Alpha.global_position - Vector3.UP * 1.2,
		"bravo": $Bravo.global_position - Vector3.UP * 1.2,
		"charlie": $Charlie.global_position - Vector3.UP * 1.2,
	}
	var projected := {}
	for id in hints:
		projected[id] = NavigationServer3D.map_get_closest_point(nav_map, hints[id])
	var edges := {
		"spawn_to_a": NavigationServer3D.map_get_path(nav_map, projected["spawn"], projected["alpha"], true),
		"a_to_b": NavigationServer3D.map_get_path(nav_map, projected["alpha"], projected["bravo"], true),
		"b_to_c": NavigationServer3D.map_get_path(nav_map, projected["bravo"], projected["charlie"], true),
	}
	route_corner_chains = {
		&"spawn_to_a": edges["spawn_to_a"],
		&"a_to_b": edges["a_to_b"],
		&"b_to_c": edges["b_to_c"],
	}
	var connected: bool = (
		edges["spawn_to_a"].size() >= 2
		and edges["a_to_b"].size() >= 2
		and edges["b_to_c"].size() >= 2
		and projected["alpha"].distance_to(projected["bravo"]) > 10.0
		and projected["bravo"].distance_to(projected["charlie"]) > 10.0
	)
	if connected:
		$Alpha.global_position = projected["alpha"] + Vector3.UP * 1.2
		$Bravo.global_position = projected["bravo"] + Vector3.UP * 1.2
		$Charlie.global_position = projected["charlie"] + Vector3.UP * 1.2
		route_clearance = _validate_route_clearance(player)
		if player != null and player.has_method(&"bind_deployment_to_walkable"):
			var first_corner := _first_meaningful_corner(edges["spawn_to_a"], projected["spawn"])
			player.call(&"bind_deployment_to_walkable", projected["spawn"] + Vector3.UP * 0.9, first_corner + Vector3.UP * 0.9)
	topology_binding_report = {
		"datum": "authored_standoff_navigation_map",
		"hints": hints,
		"projected": projected,
		"projection_distance": {
			"spawn": hints["spawn"].distance_to(projected["spawn"]),
			"alpha": hints["alpha"].distance_to(projected["alpha"]),
			"bravo": hints["bravo"].distance_to(projected["bravo"]),
			"charlie": hints["charlie"].distance_to(projected["charlie"]),
		},
		"edge_point_counts": {
			"spawn_to_a": edges["spawn_to_a"].size(),
			"a_to_b": edges["a_to_b"].size(),
			"b_to_c": edges["b_to_c"].size(),
		},
		"ordered_corners": route_corner_chains.duplicate(true),
		"capsule_clearance": route_clearance.duplicate(true),
		"all_edges_connected": connected,
		"anchors_applied": connected,
	}
	walkable_topology_bound.emit(topology_binding_report.duplicate(true))
	return connected


func _first_meaningful_corner(path: PackedVector3Array, origin: Vector3) -> Vector3:
	for corner in path:
		if Vector2(corner.x - origin.x, corner.z - origin.z).length() > 1.25:
			return corner
	return path[path.size() - 1] if not path.is_empty() else origin


func _validate_route_clearance(player: CharacterBody3D) -> Dictionary:
	var report := {}
	var capsule := CapsuleShape3D.new()
	# Keep the cast just clear of the supporting street surface while preserving
	# the authored player's practical radius and standing clearance.
	capsule.radius = 0.39
	capsule.height = 1.72
	for leg_id in route_corner_chains:
		var path: PackedVector3Array = route_corner_chains[leg_id]
		var blocked_segments: Array[Dictionary] = []
		for index in range(1, path.size()):
			var from := path[index - 1] + Vector3.UP * 0.9
			var to := path[index] + Vector3.UP * 0.9
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = capsule
			query.transform = Transform3D(Basis.IDENTITY, from)
			query.motion = to - from
			query.margin = 0.01
			query.collision_mask = player.collision_mask if player != null else 1
			query.collide_with_areas = false
			query.collide_with_bodies = true
			if player != null:
				query.exclude = [player.get_rid()]
			var cast := get_world_3d().direct_space_state.cast_motion(query)
			var safe_fraction := float(cast[0]) if cast.size() >= 1 else 0.0
			if safe_fraction < 0.985:
				blocked_segments.append({
					"segment": index - 1,
					"from": from,
					"to": to,
					"safe_fraction": safe_fraction,
				})
		report[leg_id] = {
			"clear": blocked_segments.is_empty(),
			"segment_count": maxi(path.size() - 1, 0),
			"blocked_segments": blocked_segments,
		}
	return report


func get_route_chain(leg_id: StringName) -> PackedVector3Array:
	return route_corner_chains.get(leg_id, PackedVector3Array())


func _mcp_state() -> Dictionary:
	return {
		"asset_id": "standoff_arena_authored_environment",
		"source_sha256": EXPECTED_SOURCE_SHA256,
		"environment_instance_count": 1,
		"environment_instance_path": map_instance.get_path(),
		"wrapper_scale": map_wrapper.scale,
		"wrapper_position": map_wrapper.position,
		"measured_bounds_position": map_bounds.position,
		"measured_bounds_size": map_bounds.size,
		"expected_world_extents": EXPECTED_WORLD_EXTENTS,
		"visible_mesh_count": visible_mesh_count,
		"material_slot_count": material_slot_count,
		"collision_ready": collision_ready,
		"collision_triangle_count": collision_triangle_count,
		"navigation_bake_started": navigation_bake_started,
		"navigation_ready": navigation_ready,
		"navigation_vertex_count": navigation_vertex_count,
		"navigation_polygon_count": navigation_polygon_count,
		"ground_datum_y": 0.0,
		"topology_binding": topology_binding_report,
		"route_corner_chains": route_corner_chains,
		"route_clearance": route_clearance,
	}
