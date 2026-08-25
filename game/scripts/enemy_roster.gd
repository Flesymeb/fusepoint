class_name FusepointEnemyRoster
extends Node3D

signal roster_ready(summary: Dictionary)
signal roster_event_committed(event: Dictionary)

const ENEMY_SCENE := preload("res://scenes/enemy_agent.tscn")
const REGION_ORDER: Array[StringName] = [&"alpha", &"bravo", &"charlie"]
const ACTOR_CAPSULE_RADIUS := 0.4
const RESERVATION_CLEARANCE := 0.6
const MIN_RESERVATION_SEPARATION := ACTOR_CAPSULE_RADIUS * 2.0 + RESERVATION_CLEARANCE
const RESERVATION_RING_RADII := [1.5, 2.25, 3.0, 4.0, 5.5, 7.0, 9.0]
const RESERVATION_ANGLE_STEPS := 16
const ACTOR_PAGE_LIMIT := 10
const QUALIFICATION_PAGE_LIMIT := 6
const PREPARED_COMBAT_STAGE_CYCLE: Array[StringName] = [&"search", &"aim", &"reload", &"hurt", &"flank"]
const ADVANCE_COMBAT_STAGE_CYCLE: Array[StringName] = [&"enemy_fire", &"nonlethal_player_hit", &"lethal_player_hit", &"reload", &"search"]
const ROSTER := [
	{"id":"rift-a-01","region":"alpha","role":"defender","slot":"alpha_core","route_pressure":false,"offset":Vector3(-1,0,-1)},
	{"id":"rift-a-02","region":"alpha","role":"approach","slot":"alpha_west_lane","route_pressure":true,"offset":Vector3(-8,0,5)},
	{"id":"rift-a-03","region":"alpha","role":"flanker","slot":"alpha_east_lane","route_pressure":true,"offset":Vector3(7,0,3)},
	{"id":"rift-b-01","region":"bravo","role":"defender","slot":"bravo_core_north","route_pressure":false,"offset":Vector3(-1,0,1)},
	{"id":"rift-b-02","region":"bravo","role":"defender","slot":"bravo_core_south","route_pressure":false,"offset":Vector3(2,0,-2)},
	{"id":"rift-b-03","region":"bravo","role":"approach","slot":"bravo_west_route","route_pressure":true,"offset":Vector3(-8,0,-5)},
	{"id":"rift-b-04","region":"bravo","role":"flanker","slot":"bravo_east_route","route_pressure":true,"offset":Vector3(8,0,-3)},
	{"id":"rift-b-05","region":"bravo","role":"fallback","slot":"bravo_fallback","route_pressure":true,"offset":Vector3(1,0,8)},
	{"id":"rift-c-01","region":"charlie","role":"defender","slot":"charlie_core_west","route_pressure":false,"offset":Vector3(-2,0,0)},
	{"id":"rift-c-02","region":"charlie","role":"defender","slot":"charlie_core_east","route_pressure":false,"offset":Vector3(2,0,1)},
	{"id":"rift-c-03","region":"charlie","role":"defender","slot":"charlie_core_rear","route_pressure":false,"offset":Vector3(0,0,3)},
	{"id":"rift-c-04","region":"charlie","role":"approach","slot":"charlie_south_route","route_pressure":true,"offset":Vector3(-4,0,-8)},
	{"id":"rift-c-05","region":"charlie","role":"approach","slot":"charlie_west_route","route_pressure":true,"offset":Vector3(-9,0,-2)},
	{"id":"rift-c-06","region":"charlie","role":"flanker","slot":"charlie_east_route","route_pressure":true,"offset":Vector3(9,0,-3)},
	{"id":"rift-c-07","region":"charlie","role":"flanker","slot":"charlie_north_route","route_pressure":true,"offset":Vector3(5,0,8)},
	{"id":"rift-c-08","region":"charlie","role":"fallback","slot":"charlie_fallback_west","route_pressure":true,"offset":Vector3(-7,0,7)},
	{"id":"rift-c-09","region":"charlie","role":"sentry","slot":"charlie_outer_south","route_pressure":true,"offset":Vector3(7,0,-9)},
	{"id":"rift-c-10","region":"charlie","role":"sentry","slot":"charlie_outer_north","route_pressure":true,"offset":Vector3(0,0,11)},
]

@export var player_path: NodePath
@export var mission_controller_path: NodePath
@export var navigation_region_path: NodePath
@export var alpha_path: NodePath
@export var bravo_path: NodePath
@export var charlie_path: NodePath

var enemies: Dictionary = {}
var activation_sequence := 0
var roster_initialized := false
var slot_projection_reports: Array[Dictionary] = []
var roster_events: Array[Dictionary] = []
var restore_epoch := 0
var restore_in_progress := false
var restore_applied_actor_count := 0
var last_restore_receipt: Dictionary = {}
var last_occupancy_receipt: Dictionary = {}
var last_spawn_occupancy_receipt: Dictionary = {}
var _roster_event_sequence := 0
var _last_progression_signature := ""
var progression_receipts: Array[Dictionary] = []
var _progression_receipt_sequence := 0
var qualification_run_id := "encounter-run-000001"
var qualification_event_sequence := 0
var qualification_actors: Dictionary = {}
var qualification_regions: Dictionary = {}
var qualification_region_milestones: Array[Dictionary] = []
var diagnostic_mode := &"player"
var _diagnostic_camera: Camera3D
var _diagnostic_actor_index := 0
var reservation_transaction_state := &"pending"
var reservation_failure: Dictionary = {}
var reservation_minimum_distance := INF
var run_epoch := 0
var last_run_epoch_receipt: Dictionary = {}
var tester_setup_request_count := 0
var last_tester_setup_receipt: Dictionary = {}
var tester_setup_history: Array[Dictionary] = []
var _tester_prepared_region: StringName = &""
var _tester_prepared_generation := 0
var _tester_advanced_region: StringName = &""
var _tester_advanced_generation := 0
var observation_skip_count := 0
var observation_skip_history: Array[Dictionary] = []
var _ordered_peer_cache: Array[Node] = []
var _peer_cache_physics_frame := -1
var _peer_cache_generation := 0

@onready var player: Node3D = get_node(player_path) as Node3D
@onready var mission_controller: Node = get_node(mission_controller_path)
@onready var navigation_region: NavigationRegion3D = get_node(navigation_region_path) as NavigationRegion3D


func _ready() -> void:
	await _wait_for_navigation()
	var reservation_succeeded := _instantiate_roster()
	# Give the scene tree and physics server one deterministic settlement boundary
	# before any hostile AI can be activated.
	await get_tree().physics_frame
	await get_tree().physics_frame
	last_spawn_occupancy_receipt = validate_restore_occupancy(player.global_position, false)
	last_spawn_occupancy_receipt["receipt_kind"] = &"initial_spawn_settlement"
	last_occupancy_receipt = last_spawn_occupancy_receipt.duplicate(true)
	roster_initialized = (
		reservation_succeeded
		and enemies.size() == 18
		and last_spawn_occupancy_receipt.get("accepted", false) == true
	)
	if roster_initialized:
		_rebuild_ordered_peer_cache()
		_initialize_qualification_ledger()
		_update_region_activation()
	var summary := _summary()
	roster_ready.emit(summary)
	if not roster_initialized:
		push_error("Fusepoint enemy roster expected 18 stable actors, got %d" % enemies.size())


func _process(_delta: float) -> void:
	if roster_initialized and not restore_in_progress and _tester_prepared_region.is_empty() and _tester_advanced_region.is_empty():
		_update_region_activation()


func _physics_process(_delta: float) -> void:
	# Actor identity and ordering are roster-owned and immutable during a run.
	# Publish one shared physics-cycle generation without enumerating or sorting
	# the scene tree from every enemy avoidance callback.
	if not roster_initialized:
		return
	var physics_frame := Engine.get_physics_frames()
	if physics_frame == _peer_cache_physics_frame:
		return
	_peer_cache_physics_frame = physics_frame
	_peer_cache_generation += 1


func _rebuild_ordered_peer_cache() -> void:
	_ordered_peer_cache.clear()
	for entry: Dictionary in ROSTER:
		var actor_id := StringName(entry["id"])
		var enemy := enemies.get(actor_id) as FusepointEnemyAgent
		if enemy != null and is_instance_valid(enemy):
			_ordered_peer_cache.append(enemy)
	_peer_cache_physics_frame = Engine.get_physics_frames()
	_peer_cache_generation += 1


func ordered_peer_cache() -> Array[Node]:
	return _ordered_peer_cache


func peer_cache_receipt() -> Dictionary:
	var callback_count := 0
	var duplicate_callback_count := 0
	var consumption_count := 0
	var callback_frame_actor_count := 0
	for enemy: FusepointEnemyAgent in _ordered_peer_cache:
		callback_count += int(enemy.get("_safe_velocity_callback_count"))
		duplicate_callback_count += int(enemy.get("_safe_velocity_duplicate_callback_count"))
		consumption_count += int(enemy.get("_navigation_safe_velocity_consumption_count"))
		if int(enemy.get("_navigation_safe_velocity_receipt_frame")) == _peer_cache_physics_frame:
			callback_frame_actor_count += 1
	return {
		"owner_path": String(get_path()) if is_inside_tree() else "",
		"physics_frame": _peer_cache_physics_frame,
		"generation": _peer_cache_generation,
		"stable_peer_count": _ordered_peer_cache.size(),
		"ordering": &"authored_roster_order",
		"scene_tree_enumeration_per_actor": false,
			"sort_per_actor": false,
			"safe_velocity_callback_count": callback_count,
			"safe_velocity_duplicate_callback_count": duplicate_callback_count,
			"safe_velocity_consumption_count": consumption_count,
			"callback_actor_count_this_physics_cycle": callback_frame_actor_count,
			"maximum_callback_admissions_per_actor_per_cycle": 1,
			"single_consumption_path": true,
			"route_reservations": FusepointEnemyAgent.route_reservation_cache_receipt(),
		}


func reset_transient_feedback() -> void:
	for enemy: FusepointEnemyAgent in enemies.values():
		enemy.reset_shot_feedback()


func set_run_epoch(epoch: int, reset_transients := true) -> bool:
	if epoch <= 0 or epoch < run_epoch:
		last_run_epoch_receipt = {
			"accepted": false,
			"requested_epoch": epoch,
			"previous_epoch": run_epoch,
			"failure_reason": &"non_monotonic_run_epoch",
		}
		return false
	var previous_epoch := run_epoch
	run_epoch = epoch
	if run_epoch > previous_epoch:
		_tester_prepared_region = &""
		_tester_prepared_generation = 0
		_tester_advanced_region = &""
		_tester_advanced_generation = 0
		_roster_event_sequence = 0
		qualification_event_sequence = 0
		qualification_run_id = "encounter-run-%06d" % run_epoch
		roster_events.clear()
		progression_receipts.clear()
		_progression_receipt_sequence = 0
	for enemy: FusepointEnemyAgent in enemies.values():
		enemy.clear_tester_prepared_hold()
		enemy.set_run_epoch(run_epoch)
		if reset_transients:
			enemy.reset_shot_feedback()
	if roster_initialized and run_epoch > previous_epoch:
		_initialize_qualification_ledger()
	last_run_epoch_receipt = {
		"accepted": true,
		"run_epoch": run_epoch,
		"previous_epoch": previous_epoch,
		"fresh_namespace": run_epoch > previous_epoch,
		"actor_count": enemies.size(),
		"transients_reset": reset_transients,
	}
	return true


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F10:
		_toggle_overhead_camera()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		_focus_active_actor()
		get_viewport().set_input_as_handled()


func _toggle_overhead_camera() -> void:
	_ensure_diagnostic_camera()
	if diagnostic_mode == &"player":
		var center := _objective_for(_active_region()).global_position
		_diagnostic_camera.global_position = center + Vector3(0.0, 34.0, 10.0)
		_diagnostic_camera.look_at(center, Vector3.UP)
		_diagnostic_camera.current = true
		diagnostic_mode = &"overhead"
	else:
		var player_camera := player.get_node_or_null("Head/Camera3D") as Camera3D
		if player_camera != null:
			player_camera.current = true
		diagnostic_mode = &"player"


func _focus_active_actor() -> void:
	_ensure_diagnostic_camera()
	var active: Array[FusepointEnemyAgent] = []
	for enemy: FusepointEnemyAgent in enemies.values():
		if enemy.mission_active and enemy.is_alive():
			active.append(enemy)
	if active.is_empty():
		return
	_diagnostic_actor_index = posmod(_diagnostic_actor_index, active.size())
	var subject := active[_diagnostic_actor_index]
	_diagnostic_actor_index += 1
	_diagnostic_camera.global_position = subject.global_position + Vector3(3.4, 2.35, 4.8)
	_diagnostic_camera.look_at(subject.global_position + Vector3.UP * 1.05, Vector3.UP)
	_diagnostic_camera.current = true
	diagnostic_mode = StringName("actor:%s" % subject.stable_id)


func _ensure_diagnostic_camera() -> void:
	if _diagnostic_camera != null:
		return
	_diagnostic_camera = Camera3D.new()
	_diagnostic_camera.name = "EncounterDiagnosticCamera"
	add_child(_diagnostic_camera)


func _active_region() -> StringName:
	var state: Dictionary = mission_controller.call(&"_mcp_state")
	var points: Dictionary = state.get("capture_points", {})
	if StringName((points.get(&"bravo", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis":
		return &"charlie"
	if StringName((points.get(&"alpha", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis":
		return &"bravo"
	return &"alpha"


func _wait_for_navigation() -> void:
	for _frame in 180:
		var arena := navigation_region.get_parent()
		if arena != null and arena.get("navigation_ready") == true:
			return
		await get_tree().physics_frame
	push_warning("Enemy roster timed out waiting for authored-map navigation.")


func _instantiate_roster() -> bool:
	var nav_map: RID = navigation_region.get_navigation_map()
	var reservation_plan := _build_reservation_plan(nav_map)
	if reservation_plan.size() != ROSTER.size():
		reservation_transaction_state = &"rejected"
		push_error("Enemy reservation transaction rejected: %s" % reservation_failure)
		return false
	reservation_transaction_state = &"committed"
	for reservation: Dictionary in reservation_plan:
		var entry: Dictionary = reservation["entry"]
		var projected: Vector3 = reservation["projected"]
		entry["reserved_position"] = projected
		var agent := ENEMY_SCENE.instantiate() as FusepointEnemyAgent
		agent.name = String(entry["id"]).replace("-", "_")
		# Global transforms only become meaningful after the actor owns its final
		# scene-tree parent. Keep the whole roster quiescent until the later
		# occupancy transaction accepts every stable ID.
		add_child(agent)
		agent.configure_roster_entry(entry, player)
		agent.set_run_epoch(run_epoch)
		var objective := _objective_for(StringName(entry["region"]))
		agent.global_position = projected
		var floor_support: Dictionary = agent.resolve_floor_support(&"initial_spawn")
		if floor_support.get("accepted", false) != true:
			reservation_transaction_state = &"rejected"
			reservation_failure = {"id": agent.stable_id, "reason": &"initial_floor_support_rejected", "receipt": floor_support}
			return false
		var objective_direction := agent.global_position.direction_to(objective.global_position)
		objective_direction.y = 0.0
		if objective_direction.length_squared() > 0.0001:
			agent.rotation = Vector3(0.0, atan2(-objective_direction.x, -objective_direction.z), 0.0)
		agent.authoritative_enemy_event.connect(_on_enemy_event)
		enemies[agent.stable_id] = agent
	return enemies.size() == ROSTER.size()


func _build_reservation_plan(nav_map: RID) -> Array[Dictionary]:
	var placed_positions: Array[Vector3] = []
	var plan: Array[Dictionary] = []
	slot_projection_reports.clear()
	reservation_failure.clear()
	reservation_minimum_distance = INF
	for index in ROSTER.size():
		var source: Dictionary = ROSTER[index]
		var entry := source.duplicate(true)
		entry["index"] = index
		entry["difficulty"] = FPSCombatEnemy.Difficulty.MEDIUM if index < 8 else FPSCombatEnemy.Difficulty.HARD
		var objective := _objective_for(StringName(entry["region"]))
		var requested: Vector3 = objective.global_position - Vector3.UP * 1.2 + (entry["offset"] as Vector3)
		var primary_projection: Vector3 = NavigationServer3D.map_get_closest_point(nav_map, requested)
		var selection := _select_distinct_navigation_slot(nav_map, requested, primary_projection, placed_positions)
		if selection.get("valid", false) != true:
			reservation_failure = {
				"id": String(entry["id"]),
				"slot": String(entry["slot"]),
				"requested": requested,
				"primary_projection": primary_projection,
				"nearest_neighbor_distance": float(selection.get("nearest_neighbor_distance", 0.0)),
				"required_separation": MIN_RESERVATION_SEPARATION,
				"search_attempts": int(selection.get("search_attempts", 0)),
			}
			slot_projection_reports.append(reservation_failure.duplicate(true))
			return []
		var projected: Vector3 = selection["projected"]
		var used_separation_fallback := not projected.is_equal_approx(primary_projection)
		var nearest_distance := _nearest_reserved_distance(projected, placed_positions)
		var nearest_distance_report := -1.0 if placed_positions.is_empty() else nearest_distance
		if not placed_positions.is_empty():
			reservation_minimum_distance = minf(reservation_minimum_distance, nearest_distance)
		placed_positions.append(projected)
		slot_projection_reports.append({
			"id": StringName(entry["id"]),
			"slot": StringName(entry["slot"]),
			"requested": requested,
			"primary_projection": primary_projection,
			"projected": projected,
			"projection_distance": requested.distance_to(projected),
			"nearest_reserved_distance": nearest_distance_report,
			"required_separation": MIN_RESERVATION_SEPARATION,
			"search_attempts": int(selection["search_attempts"]),
			"occupancy": (selection.get("occupancy", {}) as Dictionary).duplicate(true),
			"navigation_slot_bound": true,
			"separation_fallback": used_separation_fallback,
		})
		plan.append({"entry": entry, "projected": projected})
	return plan


func _select_distinct_navigation_slot(
	nav_map: RID,
	requested: Vector3,
	primary: Vector3,
	placed_positions: Array[Vector3],
) -> Dictionary:
	var search_attempts := 1
	var primary_occupancy := _slot_geometry_receipt(nav_map, primary)
	if _is_separated_slot(primary, placed_positions) and primary_occupancy.get("accepted", false) == true:
		return {
			"valid": true,
			"projected": primary,
			"nearest_neighbor_distance": -1.0 if placed_positions.is_empty() else _nearest_reserved_distance(primary, placed_positions),
			"search_attempts": search_attempts,
			"occupancy": primary_occupancy,
		}
	var best := Vector3.INF
	var best_score := INF
	var nearest_rejected := _nearest_reserved_distance(primary, placed_positions)
	var search_centers: Array[Vector3] = [primary, requested]
	for center: Vector3 in search_centers:
		for radius: float in RESERVATION_RING_RADII:
			for step: int in RESERVATION_ANGLE_STEPS:
				search_attempts += 1
				var angle := TAU * float(step) / float(RESERVATION_ANGLE_STEPS)
				var sample := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
				var projected := NavigationServer3D.map_get_closest_point(nav_map, sample)
				var nearest_distance := _nearest_reserved_distance(projected, placed_positions)
				var occupancy := _slot_geometry_receipt(nav_map, projected)
				nearest_rejected = maxf(nearest_rejected, nearest_distance)
				if projected.distance_to(sample) > 2.5 or nearest_distance < MIN_RESERVATION_SEPARATION or occupancy.get("accepted", false) != true:
					continue
				var score := requested.distance_to(projected) + projected.distance_to(sample) * 0.25
				if score < best_score:
					best = projected
					best_score = score
	if best != Vector3.INF:
		return {
			"valid": true,
			"projected": best,
			"nearest_neighbor_distance": _nearest_reserved_distance(best, placed_positions),
			"search_attempts": search_attempts,
			"occupancy": _slot_geometry_receipt(nav_map, best),
		}
	return {
		"valid": false,
		"projected": primary,
		"nearest_neighbor_distance": nearest_rejected,
		"search_attempts": search_attempts,
		"occupancy": primary_occupancy,
	}


func _slot_geometry_receipt(nav_map: RID, position: Vector3) -> Dictionary:
	var space_state := get_world_3d().direct_space_state
	var nav_position := NavigationServer3D.map_get_closest_point(nav_map, position)
	var floor_query := PhysicsRayQueryParameters3D.create(
		position + Vector3.UP * 0.8,
		position + Vector3.DOWN * 0.8,
		1,
	)
	floor_query.collide_with_areas = false
	var floor_hit := space_state.intersect_ray(floor_query)
	var capsule := CapsuleShape3D.new()
	capsule.radius = ACTOR_CAPSULE_RADIUS * 0.92
	capsule.height = 1.70
	var clearance_query := PhysicsShapeQueryParameters3D.new()
	clearance_query.shape = capsule
	clearance_query.transform = Transform3D(Basis.IDENTITY, position + Vector3.UP * 0.94)
	clearance_query.collision_mask = 1
	clearance_query.collide_with_areas = false
	clearance_query.collide_with_bodies = true
	var static_blocker_count := 0
	for hit: Dictionary in space_state.intersect_shape(clearance_query, 12):
		if hit.get("collider") is StaticBody3D:
			static_blocker_count += 1
	var navigation_error := nav_position.distance_to(position)
	return {
		"accepted": not floor_hit.is_empty() and navigation_error <= 0.35 and static_blocker_count == 0,
		"floor_support": not floor_hit.is_empty(),
		"navigation_support": navigation_error <= 0.35,
		"navigation_error": navigation_error,
		"capsule_clear": static_blocker_count == 0,
		"static_blocker_count": static_blocker_count,
	}


func _is_separated_slot(candidate: Vector3, placed_positions: Array[Vector3]) -> bool:
	return _nearest_reserved_distance(candidate, placed_positions) >= MIN_RESERVATION_SEPARATION


func _nearest_reserved_distance(candidate: Vector3, placed_positions: Array[Vector3]) -> float:
	if placed_positions.is_empty():
		return INF
	var nearest := INF
	for placed: Vector3 in placed_positions:
		nearest = minf(nearest, candidate.distance_to(placed))
	return nearest


func _update_region_activation() -> void:
	var state: Dictionary = mission_controller.call(&"_mcp_state")
	var points: Dictionary = state.get("capture_points", {})
	var alpha_secured := StringName((points.get(&"alpha", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis"
	var bravo_secured := StringName((points.get(&"bravo", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis"
	var signature := "%s:%s" % [alpha_secured, bravo_secured]
	if signature == _last_progression_signature:
		return
	_last_progression_signature = signature
	var active_region := &"charlie" if bravo_secured else &"bravo" if alpha_secured else &"alpha"
	activation_sequence += 1
	for enemy: FusepointEnemyAgent in enemies.values():
		enemy.set_mission_active(enemy.region_id == active_region, activation_sequence)
	_record_region_milestone(active_region)
	_commit_roster_event(&"region_activated", {"region": active_region, "sequence": activation_sequence})


func sync_progression_for_checkpoint() -> Dictionary:
	_last_progression_signature = ""
	_update_region_activation()
	var expected_region := _active_region()
	var expected_count := 3 if expected_region == &"alpha" else 5 if expected_region == &"bravo" else 10
	var active_ids: Array[StringName] = []
	for enemy: FusepointEnemyAgent in enemies.values():
		if enemy.mission_active:
			active_ids.append(enemy.stable_id)
	return {
		"accepted": active_ids.size() == expected_count,
		"expected_region": expected_region,
		"expected_count": expected_count,
		"active_count": active_ids.size(),
		"active_ids": active_ids,
		"activation_sequence": activation_sequence,
	}


func tester_request_alpha_presence() -> Dictionary:
	return tester_prepare_region_presence(&"alpha", tester_setup_request_count + 1)


func _fixture_includes_enemy(region_id: StringName, enemy: FusepointEnemyAgent) -> bool:
	return region_id == &"all" or enemy.region_id == region_id


func tester_prepare_region_presence(region_id: StringName, setup_generation: int) -> Dictionary:
	tester_setup_request_count += 1
	# A new bounded preparation ends the previous observation window. The new
	# selection below remains the only active region for this generation.
	_tester_advanced_region = &""
	_tester_advanced_generation = 0
	var actor_ids_before: Array[String] = []
	for actor_id: StringName in enemies:
		actor_ids_before.append(String(actor_id))
	actor_ids_before.sort()
	var mission_state_before := StringName(mission_controller.get("mission_state"))
	var checkpoint_before := int(mission_controller.get("checkpoint_version"))
	var timer_before := float(mission_controller.get("remaining_time"))
	var terminal_before := int(mission_controller.get("terminal_commit_count"))
	var mission_snapshot_before: Dictionary = mission_controller.call(&"_mcp_state")
	var points_before: Dictionary = (mission_snapshot_before.get("capture_points", {}) as Dictionary).duplicate(true)
	var expected_count := 3 if region_id == &"alpha" else 5 if region_id == &"bravo" else 10 if region_id == &"charlie" else 18 if region_id == &"all" else 0
	last_tester_setup_receipt = {
		"setup_id": "tester-%s-presence-%06d" % [String(region_id), tester_setup_request_count],
		"branch_id": StringName("combat:%s" % String(region_id)),
		"setup_generation": setup_generation,
		"kind": &"encounter_presence_prepare",
		"requested_region": region_id,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
		"route_acceptance_claimed": false,
		"run_epoch": run_epoch,
	}
	if not OS.is_debug_build():
		last_tester_setup_receipt["failure_reason"] = &"release_build_forbidden"
		_store_tester_setup_receipt()
		return last_tester_setup_receipt.duplicate(true)
	if expected_count == 0:
		last_tester_setup_receipt["failure_reason"] = &"unknown_region"
		_store_tester_setup_receipt()
		return last_tester_setup_receipt.duplicate(true)
	if setup_generation <= 0 or not roster_initialized or mission_state_before != &"active_gameplay" or restore_in_progress:
		last_tester_setup_receipt["failure_reason"] = &"authoritative_state_unavailable"
		_store_tester_setup_receipt()
		return last_tester_setup_receipt.duplicate(true)
	activation_sequence += 1
	var hold_receipts: Array[Dictionary] = []
	var stage_receipts: Array[Dictionary] = []
	var staged_index := 0
	for enemy: FusepointEnemyAgent in enemies.values():
		var included := _fixture_includes_enemy(region_id, enemy)
		enemy.set_mission_active(included, activation_sequence)
		if included:
			var hold_receipt := enemy.set_tester_prepared_hold(true, setup_generation)
			hold_receipts.append(hold_receipt)
			if hold_receipt.get("accepted", false) == true and enemy.has_method(&"tester_stage_prepared_combat"):
				stage_receipts.append(enemy.call(
					&"tester_stage_prepared_combat",
					_prepared_combat_stage_for(enemy, staged_index),
					setup_generation
				))
			staged_index += 1
	_record_region_milestone(region_id)
	var occupancy := validate_restore_occupancy(player.global_position, false)
	var actor_ids_after: Array[String] = []
	var active_region_ids: Array[String] = []
	var active_snapshots: Array[Dictionary] = []
	var active_alive_count := 0
	for actor_id: StringName in enemies:
		actor_ids_after.append(String(actor_id))
		var enemy := enemies[actor_id] as FusepointEnemyAgent
		if enemy.mission_active and _fixture_includes_enemy(region_id, enemy):
			active_region_ids.append(String(actor_id))
			active_alive_count += 1 if enemy.is_alive() else 0
			active_snapshots.append(enemy.authoritative_snapshot())
	actor_ids_after.sort()
	active_region_ids.sort()
	var mission_snapshot_after: Dictionary = mission_controller.call(&"_mcp_state")
	var reset_isolation := {
		"mission_state_unchanged": StringName(mission_controller.get("mission_state")) == mission_state_before,
		"checkpoint_version_unchanged": int(mission_controller.get("checkpoint_version")) == checkpoint_before,
		"timer_not_increased": float(mission_controller.get("remaining_time")) <= timer_before + 0.001,
		"terminal_state_unchanged": int(mission_controller.get("terminal_commit_count")) == terminal_before,
		"capture_points_unchanged": (mission_snapshot_after.get("capture_points", {}) as Dictionary) == points_before,
		"restore_transaction_idle": not restore_in_progress,
		"stable_actor_ids_unchanged": actor_ids_after == actor_ids_before,
		"no_actor_killed": active_alive_count == expected_count,
		"route_acceptance_claimed": false,
	}
	var every_actor_held := hold_receipts.size() == expected_count
	for hold_receipt: Dictionary in hold_receipts:
		every_actor_held = every_actor_held and hold_receipt.get("accepted", false) == true
	var every_actor_staged := stage_receipts.size() == expected_count
	for stage_receipt: Dictionary in stage_receipts:
		every_actor_staged = every_actor_staged and stage_receipt.get("accepted", false) == true
	var accepted: bool = occupancy.get("accepted", false) == true and active_region_ids.size() == expected_count and active_alive_count == expected_count and reset_isolation["capture_points_unchanged"] == true and every_actor_held and every_actor_staged
	last_tester_setup_receipt.merge({
		"resolved": true,
		"accepted": accepted,
		"active_region": region_id,
		"active_count": active_region_ids.size(),
		"active_alive_count": active_alive_count,
		"stable_actor_ids": active_region_ids,
		"actor_state_page": _combat_actor_page_from_snapshots(active_snapshots),
		"observation_matrix": _combat_observation_matrix_from_snapshots(active_snapshots),
		"occupancy": occupancy,
		"actor_hold_receipts": hold_receipts,
		"prepared_combat_stage_receipts": stage_receipts,
		"stable_inspection_hold": every_actor_held,
		"combat_states_staged": every_actor_staged,
		"reset_isolation": reset_isolation,
		"failure_reason": &"" if accepted else &"region_presence_validation_failed",
	}, true)
	if accepted:
		_tester_prepared_region = region_id
		_tester_prepared_generation = setup_generation
	_store_tester_setup_receipt()
	_commit_roster_event(&"tester_region_presence_resolved", last_tester_setup_receipt.duplicate(true))
	return last_tester_setup_receipt.duplicate(true)


func _prepared_combat_stage_for(enemy: FusepointEnemyAgent, staged_index: int) -> StringName:
	if enemy.tactical_role == &"defender":
		match staged_index % 3:
			0:
				return &"aim"
			1:
				return &"hurt"
			_:
				return &"reload"
	if enemy.tactical_role == &"approach":
		return &"search"
	if enemy.tactical_role == &"flanker":
		return &"flank"
	if enemy.tactical_role == &"fallback":
		return &"reload"
	if enemy.tactical_role == &"sentry":
		return &"aim"
	return PREPARED_COMBAT_STAGE_CYCLE[posmod(staged_index, PREPARED_COMBAT_STAGE_CYCLE.size())]


func _advance_combat_stage_for(enemy: FusepointEnemyAgent, staged_index: int) -> StringName:
	if staged_index == 2:
		return &"lethal_player_hit"
	if enemy.tactical_role == &"defender" and staged_index == 0:
		return &"enemy_fire"
	if enemy.tactical_role == &"flanker":
		return &"nonlethal_player_hit"
	if enemy.tactical_role == &"fallback":
		return &"reload"
	if enemy.tactical_role == &"sentry":
		return &"enemy_fire"
	return ADVANCE_COMBAT_STAGE_CYCLE[posmod(staged_index, ADVANCE_COMBAT_STAGE_CYCLE.size())]


func tester_prepare_enemy_search_state(region_id: StringName, setup_generation: int) -> Dictionary:
	var presence := tester_prepare_region_presence(region_id, setup_generation)
	var receipt := presence.duplicate(true)
	receipt["kind"] = &"enemy_search_state_prepare"
	receipt["branch_id"] = &"animation:enemy_search_root"
	receipt["search_actor_id"] = &""
	receipt["root_state"] = {}
	receipt["animation_binding_strategy"] = _animation_binding_strategy()
	if presence.get("accepted", false) != true:
		receipt["accepted"] = false
		receipt["failure_reason"] = presence.get("failure_reason", &"presence_prepare_failed")
		last_tester_setup_receipt = receipt.duplicate(true)
		_store_tester_setup_receipt()
		return receipt
	var active_ids: Array = presence.get("stable_actor_ids", [])
	if active_ids.is_empty():
		receipt["accepted"] = false
		receipt["failure_reason"] = &"no_active_actor_for_search_fixture"
		last_tester_setup_receipt = receipt.duplicate(true)
		_store_tester_setup_receipt()
		return receipt
	var actor_id := StringName(active_ids[0])
	var enemy := enemies.get(actor_id) as FusepointEnemyAgent
	if enemy == null:
		receipt["accepted"] = false
		receipt["failure_reason"] = &"selected_actor_missing"
		last_tester_setup_receipt = receipt.duplicate(true)
		_store_tester_setup_receipt()
		return receipt
	var search_receipt := enemy.tester_prepare_search_state(setup_generation) if enemy.has_method(&"tester_prepare_search_state") else {}
	var snapshot := enemy.authoritative_snapshot()
	receipt.merge({
		"resolved": search_receipt.get("resolved", false) == true,
		"accepted": search_receipt.get("accepted", false) == true,
		"search_actor_id": actor_id,
		"root_state": search_receipt.get("root_state", {}),
		"search_fixture": search_receipt,
		"animation": search_receipt.get("animation", {}),
		"stable_actor_ids": active_ids,
		"root_pitch_degrees": snapshot.get("root_pitch_degrees", 0.0),
		"root_roll_degrees": snapshot.get("root_roll_degrees", 0.0),
		"root_upright": snapshot.get("root_upright", false),
		"failure_reason": &"" if search_receipt.get("accepted", false) == true else search_receipt.get("failure_reason", &"search_fixture_rejected"),
	}, true)
	last_tester_setup_receipt = receipt.duplicate(true)
	_store_tester_setup_receipt()
	_commit_roster_event(&"tester_enemy_search_state_resolved", receipt.duplicate(true))
	return receipt


func tester_encounter_observer_transform(region_id: StringName) -> Dictionary:
	var receipt := {
		"requested": true,
		"resolved": false,
		"accepted": false,
		"region": region_id,
		"release_guard": &"OS.is_debug_build",
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	if region_id not in [&"alpha", &"bravo", &"charlie"]:
		receipt["failure_reason"] = &"unsupported_region"
		return receipt
	var objective := _objective_for(region_id)
	var nav_map: RID = navigation_region.get_navigation_map()
	var candidates := _observer_offsets_for(region_id)
	var attempts: Array[Dictionary] = []
	for offset: Vector3 in candidates:
		var requested := objective.global_position + offset
		var projected := NavigationServer3D.map_get_closest_point(nav_map, requested)
		var destination := projected + Vector3.UP * 1.18
		var look_target := objective.global_position
		var direction := look_target - destination
		direction.y = 0.0
		var yaw := atan2(-direction.x, -direction.z) if direction.length_squared() > 0.0001 else 0.0
		var transform := Transform3D(Basis(Vector3.UP, yaw), destination)
		var support := _slot_geometry_receipt(nav_map, projected)
		attempts.append({"offset": offset, "requested": requested, "projected": projected, "support": support})
		if support.get("floor_support", false) == true and support.get("navigation_support", false) == true:
			receipt.merge({
				"resolved": true,
				"accepted": true,
				"transform": transform,
				"objective_path": String(objective.get_path()),
				"attempt_count": attempts.size(),
				"attempts": attempts,
				"route_acceptance_claimed": false,
			}, true)
			return receipt
	receipt["failure_reason"] = &"no_supported_observer_transform"
	receipt["attempts"] = attempts
	return receipt


func _observer_offsets_for(region_id: StringName) -> Array[Vector3]:
	match region_id:
		&"alpha":
			return [Vector3(13.0, 0.0, 17.7), Vector3(9.0, 0.0, 13.0), Vector3(-9.0, 0.0, 13.0)]
		&"bravo":
			return [Vector3(10.0, 0.0, -12.0), Vector3(-10.0, 0.0, -10.0), Vector3(0.0, 0.0, -14.0), Vector3(12.0, 0.0, 0.0)]
		_:
			return [Vector3(-9.0, 0.0, -2.0), Vector3(9.0, 0.0, -3.0), Vector3(-4.0, 0.0, -8.0), Vector3(5.0, 0.0, 2.0)]


func _animation_binding_strategy() -> Dictionary:
	return {
		"selected_strategy": &"truthful_non_pistol_grounded_fallback_until_rifle_ready_intake",
		"strategies_compared": [
			&"restore_last_visually_accepted_baseline",
			&"repair_current_wrapper_binding",
			&"replace_with_coherent_rifle_ready_set",
			&"isolate_missing_evidence_through_fixtures",
		],
		"local_component": &"quaternius_ual1_ual2_retargeted_humanoid",
		"rifle_ready_authored_clips_available": false,
		"combat_clip_disposition": &"neutral_combat_fallback_marked_incompatible_until_rifle_ready_set",
		"root_tilt_strategy": &"actor_root_pitch_roll_locked_fixture_reachable",
		"issue_disposition": &"truthful_fallback_reported_rifle_semantic_asset_still_needed",
	}


func _combat_actor_page_from_snapshots(snapshots: Array[Dictionary]) -> Array[Dictionary]:
	var page: Array[Dictionary] = []
	for snapshot: Dictionary in snapshots:
		var inspection: Dictionary = snapshot.get("inspection_state", {})
		var presentation: Dictionary = snapshot.get("presentation", {})
		var health: Dictionary = snapshot.get("health", {})
		var last_event: Dictionary = snapshot.get("last_event", {})
		page.append({
			"id": snapshot.get("id", &""),
			"region": snapshot.get("region", &""),
			"role": snapshot.get("role", &""),
			"route_slot": snapshot.get("route_slot", &""),
			"combat_state": snapshot.get("action", &"idle"),
			"velocity": snapshot.get("velocity", Vector3.ZERO),
			"target_visible": snapshot.get("target_visible", false),
			"fire_authorized": (snapshot.get("pre_shot_authorization", {}) as Dictionary).get("accepted", false),
			"ammo": snapshot.get("ammo", 0),
			"reload_state": StringName(last_event.get("kind", &"")) in [&"reload_started", &"reload_finished"],
			"health": health.get("current", 0.0),
			"alive": snapshot.get("alive", false),
			"presentation_state": snapshot.get("presentation_state", &"inactive"),
			"animation_clip": snapshot.get("animation_name", ""),
			"animation_semantic": snapshot.get("animation_semantic", &""),
			"weapon_family_compatible": presentation.get("weapon_family_compatible", false),
			"nearest_neighbor_spacing": snapshot.get("nearest_neighbor_distance", -1.0),
			"occupancy": {
				"grounded": snapshot.get("grounded_occupancy", false),
				"capsule_clear": inspection.get("capsule_clear", false),
				"static_blockers": inspection.get("capsule_static_blockers", -1),
			},
			"last_shot_id": snapshot.get("shot_event_id", ""),
			"last_damage_event_id": (snapshot.get("shot_causality", {}) as Dictionary).get("damage_event_id", ""),
			"setup_generation": inspection.get("setup_generation", 0),
		})
	return page


func _combat_observation_matrix_from_snapshots(snapshots: Array[Dictionary]) -> Dictionary:
	var actions := {}
	var visible_count := 0
	var authorized_count := 0
	var alive_count := 0
	var compatible_count := 0
	var min_spacing := INF
	var occupancy_failures := 0
	for snapshot: Dictionary in snapshots:
		var action := StringName(snapshot.get("action", &"idle"))
		actions[action] = int(actions.get(action, 0)) + 1
		visible_count += 1 if snapshot.get("target_visible", false) else 0
		authorized_count += 1 if (snapshot.get("pre_shot_authorization", {}) as Dictionary).get("accepted", false) else 0
		alive_count += 1 if snapshot.get("alive", false) else 0
		compatible_count += 1 if (snapshot.get("presentation", {}) as Dictionary).get("weapon_family_compatible", false) else 0
		var spacing := float(snapshot.get("nearest_neighbor_distance", -1.0))
		if spacing >= 0.0:
			min_spacing = minf(min_spacing, spacing)
		var inspection: Dictionary = snapshot.get("inspection_state", {})
		if snapshot.get("grounded_occupancy", false) != true or inspection.get("capsule_clear", false) != true:
			occupancy_failures += 1
	return {
		"sampled_actor_count": snapshots.size(),
		"alive_count": alive_count,
		"target_visible_count": visible_count,
		"fire_authorized_count": authorized_count,
		"weapon_family_compatible_count": compatible_count,
		"minimum_spacing": -1.0 if is_inf(min_spacing) else min_spacing,
		"occupancy_failure_count": occupancy_failures,
		"actions_observed": actions,
		"fields": [
			&"id", &"region", &"role", &"route_slot", &"combat_state", &"velocity",
			&"target_visible", &"fire_authorized", &"ammo", &"reload_state",
			&"health", &"alive", &"presentation_state", &"nearest_neighbor_spacing",
			&"occupancy", &"last_shot_id", &"last_damage_event_id",
		],
	}


func _store_tester_setup_receipt() -> void:
	tester_setup_history.append(last_tester_setup_receipt.duplicate(true))
	while tester_setup_history.size() > 8:
		tester_setup_history.pop_front()


func contest_count(point_id: StringName, objective_position: Vector3, radius := 4.5) -> int:
	var count := 0
	for candidate: Variant in enemies.values():
		var enemy := _observation_enemy(candidate, &"contest_count")
		if enemy == null:
			continue
		if enemy.region_id == point_id and enemy.is_contesting(objective_position, radius):
			count += 1
	return count


func snapshot_all() -> Dictionary:
	var snapshots := {}
	for id: StringName in enemies:
		var enemy := _observation_enemy(enemies.get(id), &"snapshot_all", id)
		if enemy == null:
			continue
		var actor_snapshot := enemy.authoritative_snapshot()
		if actor_snapshot.get("observation_ready", false) == true:
			snapshots[id] = actor_snapshot
		else:
			_record_observation_skip(id, &"snapshot_all", &"snapshot_rejected")
	return snapshots


func _observation_enemy(candidate: Variant, context: StringName, expected_id: StringName = &"") -> FusepointEnemyAgent:
	if candidate != null and is_instance_valid(candidate) and candidate is FusepointEnemyAgent:
		var enemy := candidate as FusepointEnemyAgent
		if enemy.is_observation_ready():
			return enemy
	_record_observation_skip(expected_id, context, &"actor_not_observation_ready")
	return null


func _record_observation_skip(actor_id: StringName, context: StringName, reason: StringName) -> void:
	observation_skip_count += 1
	observation_skip_history.append({
		"actor_id": actor_id,
		"context": context,
		"reason": reason,
		"frame": Engine.get_process_frames(),
	})
	while observation_skip_history.size() > 12:
		observation_skip_history.pop_front()


func begin_restore_epoch() -> int:
	if restore_in_progress or not roster_initialized:
		return -1
	restore_epoch += 1
	_tester_prepared_region = &""
	_tester_prepared_generation = 0
	_tester_advanced_region = &""
	_tester_advanced_generation = 0
	restore_in_progress = true
	restore_applied_actor_count = 0
	last_restore_receipt.clear()
	last_occupancy_receipt.clear()
	for enemy: FusepointEnemyAgent in enemies.values():
		enemy.begin_checkpoint_restore(restore_epoch)
	return restore_epoch


func apply_restore_snapshot(saved: Dictionary, epoch: int) -> bool:
	if not restore_in_progress or epoch != restore_epoch or saved.size() != enemies.size():
		return false
	var applied := 0
	for id: StringName in enemies:
		var actor_snapshot: Dictionary = saved.get(id, saved.get(String(id), {}))
		if actor_snapshot.is_empty():
			return false
		if not (enemies[id] as FusepointEnemyAgent).apply_checkpoint_snapshot(actor_snapshot, epoch):
			return false
		applied += 1
	restore_applied_actor_count = applied
	return applied == enemies.size()


func commit_restore_epoch(epoch: int) -> Dictionary:
	if not restore_in_progress or epoch != restore_epoch or restore_applied_actor_count != enemies.size():
		return {}
	last_occupancy_receipt = validate_restore_occupancy(player.global_position)
	if last_occupancy_receipt.get("accepted", false) != true:
		return {}
	var actor_receipts: Array[Dictionary] = []
	for enemy: FusepointEnemyAgent in enemies.values():
		if not enemy.finish_checkpoint_restore(epoch):
			return {}
		var actor_snapshot := enemy.authoritative_snapshot()
		actor_receipts.append({
			"id": enemy.stable_id,
			"restored_epoch": epoch,
			"position": enemy.global_position,
			"active": actor_snapshot.get("active", false),
			"alive": actor_snapshot.get("alive", false),
			"ammo": actor_snapshot.get("ammo", 0),
			"health": (actor_snapshot.get("health", {}) as Dictionary).get("current", 0.0),
			"quiescent": true,
			"readiness": &"fresh_perception_pending",
		})
	restore_in_progress = false
	_last_progression_signature = _progression_signature()
	last_restore_receipt = {
		"restore_epoch": epoch,
		"actor_count": actor_receipts.size(),
		"all_snapshots_applied": actor_receipts.size() == enemies.size(),
		"occupancy": last_occupancy_receipt.duplicate(true),
		"actors": actor_receipts,
	}
	for enemy: FusepointEnemyAgent in enemies.values():
		_append_progression_receipt(&"restored", enemy, {
			"restore_epoch": epoch,
			"restore_committed": true,
		})
		_update_qualification_actor(&"checkpoint_restored", enemy, {
			"restore_epoch": epoch,
			"restore_committed": true,
		})
	_commit_roster_event(&"checkpoint_restore_transaction", last_restore_receipt)
	return last_restore_receipt.duplicate(true)


func validate_restore_occupancy(player_position: Vector3, require_active_layout := true) -> Dictionary:
	var ids := {}
	var positions: Array[Vector3] = []
	var actor_receipts: Array[Dictionary] = []
	var minimum_actor_distance := INF
	var minimum_player_distance := INF
	var failure_reason := &""
	var expected_region := _active_region()
	var expected_active_count := 3 if expected_region == &"alpha" else 5 if expected_region == &"bravo" else 10
	var active_count := 0
	var wrong_region_active_count := 0
	var nav_map := navigation_region.get_navigation_map()
	var space_state := get_world_3d().direct_space_state
	var actor_rids: Array[RID] = []
	for enemy: FusepointEnemyAgent in enemies.values():
		actor_rids.append(enemy.get_rid())
	for enemy: FusepointEnemyAgent in enemies.values():
		var actor_id := enemy.stable_id
		if enemy.mission_active:
			active_count += 1
			if enemy.region_id != expected_region:
				wrong_region_active_count += 1
		if ids.has(actor_id):
			failure_reason = &"duplicate_actor_id"
		ids[actor_id] = true
		var position := enemy.global_position
		if not position.is_finite():
			failure_reason = &"actor_position_not_finite"
		var nearest_actor := _nearest_reserved_distance(position, positions)
		if not positions.is_empty():
			minimum_actor_distance = minf(minimum_actor_distance, nearest_actor)
		positions.append(position)
		var player_distance := position.distance_to(player_position)
		minimum_player_distance = minf(minimum_player_distance, player_distance)
		var nav_position := NavigationServer3D.map_get_closest_point(nav_map, position)
		var navigation_error := nav_position.distance_to(position)
		var ground_query := PhysicsRayQueryParameters3D.create(
			position + Vector3.UP * 0.75,
			position + Vector3.DOWN * 0.65,
			1,
			actor_rids,
		)
		ground_query.collide_with_areas = false
		var ray_support := not space_state.intersect_ray(ground_query).is_empty()
		var direct_support: Dictionary = enemy.get("_last_floor_support_receipt") as Dictionary
		var grounded: bool = ray_support and direct_support.get("accepted", false) == true
		# Query the complete standing body volume, slightly inset from the authored
		# floor contact so floor support is not mistaken for wall occupancy.
		var clearance_shape := CapsuleShape3D.new()
		clearance_shape.radius = ACTOR_CAPSULE_RADIUS * 0.92
		clearance_shape.height = 1.70
		var clearance_query := PhysicsShapeQueryParameters3D.new()
		clearance_query.shape = clearance_shape
		clearance_query.transform = Transform3D(Basis.IDENTITY, position + Vector3.UP * 0.94)
		clearance_query.collision_mask = 1
		clearance_query.exclude = actor_rids
		clearance_query.collide_with_areas = false
		clearance_query.collide_with_bodies = true
		var static_blockers := space_state.intersect_shape(clearance_query, 8)
		if (not grounded or navigation_error > 0.75 or not static_blockers.is_empty()) and failure_reason == &"":
			failure_reason = &"actor_ground_or_static_occupancy_invalid"
		actor_receipts.append({
			"id": actor_id,
			"position": position,
			"grounded": grounded,
			"floor_support": grounded,
			"direct_floor_support": direct_support,
			"navigation_error": navigation_error,
			"capsule_clear": static_blockers.is_empty(),
			"static_blocker_count": static_blockers.size(),
			"nearest_actor_distance": -1.0 if is_inf(nearest_actor) else nearest_actor,
			"player_distance": player_distance,
		})
	if ids.size() != 18:
		failure_reason = &"stable_identity_count_invalid"
	elif minimum_actor_distance < MIN_RESERVATION_SEPARATION:
		failure_reason = &"hostile_capsule_overlap"
	elif minimum_player_distance < 1.2:
		failure_reason = &"player_hostile_separation_blocked"
	elif require_active_layout and (active_count != expected_active_count or wrong_region_active_count > 0):
		failure_reason = &"active_region_binding_invalid"
	var accepted := failure_reason == &""
	return {
		"accepted": accepted,
		"failure_reason": failure_reason,
		"actor_count": ids.size(),
		"minimum_actor_distance": -1.0 if is_inf(minimum_actor_distance) else minimum_actor_distance,
		"required_actor_distance": MIN_RESERVATION_SEPARATION,
		"minimum_player_distance": -1.0 if is_inf(minimum_player_distance) else minimum_player_distance,
		"required_player_distance": 1.2,
		"expected_active_region": expected_region,
		"expected_active_count": expected_active_count,
		"active_count": active_count,
		"wrong_region_active_count": wrong_region_active_count,
		"active_layout_required": require_active_layout,
		"settled_physics_frame": Engine.get_physics_frames(),
		"run_epoch": run_epoch,
		"actors": actor_receipts,
	}


func abort_restore_epoch(epoch: int, rollback_snapshot: Dictionary, reason: StringName) -> Dictionary:
	if epoch != restore_epoch:
		return {}
	var rollback_count := 0
	for id: StringName in enemies:
		var actor_snapshot: Dictionary = rollback_snapshot.get(id, rollback_snapshot.get(String(id), {}))
		if not actor_snapshot.is_empty() and (enemies[id] as FusepointEnemyAgent).abort_checkpoint_restore(actor_snapshot, epoch):
			rollback_count += 1
	restore_in_progress = false
	restore_applied_actor_count = 0
	last_restore_receipt = {
		"restore_epoch": epoch,
		"actor_count": enemies.size(),
		"rollback_actor_count": rollback_count,
		"committed": false,
		"quiescent": true,
		"failure_reason": reason,
	}
	return last_restore_receipt.duplicate(true)


func restore_all(saved: Dictionary) -> Dictionary:
	var epoch := begin_restore_epoch()
	if epoch < 0 or not apply_restore_snapshot(saved, epoch):
		return {}
	return commit_restore_epoch(epoch)


func _objective_for(region_id: StringName) -> Node3D:
	match region_id:
		&"alpha": return get_node(alpha_path) as Node3D
		&"bravo": return get_node(bravo_path) as Node3D
		_: return get_node(charlie_path) as Node3D


func _on_enemy_event(event: Dictionary) -> void:
	if restore_in_progress:
		return
	var actor_id := StringName(event.get("actor_id", &""))
	var enemy := enemies.get(actor_id) as FusepointEnemyAgent
	if enemy != null:
		_append_progression_receipt(StringName(event.get("kind", &"enemy_event")), enemy, event)
		_update_qualification_actor(StringName(event.get("kind", &"enemy_event")), enemy, event)
	_commit_roster_event(&"enemy_event", event)
	if event.get("kind", &"") != &"action_changed" and mission_controller.has_method(&"report_enemy_event"):
		mission_controller.call(&"report_enemy_event", event)


func _commit_roster_event(kind: StringName, payload: Dictionary) -> void:
	_roster_event_sequence += 1
	var event := {
		"event_id": "run-%06d:roster-%06d" % [run_epoch, _roster_event_sequence],
		"run_epoch": run_epoch,
		"kind": kind,
		"payload": payload.duplicate(true),
	}
	roster_events.append(event)
	while roster_events.size() > 128:
		roster_events.pop_front()
	roster_event_committed.emit(event)


func _summary() -> Dictionary:
	_refresh_qualification_live_state()
	var qualification := _qualification_summary()
	var region_counts := {&"alpha": 0, &"bravo": 0, &"charlie": 0}
	var route_pressure_counts := {&"alpha": 0, &"bravo": 0, &"charlie": 0}
	var active_count := 0
	var alive_count := 0
	var actor_index: Array[Dictionary] = []
	for candidate: Variant in enemies.values():
		var enemy := _observation_enemy(candidate, &"roster_summary")
		if enemy == null:
			continue
		region_counts[enemy.region_id] += 1
		if enemy.route_pressure:
			route_pressure_counts[enemy.region_id] += 1
		active_count += 1 if enemy.mission_active else 0
		alive_count += 1 if enemy.is_alive() else 0
		actor_index.append({
			"id": enemy.stable_id,
			"region": enemy.region_id,
			"role": enemy.tactical_role,
			"route_slot": enemy.route_slot,
			"active": enemy.mission_active,
			"alive": enemy.is_alive(),
		})
	actor_index.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("id", "")) < String(b.get("id", "")))
	var active_actor_page := combat_actor_page(_active_region(), 0, ACTOR_PAGE_LIMIT)
	return {
		"run_epoch": run_epoch,
		"peer_cache": peer_cache_receipt(),
		"last_run_epoch_receipt": last_run_epoch_receipt,
		"tester_setup_request_count": tester_setup_request_count,
		"tester_fixture_state": {
			"branch_id": last_tester_setup_receipt.get("branch_id", &""),
			"setup_generation": last_tester_setup_receipt.get("setup_generation", 0),
			"requested_region": last_tester_setup_receipt.get("requested_region", &""),
			"requested": last_tester_setup_receipt.get("requested", false),
			"resolved": last_tester_setup_receipt.get("resolved", false),
			"accepted": last_tester_setup_receipt.get("accepted", false),
			"release_guard": last_tester_setup_receipt.get("release_guard", &""),
			"active_count": last_tester_setup_receipt.get("active_count", 0),
			"active_alive_count": last_tester_setup_receipt.get("active_alive_count", 0),
			"stable_actor_ids": last_tester_setup_receipt.get("stable_actor_ids", []),
			"reset_isolation": last_tester_setup_receipt.get("reset_isolation", {}),
			"route_acceptance_claimed": false,
			"pinned_region": _tester_prepared_region,
			"pinned_generation": _tester_prepared_generation,
			"advanced_region": _tester_advanced_region,
			"advanced_generation": _tester_advanced_generation,
		},
		"last_tester_setup_receipt": last_tester_setup_receipt,
		"tester_setup_history": tester_setup_history,
		"animation_binding_strategy": _animation_binding_strategy(),
		"allocation_state": reservation_transaction_state,
		"allocation_minimum_distance": reservation_minimum_distance,
		"allocation_required_separation": MIN_RESERVATION_SEPARATION,
		"allocation_failure": reservation_failure,
		"ready": roster_initialized,
		"stable_identity_count": enemies.size(),
		"observable_identity_count": actor_index.size(),
		"observation_skip_count": observation_skip_count,
		"observation_skip_history": observation_skip_history.duplicate(true),
		"region_counts": region_counts,
		"route_pressure_counts": route_pressure_counts,
		"active_count": active_count,
		"alive_count": alive_count,
		"activation_sequence": activation_sequence,
		"restore_epoch": restore_epoch,
		"restore_in_progress": restore_in_progress,
		"restore_applied_actor_count": restore_applied_actor_count,
		"last_restore_receipt": last_restore_receipt,
		"last_occupancy_receipt": last_occupancy_receipt,
		"last_spawn_occupancy_receipt": last_spawn_occupancy_receipt,
		"slot_projection_reports": slot_projection_reports,
		"reservation_transaction_state": reservation_transaction_state,
		"reservation_failure": reservation_failure,
		"reservation_required_separation": MIN_RESERVATION_SEPARATION,
		"reservation_minimum_distance": reservation_minimum_distance,
		"unique_slot_count": _unique_slot_count(),
		"actor_index": actor_index,
		"actors": active_actor_page.get("items", []),
		"actor_page": active_actor_page,
		"actor_page_contract": {
			"method": &"combat_actor_page",
			"default_limit": ACTOR_PAGE_LIMIT,
			"stable_identity_count": enemies.size(),
		},
		"progression_receipt_count": progression_receipts.size(),
		"progression_receipts": progression_receipts,
		"qualification_run_id": qualification.get("run_id", ""),
		"qualification_event_sequence": qualification.get("event_sequence", 0),
		"qualification_actor_count": qualification.get("bounded_actor_count", 0),
		"qualification_complete_actor_count": qualification.get("complete_actor_count", 0),
		"qualification_region_milestone_count": qualification_region_milestones.size(),
		"qualification_ledger": qualification,
		"qualification_page_contract": {
			"method": &"qualification_actor_page",
			"default_limit": QUALIFICATION_PAGE_LIMIT,
			"total": qualification_actors.size(),
		},
		"last_event": roster_events.back() if not roster_events.is_empty() else {},
		"diagnostic_mode": diagnostic_mode,
}


func tester_release_prepared_region(expected_region: StringName, expected_generation: int) -> Dictionary:
	var receipt := {
		"requested": true,
		"resolved": false,
		"accepted": false,
		"expected_region": expected_region,
		"expected_generation": expected_generation,
		"prepared_region": _tester_prepared_region,
		"prepared_generation": _tester_prepared_generation,
		"release_guard": &"OS.is_debug_build",
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	if expected_region != _tester_prepared_region or expected_generation != _tester_prepared_generation:
		receipt["failure_reason"] = &"prepared_generation_mismatch"
		return receipt
	var release_receipts: Array[Dictionary] = []
	var transition_receipts: Array[Dictionary] = []
	var active_ids: Array[String] = []
	var active_snapshots: Array[Dictionary] = []
	var staged_index := 0
	for enemy: FusepointEnemyAgent in enemies.values():
		if not _fixture_includes_enemy(expected_region, enemy) or not enemy.mission_active:
			continue
		active_ids.append(String(enemy.stable_id))
		release_receipts.append(enemy.set_tester_prepared_hold(false, expected_generation))
		if enemy.has_method(&"tester_commit_combat_transition"):
			transition_receipts.append(enemy.call(
				&"tester_commit_combat_transition",
				expected_generation,
				_advance_combat_stage_for(enemy, staged_index)
			))
		active_snapshots.append(enemy.authoritative_snapshot())
		staged_index += 1
	active_ids.sort()
	var every_actor_released := not release_receipts.is_empty()
	for actor_receipt: Dictionary in release_receipts:
		every_actor_released = every_actor_released and actor_receipt.get("accepted", false) == true
	var transition_summary := _combat_transition_causality_summary(transition_receipts)
	if not every_actor_released:
		receipt["failure_reason"] = &"actor_release_failed"
		receipt["actor_release_receipts"] = release_receipts
		return receipt
	if transition_summary.get("accepted", false) != true:
		receipt["failure_reason"] = transition_summary.get("failure_reason", &"combat_transition_causality_failed")
		receipt["actor_release_receipts"] = release_receipts
		receipt["combat_transition_receipts"] = transition_receipts
		receipt["combat_causality_summary"] = transition_summary
		return receipt
	# Keep the released region selected for a bounded, inspectable observation
	# window. Actors now run their ordinary AI; only the debug region selector is
	# pinned until the next prepare or lifecycle reset.
	_tester_advanced_region = expected_region
	_tester_advanced_generation = expected_generation
	_tester_prepared_region = &""
	_tester_prepared_generation = 0
	receipt.merge({
		"resolved": true,
		"accepted": true,
		"failure_reason": &"",
		"active_stable_ids": active_ids,
		"active_count": active_ids.size(),
		"actor_state_page": _combat_actor_page_from_snapshots(active_snapshots),
		"observation_matrix": _combat_observation_matrix_from_snapshots(active_snapshots),
		"observation_region": _tester_advanced_region,
		"observation_generation": _tester_advanced_generation,
		"actor_release_receipts": release_receipts,
		"combat_transition_receipts": transition_receipts,
		"combat_causality_summary": transition_summary,
		"combat_authority": &"ordinary_enemy_physics_perception_navigation_fire",
		"route_acceptance_claimed": false,
	}, true)
	return receipt


func combat_actor_page(region_id: StringName = &"", offset := 0, limit := ACTOR_PAGE_LIMIT) -> Dictionary:
	var ids: Array[StringName] = []
	for actor_id: StringName in enemies:
		var enemy := _observation_enemy(enemies.get(actor_id), &"combat_actor_page_index", actor_id)
		if enemy != null and (region_id.is_empty() or enemy.region_id == region_id):
			ids.append(actor_id)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	var bounded_offset := clampi(offset, 0, ids.size())
	var bounded_limit := clampi(limit, 1, ACTOR_PAGE_LIMIT)
	var end := mini(bounded_offset + bounded_limit, ids.size())
	var items: Array[Dictionary] = []
	for index in range(bounded_offset, end):
		var enemy := _observation_enemy(enemies.get(ids[index]), &"combat_actor_page_item", ids[index])
		if enemy != null:
			items.append(_compact_actor_state(enemy))
	return {
		"requested_region": region_id,
		"requested_offset": offset,
		"requested_limit": limit,
		"resolved_offset": bounded_offset,
		"resolved_limit": bounded_limit,
		"total": ids.size(),
		"returned": items.size(),
		"truncated": end < ids.size(),
		"next_offset": end if end < ids.size() else -1,
		"items": items,
	}


func _combat_transition_causality_summary(transition_receipts: Array[Dictionary]) -> Dictionary:
	var shot_ids: Array[String] = []
	var attack_receipt_count := 0
	var accepted_shot_or_negative_count := 0
	var direct_fixture_damage_count := 0
	var ammo_commit_total := 0
	var player_damage_applied_count := 0
	var player_health_delta_total := 0.0
	var invalid_attack_receipts: Array[Dictionary] = []
	var modes: Array[StringName] = []
	for transition: Dictionary in transition_receipts:
		var mode := StringName(transition.get("mode", &""))
		if mode not in modes:
			modes.append(mode)
		var attack: Dictionary = transition.get("attack_report", {})
		if attack.is_empty():
			continue
		attack_receipt_count += 1
		if String(attack.get("shot_id", "")).is_empty():
			invalid_attack_receipts.append({
				"actor_id": transition.get("actor_id", &""),
				"mode": mode,
				"reason": &"missing_shot_id",
				"attack_reason": attack.get("reason", &""),
			})
			continue
		shot_ids.append(String(attack.get("shot_id", "")))
		if attack.get("accepted_shot_or_valid_negative", false) == true:
			accepted_shot_or_negative_count += 1
		else:
			invalid_attack_receipts.append({
				"actor_id": transition.get("actor_id", &""),
				"mode": mode,
				"reason": &"shot_not_accepted_or_negative",
				"attack_result": attack.get("result", &""),
				"attack_reason": attack.get("reason", &""),
			})
		if attack.get("fixture_direct_damage", false) == true:
			direct_fixture_damage_count += 1
		ammo_commit_total += int(attack.get("ammo_commit", 0))
		if attack.get("applied", false) == true:
			player_damage_applied_count += 1
			var before := float(attack.get("health_before", -1.0))
			var after := float(attack.get("health_after", before))
			if before >= 0.0 and after >= 0.0:
				player_health_delta_total += before - after
	var accepted := (
		attack_receipt_count > 0
		and accepted_shot_or_negative_count == attack_receipt_count
		and direct_fixture_damage_count == 0
		and ammo_commit_total >= attack_receipt_count
		and invalid_attack_receipts.is_empty()
	)
	return {
		"accepted": accepted,
		"failure_reason": &"" if accepted else &"combat_transition_causality_failed",
		"transition_count": transition_receipts.size(),
		"attack_receipt_count": attack_receipt_count,
		"accepted_shot_or_valid_negative_count": accepted_shot_or_negative_count,
		"direct_fixture_damage_count": direct_fixture_damage_count,
		"ammo_commit_total": ammo_commit_total,
		"player_damage_applied_count": player_damage_applied_count,
		"player_health_delta_total": player_health_delta_total,
		"shot_ids": shot_ids,
		"modes": modes,
		"invalid_attack_receipts": invalid_attack_receipts,
		"causality_contract": &"advance_fixtures_call_authoritative_enemy_shot_only",
	}


func _compact_actor_state(enemy: FusepointEnemyAgent) -> Dictionary:
	var snapshot := enemy.authoritative_snapshot()
	var inspection: Dictionary = snapshot.get("inspection_state", {})
	var health: Dictionary = snapshot.get("health", {})
	var feedback: Dictionary = snapshot.get("shot_feedback", {})
	return {
		"id": snapshot.get("id", enemy.stable_id),
		"region": snapshot.get("region", enemy.region_id),
		"role": snapshot.get("role", enemy.tactical_role),
		"route_slot": snapshot.get("route_slot", enemy.route_slot),
		"active": snapshot.get("active", false),
		"alive": snapshot.get("alive", false),
		"health": health.get("current", 0.0),
		"ammo": snapshot.get("ammo", 0),
		"position": inspection.get("position", enemy.global_position),
		"velocity": snapshot.get("velocity", Vector3.ZERO),
		"grounded_occupancy": snapshot.get("grounded_occupancy", false),
		"capsule_clear": inspection.get("capsule_clear", false),
		"nearest_neighbor_distance": snapshot.get("nearest_neighbor_distance", -1.0),
		"target_visible": snapshot.get("target_visible", false),
		"fire_block_reason": snapshot.get("fire_block_reason", &"unknown"),
		"shot_event_id": snapshot.get("shot_event_id", ""),
		"action": snapshot.get("action", &"idle"),
		"animation_semantic": snapshot.get("animation_semantic", &""),
		"animation_name": snapshot.get("animation_name", ""),
		"animation_normalized_time": snapshot.get("animation_normalized_time", 0.0),
		"animation_playing": snapshot.get("animation_playing", false),
		"animation_state_change_count": snapshot.get("animation_state_change_count", 0),
		"rifle_action_progress": snapshot.get("rifle_action_progress", 0.0),
		"weapon_family": snapshot.get("weapon_family", &"unbound"),
		"weapon_family_compatible": snapshot.get("weapon_family_compatible", false),
		"weapon_socket_bound": snapshot.get("weapon_socket_bound", false),
		"weapon_attached": snapshot.get("weapon_attached", false),
		"root_pitch_degrees": snapshot.get("root_pitch_degrees", 0.0),
		"root_roll_degrees": snapshot.get("root_roll_degrees", 0.0),
		"root_upright": snapshot.get("root_upright", false),
		"aim_pitch_degrees": snapshot.get("aim_pitch_degrees", 0.0),
		"restore_epoch": snapshot.get("restore_epoch", 0),
		"setup_generation": inspection.get("setup_generation", _tester_prepared_generation),
		"tester_prepared_hold": inspection.get("tester_prepared_hold", false),
		"shot_feedback": {
			"active_effect_count": feedback.get("active_effect_count", 0),
			"presented_event_count": feedback.get("presented_event_count", 0),
			"duplicate_event_count": feedback.get("duplicate_event_count", 0),
		},
		"last_event": snapshot.get("last_event", {}),
	}


func _unique_slot_count() -> int:
	var slots := {}
	for enemy: FusepointEnemyAgent in enemies.values():
		slots[enemy.route_slot] = true
	return slots.size()


func _progression_signature() -> String:
	var state: Dictionary = mission_controller.call(&"_mcp_state")
	var points: Dictionary = state.get("capture_points", {})
	var alpha_secured := StringName((points.get(&"alpha", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis"
	var bravo_secured := StringName((points.get(&"bravo", {}) as Dictionary).get("state", &"held_rift")) == &"secured_aegis"
	return "%s:%s" % [alpha_secured, bravo_secured]


func _initialize_qualification_ledger() -> void:
	qualification_event_sequence = 0
	qualification_actors.clear()
	qualification_regions.clear()
	qualification_region_milestones.clear()
	for region_id in REGION_ORDER:
		qualification_regions[region_id] = {
			"region": region_id,
			"activated": false,
			"activation_count": 0,
			"first_activation_sequence": 0,
			"latest_activation_sequence": 0,
			"active_actor_ids": [],
		}
	for enemy: FusepointEnemyAgent in enemies.values():
		qualification_actors[enemy.stable_id] = {
			"actor_id": enemy.stable_id,
			"region": enemy.region_id,
			"role": enemy.tactical_role,
			"route_slot": enemy.route_slot,
			"roster_index": enemy.roster_index,
			"route_pressure": enemy.route_pressure,
			"activation_sequences": [],
			"event_counts": {},
			"state_coverage": {
				"perception": false,
				"navigation": false,
				"aim": false,
				"fire": false,
				"reload": false,
				"hurt": false,
				"death": false,
				"blocked_fire": false,
			},
			"first_event_sequence": 0,
			"last_event_sequence": 0,
			"latest": {},
		}


func _record_region_milestone(region_id: StringName) -> void:
	var active_ids: Array[StringName] = []
	for enemy: FusepointEnemyAgent in enemies.values():
		if enemy.mission_active:
			active_ids.append(enemy.stable_id)
			var actor: Dictionary = qualification_actors.get(enemy.stable_id, {})
			var sequences: Array = actor.get("activation_sequences", [])
			if not sequences.has(activation_sequence):
				sequences.append(activation_sequence)
			actor["activation_sequences"] = sequences
	active_ids.sort()
	var region: Dictionary = qualification_regions.get(region_id, {})
	region["activated"] = true
	region["activation_count"] = int(region.get("activation_count", 0)) + 1
	region["first_activation_sequence"] = activation_sequence if int(region.get("first_activation_sequence", 0)) == 0 else region["first_activation_sequence"]
	region["latest_activation_sequence"] = activation_sequence
	region["active_actor_ids"] = active_ids.duplicate()
	qualification_regions[region_id] = region
	qualification_region_milestones.append({
		"region": region_id,
		"activation_sequence": activation_sequence,
		"active_count": active_ids.size(),
		"active_actor_ids": active_ids,
		"monotonic_event_sequence": qualification_event_sequence,
	})
	while qualification_region_milestones.size() > REGION_ORDER.size() * 4:
		qualification_region_milestones.pop_front()


func _update_qualification_actor(kind: StringName, enemy: FusepointEnemyAgent, source_event: Dictionary = {}) -> void:
	if _observation_enemy(enemy, &"qualification_event", enemy.stable_id if enemy != null and is_instance_valid(enemy) else &"") == null:
		return
	if not qualification_actors.has(enemy.stable_id):
		return
	qualification_event_sequence += 1
	var actor: Dictionary = qualification_actors[enemy.stable_id]
	var snapshot := enemy.authoritative_snapshot()
	var coverage: Dictionary = actor["state_coverage"]
	var action := StringName(snapshot.get("action", &"idle"))
	var block_reason := StringName(snapshot.get("fire_block_reason", &"unknown"))
	coverage["perception"] = bool(coverage["perception"]) or snapshot.get("target_visible", false) == true
	coverage["navigation"] = bool(coverage["navigation"]) or action in [&"search", &"patrol", &"chase", &"reposition", &"strafe", &"flank"] or not (snapshot.get("navigation_velocity", Vector3.ZERO) as Vector3).is_zero_approx()
	coverage["aim"] = bool(coverage["aim"]) or action in [&"aim", &"fire"]
	coverage["fire"] = bool(coverage["fire"]) or kind == &"shot_resolved" or not String(snapshot.get("shot_event_id", "")).is_empty()
	coverage["reload"] = bool(coverage["reload"]) or kind in [&"reload_started", &"reload_finished"] or action == &"reload"
	coverage["hurt"] = bool(coverage["hurt"]) or kind == &"player_hit" or action == &"hurt"
	coverage["death"] = bool(coverage["death"]) or kind == &"died" or action in [&"dead", &"death"]
	coverage["blocked_fire"] = bool(coverage["blocked_fire"]) or block_reason not in [&"none", &"no_target", &"attack_cooldown"]
	var event_counts: Dictionary = actor["event_counts"]
	event_counts[kind] = int(event_counts.get(kind, 0)) + 1
	actor["first_event_sequence"] = qualification_event_sequence if int(actor["first_event_sequence"]) == 0 else actor["first_event_sequence"]
	actor["last_event_sequence"] = qualification_event_sequence
	actor["event_counts"] = event_counts
	actor["state_coverage"] = coverage
	actor["latest"] = _qualification_live_fields(snapshot, source_event)


func _refresh_qualification_live_state() -> void:
	for candidate: Variant in enemies.values():
		var enemy := _observation_enemy(candidate, &"qualification_refresh")
		if enemy == null:
			continue
		if not qualification_actors.has(enemy.stable_id):
			continue
		var actor: Dictionary = qualification_actors[enemy.stable_id]
		actor["latest"] = _qualification_live_fields(enemy.authoritative_snapshot(), {})


func _qualification_live_fields(snapshot: Dictionary, source_event: Dictionary) -> Dictionary:
	var health_state: Dictionary = snapshot.get("health", {})
	return {
		"actor_id": snapshot.get("id", &""),
		"role": snapshot.get("role", &""),
		"region": snapshot.get("region", &""),
		"route_slot": snapshot.get("route_slot", &""),
		"active": snapshot.get("active", false),
		"alive": snapshot.get("alive", false),
		"transform": snapshot.get("transform", Transform3D.IDENTITY),
		"velocity": snapshot.get("velocity", Vector3.ZERO),
		"action": snapshot.get("action", &"idle"),
		"target_visible": snapshot.get("target_visible", false),
		"perception_memory": snapshot.get("perception_memory", {}),
		"navigation_velocity": snapshot.get("navigation_velocity", Vector3.ZERO),
		"desired_navigation_velocity": snapshot.get("desired_navigation_velocity", Vector3.ZERO),
		"safe_navigation_velocity": snapshot.get("safe_navigation_velocity", Vector3.ZERO),
		"safe_velocity_ready": snapshot.get("safe_velocity_ready", false),
		"reservation": snapshot.get("reservation", {}),
		"nearest_neighbor_distance": snapshot.get("nearest_neighbor_distance", -1.0),
		"grounded_occupancy": snapshot.get("grounded_occupancy", false),
		"full_capsule_occupancy": snapshot.get("full_capsule_occupancy", {}),
		"avoidance_enabled": snapshot.get("avoidance_enabled", false),
		"fire_block_reason": snapshot.get("fire_block_reason", &"unknown"),
		"ammo": snapshot.get("ammo", 0),
		"muzzle_state": snapshot.get("muzzle_state", {}),
		"health": health_state.get("current", 0.0),
		"shot_event_id": snapshot.get("shot_event_id", ""),
		"shot_causality": snapshot.get("shot_causality", {}),
		"pre_shot_authorization": snapshot.get("pre_shot_authorization", {}),
		"animation": {
			"state": snapshot.get("presentation_state", &"inactive"),
			"semantic": snapshot.get("animation_semantic", &""),
			"clip": snapshot.get("animation_name", ""),
			"time_seconds": snapshot.get("animation_position_seconds", 0.0),
			"normalized_time": snapshot.get("animation_normalized_time", 0.0),
			"playing": snapshot.get("animation_playing", false),
			"weapon_family": snapshot.get("weapon_family", &"unbound"),
		},
		"stalled_seconds": snapshot.get("stalled_seconds", 0.0),
		"progress_watchdog_count": snapshot.get("progress_watchdog_count", 0),
		"activation_sequence": snapshot.get("activation_sequence", 0),
		"restore_epoch": snapshot.get("restore_epoch", 0),
		"source_event_id": source_event.get("event_id", ""),
	}


func _qualification_summary() -> Dictionary:
	var complete_actor_count := 0
	for actor: Dictionary in qualification_actors.values():
		var coverage: Dictionary = actor.get("state_coverage", {})
		var complete := true
		for state_id in ["perception", "navigation", "aim", "fire", "reload", "hurt", "death", "blocked_fire"]:
			complete = complete and coverage.get(state_id, false) == true
		actor["coverage_complete"] = complete
		complete_actor_count += 1 if complete else 0
	return {
		"run_id": qualification_run_id,
		"event_sequence": qualification_event_sequence,
		"bounded_actor_count": qualification_actors.size(),
		"complete_actor_count": complete_actor_count,
		"regions": qualification_regions,
		"region_milestones": qualification_region_milestones,
		"actor_page": qualification_actor_page(0, QUALIFICATION_PAGE_LIMIT),
		"checkpoint_preserves_coverage": true,
	}


func qualification_actor_page(offset := 0, limit := QUALIFICATION_PAGE_LIMIT) -> Dictionary:
	var ids: Array[StringName] = []
	for actor_id: StringName in qualification_actors:
		ids.append(actor_id)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	var bounded_offset := clampi(offset, 0, ids.size())
	var bounded_limit := clampi(limit, 1, QUALIFICATION_PAGE_LIMIT)
	var end := mini(bounded_offset + bounded_limit, ids.size())
	var items: Array[Dictionary] = []
	for index in range(bounded_offset, end):
		var actor: Dictionary = qualification_actors.get(ids[index], {})
		items.append({
			"actor_id": actor.get("actor_id", ids[index]),
			"region": actor.get("region", &""),
			"role": actor.get("role", &""),
			"route_slot": actor.get("route_slot", &""),
			"state_coverage": actor.get("state_coverage", {}),
			"coverage_complete": actor.get("coverage_complete", false),
			"first_event_sequence": actor.get("first_event_sequence", 0),
			"last_event_sequence": actor.get("last_event_sequence", 0),
			"latest": actor.get("latest", {}),
		})
	return {
		"requested_offset": offset,
		"requested_limit": limit,
		"resolved_offset": bounded_offset,
		"resolved_limit": bounded_limit,
		"total": ids.size(),
		"returned": items.size(),
		"truncated": end < ids.size(),
		"next_offset": end if end < ids.size() else -1,
		"items": items,
	}


func _append_progression_receipt(kind: StringName, enemy: FusepointEnemyAgent, source_event: Dictionary = {}) -> void:
	var actor := enemy.authoritative_snapshot()
	var health_state: Dictionary = actor.get("health", {})
	_progression_receipt_sequence += 1
	progression_receipts.append({
		"receipt_id": "progression-%06d" % _progression_receipt_sequence,
		"sequence": _progression_receipt_sequence,
		"activation_sequence": int(actor.get("activation_sequence", 0)),
		"kind": kind,
		"region": actor.get("region", &""),
		"actor_id": actor.get("id", &""),
		"role": actor.get("role", &""),
		"action": actor.get("action", &"idle"),
		"perception": {
			"target": actor.get("target", ""),
			"target_visible": actor.get("target_visible", false),
			"fire_block_reason": actor.get("fire_block_reason", &"unknown"),
		},
		"movement_mode": actor.get("action", &"idle"),
		"aim_authorized": actor.get("action", &"idle") in [&"aim", &"fire"],
		"reload_active": actor.get("action", &"idle") == &"reload",
		"hurt_active": actor.get("action", &"idle") == &"hurt",
		"death_active": actor.get("action", &"idle") == &"dead",
		"target_visible": actor.get("target_visible", false),
		"route_target": actor.get("route_target", enemy.global_position),
		"navigation_velocity": actor.get("navigation_velocity", Vector3.ZERO),
		"nearest_neighbor_distance": actor.get("nearest_neighbor_distance", -1.0),
		"grounded_occupancy": actor.get("grounded_occupancy", false),
		"occlusion": actor.get("occlusion", actor.get("fire_block_reason", &"unknown")),
		"ammo": actor.get("ammo", 0),
		"health": health_state.get("current", 0.0),
		"alive": actor.get("alive", false),
		"shot_event_id": actor.get("shot_event_id", ""),
		"immutable_shot_id": actor.get("shot_event_id", ""),
		"fire_block_reason": actor.get("fire_block_reason", &"unknown"),
		"restore_epoch": actor.get("restore_epoch", 0),
		"source_event": source_event.duplicate(true),
	})
	while progression_receipts.size() > 96:
		progression_receipts.pop_front()


func _mcp_state() -> Dictionary:
	return _summary()
