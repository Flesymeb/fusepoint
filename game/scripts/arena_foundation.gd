extends Node3D

signal walkable_topology_bound(report: Dictionary)

const EXPECTED_SOURCE_SHA256 := "6298ee68eb4df52d4fe8bdd332a1813492de600f595c214ef934f35fd3ee3e1a"
const EXPECTED_WORLD_EXTENTS := Vector3(217.404864, 24.222379, 232.932841)
const NAVIGATION_SOURCE_GROUP := &"fusepoint_structural_navigation_source"
const DECORATIVE_COLLISION_TOKENS: Array[String] = ["decal", "2year"]

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
var topology_ready := false
var collision_source_counts := {"selected": 0, "excluded": 0}
var collision_source_triangles := {"selected": 0, "excluded": 0}
var selected_collision_sources: Array[String] = []
var excluded_collision_sources: Array[String] = []


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
		var source_path := String(mesh_instance.get_path())
		var source_faces := mesh_instance.mesh.get_faces()
		var triangle_count := source_faces.size() / 3
		if not _is_structural_collision_source(mesh_instance):
			collision_source_counts["excluded"] = int(collision_source_counts["excluded"]) + 1
			collision_source_triangles["excluded"] = int(collision_source_triangles["excluded"]) + triangle_count
			excluded_collision_sources.append(source_path)
			continue
		collision_source_counts["selected"] = int(collision_source_counts["selected"]) + 1
		collision_source_triangles["selected"] = int(collision_source_triangles["selected"]) + triangle_count
		selected_collision_sources.append(source_path)
		var to_collision := collision_inverse * mesh_instance.global_transform
		for vertex in source_faces:
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
	map_collision.add_to_group(NAVIGATION_SOURCE_GROUP)
	collision_triangle_count = faces.size() / 3
	collision_ready = true
	print("Arena structural collision built from %d triangles across %d selected sources; %d decorative sources excluded." % [collision_triangle_count, collision_source_counts["selected"], collision_source_counts["excluded"]])


func _is_structural_collision_source(mesh_instance: MeshInstance3D) -> bool:
	# The imported scene is partitioned by material. Decal partitions are visual
	# overlays with very large or coplanar faces, not opaque walkable structure.
	var source_name := String(mesh_instance.name).to_lower()
	for token in DECORATIVE_COLLISION_TOKENS:
		if token in source_name:
			return false
	return mesh_instance.visible


func _start_navigation_bake() -> void:
	if navigation_region.navigation_mesh == null:
		push_error("Arena NavigationRegion3D has no NavigationMesh resource.")
		return
	# Bake from the isolated structural collider only. Parsing the visible GLB
	# again would reintroduce the excluded decal partitions into navigation.
	navigation_region.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navigation_region.navigation_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_EXPLICIT
	navigation_region.navigation_mesh.geometry_source_group_name = NAVIGATION_SOURCE_GROUP
	navigation_region.navigation_mesh.geometry_collision_mask = map_collision.collision_layer
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
			topology_ready = true
			break
	navigation_ready = topology_ready
	if not topology_ready:
		push_warning("Arena navigation baked, but transactional anchor binding did not become valid.")


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
	var raw_edges := {
		"spawn_to_a": NavigationServer3D.map_get_path(nav_map, projected["spawn"], projected["alpha"], true),
		"a_to_b": NavigationServer3D.map_get_path(nav_map, projected["alpha"], projected["bravo"], true),
		"b_to_c": NavigationServer3D.map_get_path(nav_map, projected["bravo"], projected["charlie"], true),
	}
	var edges := {
		"spawn_to_a": _build_capsule_clear_route(raw_edges["spawn_to_a"], player, nav_map),
		"a_to_b": _build_capsule_clear_route(raw_edges["a_to_b"], player, nav_map),
		"b_to_c": _build_capsule_clear_route(raw_edges["b_to_c"], player, nav_map),
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
	var anchor_validation := {}
	if player != null:
		for id in projected:
			var target: Transform3D = Transform3D(player.global_basis, projected[id] + Vector3.UP * 0.9)
			anchor_validation[id] = player.call(&"validate_recovery_destination", target, [])
	else:
		anchor_validation["spawn"] = {"accepted": false, "failure_reason": &"player_missing"}
	var all_anchors_valid: bool = anchor_validation.size() == projected.size()
	for id in anchor_validation:
		all_anchors_valid = all_anchors_valid and anchor_validation[id].get("accepted", false) == true
	route_clearance = _validate_route_clearance(player) if connected else {}
	var all_routes_clear: bool = connected and _all_routes_clear(route_clearance)
	var first_escape: Dictionary = _first_escape_validation(edges["spawn_to_a"], player) if connected else {"accepted": false, "failure_reason": &"route_disconnected"}
	var transaction_accepted: bool = connected and all_anchors_valid and all_routes_clear and bool(first_escape.get("accepted", false))
	if transaction_accepted:
		$Alpha.global_position = projected["alpha"] + Vector3.UP * 1.2
		$Bravo.global_position = projected["bravo"] + Vector3.UP * 1.2
		$Charlie.global_position = projected["charlie"] + Vector3.UP * 1.2
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
		"anchor_validation": anchor_validation.duplicate(true),
		"capsule_clearance": route_clearance.duplicate(true),
		"first_escape": first_escape.duplicate(true),
		"all_edges_connected": connected,
		"all_anchors_valid": all_anchors_valid,
		"all_routes_clear": all_routes_clear,
		"anchors_applied": transaction_accepted,
		"failure_reason": &"" if transaction_accepted else &"route_disconnected" if not connected else &"anchor_occupancy_rejected" if not all_anchors_valid else &"route_capsule_blocked" if not all_routes_clear else &"first_escape_blocked",
	}
	walkable_topology_bound.emit(topology_binding_report.duplicate(true))
	return transaction_accepted


func _all_routes_clear(report: Dictionary) -> bool:
	for leg_id in [&"spawn_to_a", &"a_to_b", &"b_to_c"]:
		if report.get(leg_id, {}).get("clear", false) != true:
			return false
	return true


func _first_escape_validation(path: PackedVector3Array, player: CharacterBody3D) -> Dictionary:
	if path.size() < 2:
		return {"accepted": false, "failure_reason": &"route_missing"}
	var origin := path[0]
	var first_corner := _first_meaningful_corner(path, origin)
	var horizontal := first_corner - origin
	horizontal.y = 0.0
	if horizontal.length() < 0.6:
		return {"accepted": false, "failure_reason": &"first_segment_too_short"}
	var escape_target := origin + horizontal.normalized() * minf(horizontal.length(), 1.25)
	var diagnostic := _route_segment_diagnostic(origin, escape_target, player)
	diagnostic["accepted"] = float(diagnostic.get("safe_fraction", 0.0)) >= 0.985
	diagnostic["from"] = origin
	diagnostic["to"] = escape_target
	diagnostic["failure_reason"] = &"" if diagnostic["accepted"] else &"first_segment_capsule_blocked"
	return diagnostic


func _first_meaningful_corner(path: PackedVector3Array, origin: Vector3) -> Vector3:
	for corner in path:
		if Vector2(corner.x - origin.x, corner.z - origin.z).length() > 1.25:
			return corner
	return path[path.size() - 1] if not path.is_empty() else origin


func _build_capsule_clear_route(path: PackedVector3Array, player: CharacterBody3D, nav_map: RID) -> PackedVector3Array:
	if path.size() < 2:
		return path
	var repaired := PackedVector3Array([path[0]])
	for index in range(1, path.size()):
		var from := repaired[repaired.size() - 1]
		var destination := path[index]
		if _route_segment_safe_fraction(from, destination, player) >= 0.985:
			repaired.append(destination)
			continue
		var direction := destination - from
		direction.y = 0.0
		if direction.length_squared() <= 0.001:
			repaired.append(destination)
			continue
		var side := Vector3(-direction.z, 0.0, direction.x).normalized()
		var midpoint := from.lerp(destination, 0.5)
		var best_detour := Vector3.INF
		var best_length := INF
		for distance: float in [0.8, 1.2, 1.6, 2.0, 2.6]:
			for sign_value: float in [-1.0, 1.0]:
				var raw_detour: Vector3 = midpoint + side * distance * sign_value
				var detour: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, raw_detour)
				if detour.distance_to(raw_detour) > 1.0:
					continue
				if _route_segment_safe_fraction(from, detour, player) < 0.985:
					continue
				if _route_segment_safe_fraction(detour, destination, player) < 0.985:
					continue
				var length: float = from.distance_to(detour) + detour.distance_to(destination)
				if length < best_length:
					best_length = length
					best_detour = detour
		if best_detour != Vector3.INF:
			repaired.append(best_detour)
		repaired.append(destination)
	return repaired


func _route_segment_safe_fraction(from: Vector3, to: Vector3, player: CharacterBody3D) -> float:
	return float(_route_segment_diagnostic(from, to, player).get("safe_fraction", 0.0))


func _route_segment_diagnostic(from: Vector3, to: Vector3, player: CharacterBody3D) -> Dictionary:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.39
	capsule.height = 1.72
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis.IDENTITY, from + Vector3.UP * 0.9)
	query.motion = to - from
	query.margin = 0.01
	query.collision_mask = player.collision_mask if player != null else 1
	query.collide_with_areas = false
	query.collide_with_bodies = true
	if player != null:
		query.exclude = [player.get_rid()]
	var cast := get_world_3d().direct_space_state.cast_motion(query)
	var safe_fraction := float(cast[0]) if cast.size() >= 1 else 0.0
	var diagnostic := {"safe_fraction": safe_fraction, "blocker": {}}
	if safe_fraction >= 0.999:
		return diagnostic
	var probe := PhysicsShapeQueryParameters3D.new()
	probe.shape = capsule
	probe.transform = Transform3D(Basis.IDENTITY, from + Vector3.UP * 0.9 + (to - from) * minf(1.0, safe_fraction + 0.015))
	probe.margin = 0.015
	probe.collision_mask = query.collision_mask
	probe.collide_with_areas = false
	probe.collide_with_bodies = true
	probe.exclude = query.exclude
	var blockers := get_world_3d().direct_space_state.intersect_shape(probe, 4)
	if not blockers.is_empty():
		var collider: Variant = blockers[0].get("collider", null)
		diagnostic["blocker"] = {
			"collider_path": String(collider.get_path()) if collider is Node else String(collider),
			"collider_id": int(blockers[0].get("collider_id", 0)),
		}
	return diagnostic


func _validate_route_clearance(player: CharacterBody3D) -> Dictionary:
	var report := {}
	for leg_id in route_corner_chains:
		var path: PackedVector3Array = route_corner_chains[leg_id]
		var blocked_segments: Array[Dictionary] = []
		for index in range(1, path.size()):
			var from := path[index - 1] + Vector3.UP * 0.9
			var to := path[index] + Vector3.UP * 0.9
			var diagnostic := _route_segment_diagnostic(path[index - 1], path[index], player)
			var safe_fraction := float(diagnostic.get("safe_fraction", 0.0))
			if safe_fraction < 0.985:
				blocked_segments.append({
					"segment": index - 1,
					"from": from,
					"to": to,
					"safe_fraction": safe_fraction,
					"blocker": diagnostic.get("blocker", {}),
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
		"collision_source_counts": collision_source_counts,
		"collision_source_triangles": collision_source_triangles,
		"selected_collision_sources": selected_collision_sources,
		"excluded_collision_sources": excluded_collision_sources,
		"navigation_bake_started": navigation_bake_started,
		"navigation_ready": navigation_ready,
		"navigation_vertex_count": navigation_vertex_count,
		"navigation_polygon_count": navigation_polygon_count,
		"topology_ready": topology_ready,
		"ground_datum_y": 0.0,
		"topology_binding": topology_binding_report,
		"route_corner_chains": route_corner_chains,
		"route_clearance": route_clearance,
	}
