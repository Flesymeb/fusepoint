extends Node3D

signal walkable_topology_bound(report: Dictionary)

const EXPECTED_SOURCE_SHA256 := "6298ee68eb4df52d4fe8bdd332a1813492de600f595c214ef934f35fd3ee3e1a"
const EXPECTED_WORLD_EXTENTS := Vector3(217.404864, 24.222379, 232.932841)
const NAVIGATION_SOURCE_GROUP := &"fusepoint_structural_navigation_source"
const DECORATIVE_COLLISION_TOKENS: Array[String] = ["decal", "2year"]
const ROUTE_MIN_EFFECTIVE_SECONDS := 30.0
const ROUTE_MAX_EFFECTIVE_SECONDS := 45.0
const ROUTE_TARGET_EFFECTIVE_SECONDS := 37.5
# Effective route pace includes normal cover checks and the preserved 0.45 m
# step traversal; it selects product anchors only and never changes player speed.
const CALIBRATED_EFFECTIVE_ROUTE_SPEED := 2.3
const ROUTE_LEG_BUDGETS := {
	&"spawn_to_a": Vector2(30.0, 45.0),
	&"a_to_b": Vector2(35.0, 55.0),
	&"b_to_c": Vector2(40.0, 60.0),
}
const ROUTE_ENGAGEMENT_DWELL := {&"spawn_to_a": 0.0, &"a_to_b": 20.0, &"b_to_c": 30.0}
const DEPLOYMENT_CANDIDATE_OFFSETS: Array[Vector3] = [
	Vector3.ZERO,
	Vector3(5.8, 0.0, -1.7),
	Vector3(-9.2, 0.0, 2.3),
]
const ALPHA_CANDIDATE_OFFSETS: Array[Vector3] = [
	Vector3.ZERO,
	Vector3(-0.6, 0.0, -3.2),
]
const SOURCE_CLOUD_SHADER := "res://shaders/clouds.gdshader"
const SOURCE_SUN_FLARE_SCRIPT := "res://scripts/source_sun_flare.gd"
const MIGRATION_MANIFEST_PATH := "res://scenes/arena_foundation_migration_manifest.json"

@onready var map_wrapper: Node3D = $NavigationRegion3D/AuthoredEnvironmentWrapper
@onready var map_instance: Node3D = $NavigationRegion3D/AuthoredEnvironmentWrapper/StandoffArena
@onready var map_collision: StaticBody3D = $MapCollision
@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var cloud_layer: Node3D = $AtmospherePresentation/DayCloudLayer
@onready var sun_flare: Control = $AtmospherePresentation/SunFlareCanvas/DirectionalSunFlare
@onready var alpha_route_light: OmniLight3D = $AtmospherePresentation/AlphaRouteLight
@onready var bravo_route_light: OmniLight3D = $AtmospherePresentation/BravoRouteLight
@onready var mission_controller: Node = get_node("../MissionController")
@onready var deployment_anchor: Marker3D = $ProductAnchors/Deployment
@onready var alpha_anchor: Marker3D = $ProductAnchors/Alpha
@onready var bravo_anchor: Marker3D = $ProductAnchors/Bravo
@onready var charlie_anchor: Marker3D = $ProductAnchors/Charlie

var map_bounds := AABB()
var visible_mesh_count := 0
var material_slot_count := 0
var native_material_binding_count := 0
var surface_override_count := 0
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
var deployment_anchor_selection: Dictionary = {}
var last_industrial_cue_receipt: Dictionary = {}
var industrial_cue_response_count := 0
var migration_manifest: Dictionary = {}
var migration_manifest_report: Dictionary = {}


func _ready() -> void:
	navigation_region.bake_finished.connect(_on_navigation_bake_finished)
	mission_controller.connect(&"mission_event_committed", _on_mission_event_committed)
	await get_tree().process_frame
	_bind_source_atmosphere_layers()
	_sync_industrial_route_lights()
	_configure_map_materials()
	_measure_map()
	_build_map_collision()
	_load_and_validate_migration_manifest()
	_start_navigation_bake()


func _load_and_validate_migration_manifest() -> void:
	if not FileAccess.file_exists(MIGRATION_MANIFEST_PATH):
		push_error("Arena migration manifest is missing: %s" % MIGRATION_MANIFEST_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MIGRATION_MANIFEST_PATH))
	if parsed is not Dictionary:
		push_error("Arena migration manifest is not a valid JSON object.")
		return
	migration_manifest = parsed as Dictionary
	var authority := migration_manifest.get("authoritative_visual_map", {}) as Dictionary
	var child_policy := migration_manifest.get("authored_child_transforms", {}) as Dictionary
	var prohibited := migration_manifest.get("prohibited_migration_actions", {}) as Dictionary
	var declared_paths: Dictionary = {}
	var missing_paths: Array[String] = []
	for item: Variant in migration_manifest.get("retained_additive_placements", []):
		if item is not Dictionary:
			continue
		var placement := item as Dictionary
		var node_path := String(placement.get("node_path", ""))
		if node_path.is_empty():
			continue
		declared_paths[node_path] = String(placement.get("gameplay_purpose", ""))
		if get_node_or_null(NodePath(node_path)) == null:
			missing_paths.append(node_path)
	var undeclared_paths: Array[String] = []
	for node: Node in find_children("*", "Node", true, false):
		if node == map_instance or map_instance.is_ancestor_of(node):
			continue
		var relative_path := String(get_path_to(node))
		if not declared_paths.has(relative_path):
			undeclared_paths.append(relative_path)
	var prohibited_clear := true
	for value: Variant in prohibited.values():
		prohibited_clear = prohibited_clear and value == false
	var child_transforms_unchanged := (
		String(child_policy.get("status", "")) == "unchanged_from_imported_source"
		and int(child_policy.get("edited_child_count", -1)) == 0
		and int(child_policy.get("repositioned_child_count", -1)) == 0
		and int(child_policy.get("hidden_child_count", -1)) == 0
		and int(child_policy.get("extracted_child_count", -1)) == 0
		and int(child_policy.get("duplicated_child_count", -1)) == 0
	)
	var authoritative_instance_accepted := (
		int(authority.get("instance_count", 0)) == 1
		and String(authority.get("node_path", "")) == String(get_path_to(map_instance))
		and String(authority.get("wrapper_path", "")) == String(get_path_to(map_wrapper))
		and String(authority.get("source_sha256", "")) == EXPECTED_SOURCE_SHA256
	)
	migration_manifest_report = {
		"path": MIGRATION_MANIFEST_PATH,
		"manifest_id": migration_manifest.get("manifest_id", ""),
		"authoritative_instance_accepted": authoritative_instance_accepted,
		"authoritative_instance_count": authority.get("instance_count", 0),
		"authored_child_transforms_unchanged": child_transforms_unchanged,
		"declared_additive_placement_count": declared_paths.size(),
		"missing_declared_paths": missing_paths,
		"undeclared_retained_paths": undeclared_paths,
		"all_retained_additive_placements_declared": missing_paths.is_empty() and undeclared_paths.is_empty(),
		"prohibited_actions_clear": prohibited_clear,
	}
	migration_manifest_report["accepted"] = (
		authoritative_instance_accepted
		and child_transforms_unchanged
		and missing_paths.is_empty()
		and undeclared_paths.is_empty()
		and prohibited_clear
	)
	if migration_manifest_report.get("accepted", false) != true:
		push_error("Arena migration manifest does not match the retained runtime placement: %s" % migration_manifest_report)


func _process(_delta: float) -> void:
	# Result cameras can replace the active camera without replacing the source
	# flare component. Keep the product wrapper's direct source binding current.
	var active_camera := get_viewport().get_camera_3d()
	if sun_flare.get("sun") != sun or sun_flare.get("camera") != active_camera:
		sun_flare.set("sun", sun)
		sun_flare.set("camera", active_camera)


func _bind_source_atmosphere_layers() -> void:
	sun_flare.set("sun", sun)
	sun_flare.set("camera", get_viewport().get_camera_3d())


func _on_mission_event_committed(event: Dictionary) -> void:
	var kind := StringName(event.get("kind", &""))
	if kind not in [&"capture_started", &"capture_progress", &"capture_completed", &"route_unlocked", &"checkpoint_committed", &"bomb_stage_started"]:
		return
	_sync_industrial_route_lights()
	industrial_cue_response_count += 1
	last_industrial_cue_receipt = {
		"source_event_id": event.get("event_id", ""),
		"source_kind": kind,
		"authority_path": mission_controller.get_path(),
		"received_frame": Engine.get_process_frames(),
		"presented_frame": Engine.get_process_frames(),
		"frame_latency": 0,
		"alpha_energy": alpha_route_light.light_energy,
		"bravo_energy": bravo_route_light.light_energy,
		"presentation_only": true,
	}


func _sync_industrial_route_lights() -> void:
	var alpha_state := mission_controller.call(&"objective_state_for", &"alpha") as Dictionary
	var bravo_state := mission_controller.call(&"objective_state_for", &"bravo") as Dictionary
	alpha_route_light.light_color = Color(0.08, 0.82, 0.95) if alpha_state.get("legal", false) == true else Color(1.0, 0.16, 0.05)
	alpha_route_light.light_energy = 1.05 if StringName(alpha_state.get("state", &"")) == &"capturing_aegis" else 0.5 if alpha_state.get("legal", false) == true else 0.18
	bravo_route_light.light_color = Color(0.08, 0.82, 0.95) if bravo_state.get("legal", false) == true else Color(1.0, 0.16, 0.05)
	bravo_route_light.light_energy = 1.05 if StringName(bravo_state.get("state", &"")) == &"capturing_aegis" else 0.5 if bravo_state.get("legal", false) == true else 0.18


func _configure_map_materials() -> void:
	# Keep the complete authored environment on its imported material resources.
	# Previous product-side duplication severed that direct binding and made the
	# daylight defect impossible to isolate from a material override defect.
	for node in map_instance.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			material_slot_count += 1
			var source_material := mesh_instance.get_active_material(surface_index) as BaseMaterial3D
			if source_material != null:
				native_material_binding_count += 1
			if mesh_instance.get_surface_override_material(surface_index) != null:
				surface_override_count += 1


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
		if (
			topology_binding_report.get("failure_reason", &"") == &"spawn_alpha_route_budget_unavailable"
			and int(deployment_anchor_selection.get("evaluated_pair_count", 0)) > 0
		):
			break
	navigation_ready = topology_ready
	if not topology_ready:
		push_warning("Arena navigation baked, but transactional anchor binding did not become valid.")


func _bind_product_anchors() -> bool:
	var nav_map := navigation_region.get_navigation_map()
	NavigationServer3D.map_force_update(nav_map)
	var player := get_tree().get_first_node_in_group(&"player") as CharacterBody3D
	var hints := {
		"spawn": deployment_anchor.global_position,
		"alpha": alpha_anchor.global_position,
		"bravo": bravo_anchor.global_position,
		"charlie": charlie_anchor.global_position,
	}
	var projected := {}
	for id in hints:
		projected[id] = NavigationServer3D.map_get_closest_point(nav_map, hints[id])
	deployment_anchor_selection = _validate_product_anchor_pair(nav_map, projected, hints, player)
	if deployment_anchor_selection.get("accepted", false) == true:
		projected["alpha"] = deployment_anchor_selection["alpha_position"]
		projected["spawn"] = deployment_anchor_selection["position"]
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
		and _path_reaches_endpoints(raw_edges["spawn_to_a"], projected["spawn"], projected["alpha"])
		and _path_reaches_endpoints(raw_edges["a_to_b"], projected["alpha"], projected["bravo"])
		and _path_reaches_endpoints(raw_edges["b_to_c"], projected["bravo"], projected["charlie"])
		and projected["alpha"].distance_to(projected["bravo"]) > 10.0
		and projected["bravo"].distance_to(projected["charlie"]) > 10.0
	)
	var spawn_to_a_length := _path_length(edges["spawn_to_a"])
	var predicted_effective_seconds := spawn_to_a_length / CALIBRATED_EFFECTIVE_ROUTE_SPEED
	# Prediction ranks a provisional native anchor pair only. The RouteProbe's
	# fresh ordinary-input first-overlap receipt is the acceptance authority.
	var route_pair_provisional_accepted: bool = deployment_anchor_selection.get("accepted", false) == true
	var predicted_within_budget := predicted_effective_seconds >= ROUTE_MIN_EFFECTIVE_SECONDS and predicted_effective_seconds <= ROUTE_MAX_EFFECTIVE_SECONDS
	var leg_budget_predictions := _route_leg_budget_snapshot(edges)
	var all_leg_predictions_within_budget := leg_budget_predictions.values().all(func(leg: Dictionary) -> bool: return leg.get("predicted_within_budget", false) == true)
	var route_budget_accepted := false
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
	# Preserve the last accepted topology when the intact authored navigation has
	# no compliant spawn/Alpha pair. The report keeps the route-budget failure
	# explicit without disabling deployment, combat, or lifecycle foundations.
	var transaction_accepted: bool = route_pair_provisional_accepted and connected and all_anchors_valid and all_routes_clear and bool(first_escape.get("accepted", false))
	if transaction_accepted:
		$Alpha.global_position = projected["alpha"] + Vector3.UP * 1.2
		$Bravo.global_position = projected["bravo"] + Vector3.UP * 1.2
		$Charlie.global_position = projected["charlie"] + Vector3.UP * 1.2
		if player != null and player.has_method(&"bind_deployment_to_walkable"):
			var first_corner := _first_meaningful_corner(edges["spawn_to_a"], projected["spawn"])
			player.call(&"bind_deployment_to_walkable", projected["spawn"] + Vector3.UP * 0.9, first_corner + Vector3.UP * 0.9)
	var failure_reason := &""
	if not route_pair_provisional_accepted:
		failure_reason = StringName(deployment_anchor_selection.get("failure_reason", &"spawn_alpha_route_budget_unavailable"))
	elif not connected:
		failure_reason = &"route_disconnected"
	elif not all_anchors_valid:
		failure_reason = &"anchor_occupancy_rejected"
	elif not all_routes_clear:
		failure_reason = &"route_capsule_blocked"
	elif not bool(first_escape.get("accepted", false)):
		failure_reason = &"first_escape_blocked"
	else:
		failure_reason = &"spawn_alpha_route_budget_pending_observed_input"
	topology_binding_report = {
		"datum": "authored_standoff_navigation_map",
		"anchor_binding_mode": &"deterministic_candidate_transaction",
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
		"deployment_anchor_selection": deployment_anchor_selection.duplicate(true),
		"spawn_to_alpha_route_length": snappedf(spawn_to_a_length, 0.01),
		"predicted_effective_seconds": snappedf(predicted_effective_seconds, 0.01),
		"predicted_within_budget": predicted_within_budget,
		"route_budget_seconds": Vector2(ROUTE_MIN_EFFECTIVE_SECONDS, ROUTE_MAX_EFFECTIVE_SECONDS),
		"leg_budget_predictions": leg_budget_predictions,
		"all_leg_predictions_within_budget": all_leg_predictions_within_budget,
		"route_budget_accepted": route_budget_accepted,
		"route_budget_acceptance_authority": &"route_probe_first_legal_alpha_overlap",
		"route_pair_provisional_accepted": route_pair_provisional_accepted,
		"anchor_validation": anchor_validation.duplicate(true),
		"capsule_clearance": route_clearance.duplicate(true),
		"first_escape": first_escape.duplicate(true),
		"all_edges_connected": connected,
		"all_anchors_valid": all_anchors_valid,
		"all_routes_clear": all_routes_clear,
		"anchors_applied": transaction_accepted,
		"failure_reason": failure_reason,
	}
	walkable_topology_bound.emit(topology_binding_report.duplicate(true))
	return transaction_accepted


func _validate_product_anchor_pair(
	nav_map: RID,
	projected: Dictionary,
	hints: Dictionary,
	player: CharacterBody3D,
) -> Dictionary:
	if player == null:
		return {"accepted": false, "failure_reason": &"player_missing"}
	var candidate_reports: Array[Dictionary] = []
	var best_report: Dictionary = {}
	var best_score := INF
	var candidate_index := 0
	var projected_candidate_count := 0
	for spawn_offset in DEPLOYMENT_CANDIDATE_OFFSETS:
		for alpha_offset in ALPHA_CANDIDATE_OFFSETS:
			var spawn_hint: Vector3 = hints["spawn"] + spawn_offset
			var alpha_hint: Vector3 = hints["alpha"] + alpha_offset
			var spawn_position := NavigationServer3D.map_get_closest_point(nav_map, spawn_hint)
			var alpha_position := NavigationServer3D.map_get_closest_point(nav_map, alpha_hint)
			var spawn_projection_distance := spawn_hint.distance_to(spawn_position)
			var alpha_projection_distance := alpha_hint.distance_to(alpha_position)
			var candidate_id := "route_pair_%02d" % candidate_index
			candidate_index += 1
			if spawn_projection_distance > 0.75 or alpha_projection_distance > 0.75:
				candidate_reports.append({
					"candidate_id": candidate_id,
					"accepted": false,
					"failure_reason": &"candidate_projection_rejected",
					"spawn_projection_distance": snappedf(spawn_projection_distance, 0.001),
					"alpha_projection_distance": snappedf(alpha_projection_distance, 0.001),
				})
				continue
			projected_candidate_count += 1
			var candidate_projected := projected.duplicate()
			candidate_projected["spawn"] = spawn_position
			candidate_projected["alpha"] = alpha_position
			var report := _evaluate_product_anchor_pair(nav_map, candidate_projected, player)
			var predicted_seconds := float(report.get("predicted_effective_seconds", 0.0))
			var within_budget := predicted_seconds >= ROUTE_MIN_EFFECTIVE_SECONDS and predicted_seconds <= ROUTE_MAX_EFFECTIVE_SECONDS
			report["candidate_id"] = candidate_id
			report["spawn_hint"] = spawn_hint
			report["alpha_hint"] = alpha_hint
			report["spawn_projection_distance"] = snappedf(spawn_projection_distance, 0.001)
			report["alpha_projection_distance"] = snappedf(alpha_projection_distance, 0.001)
			report["predicted_within_budget"] = within_budget
			candidate_reports.append({
				"candidate_id": candidate_id,
				"accepted": report.get("accepted", false),
				"failure_reason": report.get("failure_reason", &""),
				"repaired_path_length": snappedf(float(report.get("repaired_path_length", 0.0)), 0.01),
				"predicted_effective_seconds": snappedf(predicted_seconds, 0.01),
				"predicted_within_budget": within_budget,
				"spawn_projection_distance": snappedf(spawn_projection_distance, 0.001),
				"alpha_projection_distance": snappedf(alpha_projection_distance, 0.001),
			})
			var score := absf(predicted_seconds - ROUTE_TARGET_EFFECTIVE_SECONDS)
			if not within_budget:
				score += 1000.0
			if report.get("accepted", false) == true and score < best_score:
				best_score = score
				best_report = report
	if best_report.is_empty():
		return {
			"accepted": false,
			"failure_reason": &"navigation_map_not_ready" if projected_candidate_count == 0 else &"spawn_alpha_route_budget_unavailable",
			"binding_mode": &"deterministic_candidate_transaction",
			"candidate_count": candidate_index,
			"pair_candidate_count": candidate_index,
			"evaluated_pair_count": projected_candidate_count,
			"inspected_count": candidate_reports.size(),
			"candidate_reports": candidate_reports,
		}
	best_report["binding_mode"] = &"deterministic_candidate_transaction"
	best_report["candidate_count"] = candidate_index
	best_report["pair_candidate_count"] = candidate_index
	best_report["evaluated_pair_count"] = candidate_reports.size()
	best_report["inspected_count"] = candidate_reports.size()
	best_report["candidate_reports"] = candidate_reports
	return best_report


func _evaluate_product_anchor_pair(
	nav_map: RID,
	projected: Dictionary,
	player: CharacterBody3D,
) -> Dictionary:
	var spawn_position: Vector3 = projected["spawn"]
	var alpha_position: Vector3 = projected["alpha"]
	var raw_path := NavigationServer3D.map_get_path(nav_map, spawn_position, alpha_position, true)
	if raw_path.size() < 2 or not _path_reaches_endpoints(raw_path, spawn_position, alpha_position):
		return {"accepted": false, "failure_reason": &"deterministic_spawn_alpha_disconnected"}
	var repaired_path := _build_capsule_clear_route(raw_path, player, nav_map)
	var clearance := _route_clearance_for_path(repaired_path, player)
	var first_escape := _first_escape_validation(repaired_path, player)
	var spawn_occupancy: Dictionary = player.call(
		&"validate_recovery_destination",
		Transform3D(player.global_basis, spawn_position + Vector3.UP * 0.9),
		[],
	)
	var alpha_occupancy: Dictionary = player.call(
		&"validate_recovery_destination",
		Transform3D(player.global_basis, alpha_position + Vector3.UP * 0.9),
		[],
	)
	var accepted: bool = (
		repaired_path.size() >= 2
		and clearance.get("clear", false) == true
		and first_escape.get("accepted", false) == true
		and spawn_occupancy.get("accepted", false) == true
		and alpha_occupancy.get("accepted", false) == true
	)
	var repaired_length := _path_length(repaired_path)
	return {
		"accepted": accepted,
		"failure_reason": &"" if accepted else &"deterministic_anchor_clearance_rejected",
		"anchor_ids": [&"deployment", &"alpha"],
		"position": spawn_position,
		"alpha_position": alpha_position,
		"raw_path": raw_path,
		"raw_path_length": _path_length(raw_path),
		"repaired_path": repaired_path,
		"repaired_path_length": repaired_length,
		"predicted_effective_seconds": repaired_length / CALIBRATED_EFFECTIVE_ROUTE_SPEED,
		"direct_distance": spawn_position.distance_to(alpha_position),
		"clearance": clearance,
		"first_escape": first_escape,
		"occupancy": spawn_occupancy,
		"alpha_occupancy": alpha_occupancy,
	}


func _path_length(path: PackedVector3Array) -> float:
	var length := 0.0
	for index in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
	return length


func _path_reaches_endpoints(path: PackedVector3Array, from: Vector3, to: Vector3) -> bool:
	return path.size() >= 2 and path[0].distance_to(from) <= 0.75 and path[path.size() - 1].distance_to(to) <= 0.75


func _route_leg_budget_snapshot(edges: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for leg_id: StringName in ROUTE_LEG_BUDGETS:
		var path: PackedVector3Array = edges.get(String(leg_id), PackedVector3Array())
		var path_length := _path_length(path)
		var engagement_seconds := float(ROUTE_ENGAGEMENT_DWELL.get(leg_id, 0.0))
		var predicted_seconds := path_length / CALIBRATED_EFFECTIVE_ROUTE_SPEED + engagement_seconds
		var budget: Vector2 = ROUTE_LEG_BUDGETS[leg_id]
		result[leg_id] = {
			"path_length_m": snappedf(path_length, 0.01),
			"traversal_seconds": snappedf(path_length / CALIBRATED_EFFECTIVE_ROUTE_SPEED, 0.01),
			"engagement_observation_seconds": engagement_seconds,
			"predicted_effective_seconds": snappedf(predicted_seconds, 0.01),
			"budget_seconds": budget,
			"predicted_within_budget": predicted_seconds >= budget.x and predicted_seconds <= budget.y,
		}
	return result


func _route_clearance_for_path(path: PackedVector3Array, player: CharacterBody3D) -> Dictionary:
	var blocked_segments: Array[Dictionary] = []
	for index in range(1, path.size()):
		var diagnostic := _route_segment_diagnostic(path[index - 1], path[index], player)
		if float(diagnostic.get("safe_fraction", 0.0)) < 0.985:
			blocked_segments.append({
				"segment": index - 1,
				"from": path[index - 1],
				"to": path[index],
				"diagnostic": diagnostic,
			})
	return {
		"clear": blocked_segments.is_empty(),
		"segment_count": maxi(path.size() - 1, 0),
		"blocked_segments": blocked_segments,
	}


func _is_alpha_sightline_blocked(spawn_position: Vector3, alpha_position: Vector3, player: CharacterBody3D) -> bool:
	var excluded: Array[RID] = []
	if player != null:
		excluded.append(player.get_rid())
	var query := PhysicsRayQueryParameters3D.create(
		spawn_position + Vector3.UP * 1.55,
		alpha_position + Vector3.UP * 1.2,
		player.collision_mask if player != null else 1,
		excluded,
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()


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
	var atmosphere := _atmosphere_snapshot()
	return {
		"atmosphere_binding_summary": {
			"daylight_exposure": atmosphere.get("daylight_exposure", {}),
			"source_sky_enabled": (atmosphere.get("source_sky", {}) as Dictionary).get("enabled", false),
			"source_shadows_enabled": (atmosphere.get("source_shadows", {}) as Dictionary).get("enabled", false),
			"source_ssao_enabled": (atmosphere.get("source_ssao", {}) as Dictionary).get("enabled", false),
			"cloud_direct_source_binding": (atmosphere.get("clouds", {}) as Dictionary).get("direct_source_binding", false),
			"cloud_runtime_variant_count": (atmosphere.get("clouds", {}) as Dictionary).get("runtime_variant_count", 0),
			"flare_direct_source_binding": (atmosphere.get("directional_sun_flare", {}) as Dictionary).get("direct_source_binding", false),
			"flare_sun_bound": (atmosphere.get("directional_sun_flare", {}) as Dictionary).get("sun_bound", false),
			"flare_camera_bound": (atmosphere.get("directional_sun_flare", {}) as Dictionary).get("camera_bound", false),
		},
		"asset_id": "standoff_arena_authored_environment",
		"atmosphere_layers": atmosphere,
		"source_sha256": EXPECTED_SOURCE_SHA256,
		"environment_instance_count": 1,
		"environment_instance_path": map_instance.get_path(),
		"migration_manifest": migration_manifest_report.duplicate(true),
		"wrapper_scale": map_wrapper.scale,
		"wrapper_position": map_wrapper.position,
		"measured_bounds_position": map_bounds.position,
		"measured_bounds_size": map_bounds.size,
		"expected_world_extents": EXPECTED_WORLD_EXTENTS,
		"visible_mesh_count": visible_mesh_count,
		"material_slot_count": material_slot_count,
		"native_material_binding_count": native_material_binding_count,
		"surface_override_count": surface_override_count,
		"native_materials_preserved": native_material_binding_count > 0 and surface_override_count == 0,
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
		"deployment_anchor_selection": deployment_anchor_selection,
		"industrial_cue": {
			"family_id": &"objective_bound_route_lights",
			"authority_path": mission_controller.get_path(),
			"response_count": industrial_cue_response_count,
			"last_receipt": last_industrial_cue_receipt,
			"alpha_energy": alpha_route_light.light_energy,
			"bravo_energy": bravo_route_light.light_energy,
			"presentation_only": true,
		},
	}


func _atmosphere_snapshot() -> Dictionary:
	var environment := world_environment.environment
	var cloud_sheets: Array[Dictionary] = []
	for child: Node in cloud_layer.get_children():
		var sheet := child as MeshInstance3D
		if sheet == null:
			continue
		var material := sheet.material_override as ShaderMaterial
		cloud_sheets.append({
			"path": sheet.get_path(),
			"height": sheet.global_position.y,
			"plane_size": (sheet.mesh as PlaneMesh).size if sheet.mesh is PlaneMesh else Vector2.ZERO,
			"material_bound": material != null,
			"shader_path": material.shader.resource_path if material != null and material.shader != null else "",
			"cloud_scale": material.get_shader_parameter(&"cloud_scale") if material != null else -1.0,
			"drift_speed": material.get_shader_parameter(&"drift_speed") if material != null else -1.0,
			"density": material.get_shader_parameter(&"density") if material != null else -1.0,
		})
	var flare_script := sun_flare.get_script() as Script
	var flare_camera := sun_flare.get("camera") as Camera3D
	return {
		"daylight_exposure": {
			"background_energy_multiplier": environment.background_energy_multiplier,
			"ambient_light_energy": environment.ambient_light_energy,
			"ambient_light_sky_contribution": environment.ambient_light_sky_contribution,
			"tonemap_exposure": environment.tonemap_exposure,
			"tonemap_mode": environment.tonemap_mode,
			"tonemap_white": environment.tonemap_white,
			"direct_sun_energy": sun.light_energy,
			"profile_id": &"loop35_filmic_highlight_rolloff",
			"coherent_profile_bound": is_equal_approx(environment.background_energy_multiplier, 0.8) and is_equal_approx(environment.ambient_light_energy, 0.75) and is_equal_approx(environment.ambient_light_sky_contribution, 0.7) and environment.tonemap_mode == Environment.TONE_MAPPER_FILMIC and is_equal_approx(environment.tonemap_exposure, 1.0) and is_equal_approx(environment.tonemap_white, 6.0) and is_equal_approx(sun.light_energy, 1.35),
			"highlight_recovery_calibration": true,
			"highlight_isolation": &"filmic_white_reference_only",
			"global_exposure_changed": false,
			"calibration_owner": String(get_path()),
		},
		"source_sky": {"enabled": environment.sky != null, "background_mode": environment.background_mode, "profile": &"3d_fps_map_source"},
		"source_shadows": {"enabled": sun.shadow_enabled, "max_distance": sun.directional_shadow_max_distance, "energy": sun.light_energy, "profile": &"3d_fps_map_source"},
		"source_ssao": {"enabled": environment.ssao_enabled, "radius": environment.ssao_radius, "intensity": environment.ssao_intensity, "power": environment.ssao_power, "profile": &"3d_fps_map_source"},
		"clouds": {
			"family_id": &"environment_cloud_layer",
			"enabled": cloud_layer.visible,
			"singleton_count": 1,
			"runtime_variant_count": cloud_sheets.size(),
			"source_shader_path": SOURCE_CLOUD_SHADER,
			"direct_source_binding": cloud_sheets.size() == 2 and cloud_sheets.all(func(sheet: Dictionary) -> bool: return String(sheet.get("shader_path", "")) == SOURCE_CLOUD_SHADER),
			"sheets": cloud_sheets,
			"world_height": cloud_layer.global_position.y,
			"authored_geometry_changed": false,
		},
		"directional_sun_flare": {
			"family_id": &"directional_sun_flare",
			"enabled": sun_flare.visible,
			"source_script_path": flare_script.resource_path if flare_script != null else "",
			"direct_source_binding": flare_script != null and flare_script.resource_path == SOURCE_SUN_FLARE_SCRIPT,
			"sun_bound": sun_flare.get("sun") == sun,
			"camera_bound": flare_camera != null and flare_camera.current,
			"camera_path": String(flare_camera.get_path()) if flare_camera != null else "",
			"canvas_layer": (sun_flare.get_parent() as CanvasLayer).layer,
			"changes_exposure": false,
			"presentation_only": true,
		},
	}
