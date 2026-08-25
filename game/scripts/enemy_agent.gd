class_name FusepointEnemyAgent
extends FPSCombatEnemy

signal authoritative_enemy_event(event: Dictionary)

const PRESENTATION_SCENE := preload("res://systems/actors/humanoid/enemy_humanoid_actor.tscn")
const REQUIRED_ACTOR_SEPARATION := 1.4
const ROUTE_RESERVATION_SECONDS := 0.55
const ROUTE_PREDICTION_SECONDS := 0.32
const STALL_LIMIT_SECONDS := 3.0
const REGION_COMBAT_PROFILES := {
	&"alpha": {
		"profile_id": &"alpha_first_contact",
		"reaction_bonus_seconds": 2.0,
		"attack_interval_scale": 2.4,
		"damage_scale": 0.1875,
	},
	&"bravo": {
		"profile_id": &"bravo_crossfire",
		"reaction_bonus_seconds": 1.35,
		"attack_interval_scale": 2.0,
		"damage_scale": 0.25,
	},
	&"charlie": {
		"profile_id": &"charlie_defense",
		"reaction_bonus_seconds": 0.9,
		"attack_interval_scale": 1.7,
		"damage_scale": 0.3125,
	},
}

static var _route_reservations: Dictionary = {}
static var _route_reservation_cleanup_frame := -1
static var _route_reservation_cleanup_count := 0
@export var stable_id: StringName = &"enemy-unconfigured"
@export var region_id: StringName = &"alpha"
@export var tactical_role: StringName = &"defender"
@export var route_slot: StringName = &"unassigned"
@export var route_pressure := false
@export var roster_index := -1

var mission_active := false
var activation_sequence := 0
var cleanup_hidden := false
var _presentation_actor: EnemyHumanoidActor
@onready var _shot_feedback: FPSShotFeedback3D = $ShotFeedback
var _cleanup_remaining := 0.0
var _event_sequence := 0
var _last_enemy_event: Dictionary = {}
var _mission_target: Node3D
var _restore_epoch := 0
var _restore_in_progress := false
var _restored_epoch := 0
var _restore_quiescent := false
var _restore_readiness := &"ordinary"
var reserved_position := Vector3.ZERO
var _aim_pitch_degrees := 0.0
var _upright_correction_count := 0
var _route_reservation: Dictionary = {}
var _last_pre_shot_authorization: Dictionary = {}
var _pending_fixture_shot_context: Dictionary = {}
var _last_progress_position := Vector3.ZERO
var _stalled_seconds := 0.0
var _progress_watchdog_count := 0
var _combat_profile: Dictionary = {}
var _tester_prepared_hold := false
var _tester_prepared_generation := 0
var _tester_search_fixture_receipt: Dictionary = {}
var _last_floor_support_receipt: Dictionary = {}
var _safe_velocity_callback_count := 0
var _safe_velocity_duplicate_callback_count := 0


func _ready() -> void:
	_enforce_upright_navigation_root()
	super._ready()
	add_to_group(&"mcp_watch")
	add_to_group(&"fusepoint_enemy")
	attack_resolved.connect(_on_attack_resolved)
	target_acquired.connect(_on_target_acquired_after_restore)
	reload_started.connect(_on_reload_started)
	reload_finished.connect(_on_reload_finished)
	enemy_died.connect(_on_enemy_died)
	ai_state_changed.connect(_on_ai_state_changed)
	_apply_activation_state()
	_last_progress_position = global_position
	if _navigation_agent != null:
		# Avoidance owns the complete 1.40 m center-to-center separation envelope;
		# the CharacterBody capsule remains the authored 0.40 m collision body.
		_navigation_agent.radius = REQUIRED_ACTOR_SEPARATION * 0.5
		_navigation_agent.neighbor_distance = maxf(_navigation_agent.neighbor_distance, 7.0)
		_navigation_agent.max_neighbors = maxi(_navigation_agent.max_neighbors, 18)
		_navigation_agent.time_horizon_agents = maxf(_navigation_agent.time_horizon_agents, 1.4)


func _physics_process(delta: float) -> void:
	if not mission_active or _tester_prepared_hold:
		return
	_enforce_upright_navigation_root()
	super._physics_process(delta)
	_update_presentation_aim_pitch()
	_enforce_upright_navigation_root()
	if _cleanup_remaining > 0.0:
		_cleanup_remaining = maxf(0.0, _cleanup_remaining - delta)
		if _cleanup_remaining <= 0.0 and _presentation_actor != null and not is_alive():
			_presentation_actor.visible = false
			cleanup_hidden = true
	_update_progress_watchdog(delta)


func _enforce_upright_navigation_root() -> void:
	if absf(rotation.x) <= 0.0001 and absf(rotation.z) <= 0.0001:
		return
	rotation = Vector3(0.0, rotation.y, 0.0)
	_upright_correction_count += 1


func _update_presentation_aim_pitch() -> void:
	if _presentation_actor == null:
		return
	var requested_pitch := 0.0
	if target != null and is_instance_valid(target) and _eye != null:
		var aim_delta := _target_aim_position(target) - _eye.global_position
		var horizontal_distance := Vector2(aim_delta.x, aim_delta.z).length()
		requested_pitch = -rad_to_deg(atan2(aim_delta.y, maxf(horizontal_distance, 0.001)))
	_aim_pitch_degrees = clampf(requested_pitch, -50.0, 50.0)
	_presentation_actor.set_aim_pitch(_aim_pitch_degrees)


func configure_roster_entry(entry: Dictionary, target_node: Node3D) -> void:
	stable_id = StringName(entry["id"])
	region_id = StringName(entry["region"])
	tactical_role = StringName(entry["role"])
	route_slot = StringName(entry["slot"])
	route_pressure = entry["route_pressure"] == true
	roster_index = int(entry["index"])
	reserved_position = entry.get("reserved_position", global_position)
	# add_child() enters the tree before the roster can apply the final global
	# transform, so the reusable base briefly observes the roster origin. Replace
	# that provisional home with this actor's committed navigation reservation.
	_home_position = reserved_position + Vector3.UP * 0.04
	_has_home_position = true
	tactical_random_seed = 17041 + roster_index * 131
	difficulty = int(entry.get("difficulty", Difficulty.MEDIUM))
	target_group = &"player"
	_mission_target = target_node
	# Preserve a readable, survivable contact window across the 30--45 second
	# spawn-to-Alpha budget. Region data keeps pressure progressive while the
	# stable roster index staggers simultaneous squad telegraphs deterministically.
	_combat_profile = (REGION_COMBAT_PROFILES.get(region_id, REGION_COMBAT_PROFILES[&"charlie"]) as Dictionary).duplicate(true)
	reaction_delay += float(_combat_profile["reaction_bonus_seconds"]) + float(roster_index % 5) * 0.35
	attack_interval *= float(_combat_profile["attack_interval_scale"])
	attack_damage *= float(_combat_profile["damage_scale"])
	if tactical_role in [&"defender", &"sentry"]:
		attack_range = 30.0
		walk_distance = 16.0
		flank_reposition_chance_override = 0.0
	# Target acquisition must remain perception-authoritative. Prebinding the
	# player here seeds last-seen memory before any range/FOV/LOS observation and
	# can pull an objective defender off its authored slot during deployment.
	target_path = NodePath()


func set_mission_active(active: bool, sequence := 0) -> void:
	if mission_active == active and (not active or activation_sequence > 0):
		return
	mission_active = active
	if not active:
		_tester_prepared_hold = false
		_tester_prepared_generation = 0
	_navigation_safe_velocity = Vector3.ZERO
	_navigation_desired_velocity = Vector3.ZERO
	_navigation_safe_velocity_ready = false
	if active:
		activation_sequence = sequence
		_ensure_presentation()
		var floor_support := resolve_floor_support(&"region_activation")
		if floor_support.get("accepted", false) != true:
			mission_active = false
			_apply_activation_state()
			_commit_enemy_event(&"activation_rejected", {"activation_sequence": activation_sequence, "floor_support": floor_support})
			return
		acquire_candidate_if_visible(_mission_target)
	else:
		_release_route_reservation()
	_apply_activation_state()
	_commit_enemy_event(&"activated" if active else &"deactivated", {
		"activation_sequence": activation_sequence,
	})


func _ensure_presentation() -> void:
	if _presentation_actor != null:
		return
	_presentation_actor = PRESENTATION_SCENE.instantiate() as EnemyHumanoidActor
	_presentation_actor.name = "Presentation"
	_presentation_actor.rotation.y = PI
	_presentation_actor.initial_skin = "soldier_a" if roster_index % 2 == 0 else "soldier_b"
	add_child(_presentation_actor)
	_presentation = _presentation_actor
	_set_calibration_visuals_visible(false)


func _apply_activation_state() -> void:
	set_physics_process(mission_active and not _tester_prepared_hold)
	if _collision_shape != null:
		_collision_shape.set_deferred("disabled", not mission_active or (_health != null and _health.is_dead))
	if _navigation_agent != null:
		_navigation_agent.avoidance_enabled = mission_active and (_health == null or not _health.is_dead)
	if _presentation_actor != null:
		_presentation_actor.visible = mission_active and not cleanup_hidden
	if not mission_active:
		velocity = Vector3.ZERO


func set_tester_prepared_hold(enabled: bool, setup_generation: int) -> Dictionary:
	var receipt := {
		"actor_id": stable_id,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"enabled": enabled,
		"setup_generation": setup_generation,
		"release_guard": &"OS.is_debug_build",
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	if setup_generation <= 0 or not mission_active or not is_alive():
		receipt["failure_reason"] = &"actor_not_stable_live"
		return receipt
	if not enabled and (not _tester_prepared_hold or setup_generation != _tester_prepared_generation):
		receipt["failure_reason"] = &"prepared_generation_mismatch"
		return receipt
	var floor_support := resolve_floor_support(&"tester_prepare" if enabled else &"tester_release")
	if enabled and floor_support.get("accepted", false) != true:
		receipt["failure_reason"] = floor_support.get("failure_reason", &"floor_support_rejected")
		receipt["floor_support"] = floor_support
		return receipt
	_tester_prepared_hold = enabled
	# Retain the released generation so paged inspection can correlate ordinary
	# perception/combat samples with the preparation that selected this actor.
	# Lifecycle reset remains the sole place that clears the generation.
	_tester_prepared_generation = setup_generation
	velocity = Vector3.ZERO
	_navigation_safe_velocity = Vector3.ZERO
	_navigation_desired_velocity = Vector3.ZERO
	_navigation_safe_velocity_ready = false
	if _navigation_agent != null:
		_navigation_agent.set_velocity_forced(Vector3.ZERO)
	_apply_activation_state()
	receipt.merge({
		"resolved": true,
		"accepted": true,
		"failure_reason": &"",
		"physics_held": _tester_prepared_hold,
		"visible": _presentation_actor != null and _presentation_actor.visible,
		"collision_active": _collision_shape != null and not _collision_shape.disabled,
		"floor_support": floor_support,
	}, true)
	return receipt


func tester_prepare_search_state(setup_generation: int) -> Dictionary:
	var receipt := {
		"actor_id": stable_id,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"setup_generation": setup_generation,
		"release_guard": &"OS.is_debug_build",
		"fixture": &"enemy_search_root_state",
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		_tester_search_fixture_receipt = receipt.duplicate(true)
		return receipt
	if setup_generation <= 0 or not mission_active or not is_alive():
		receipt["failure_reason"] = &"actor_not_stable_live"
		_tester_search_fixture_receipt = receipt.duplicate(true)
		return receipt
	_ensure_presentation()
	var hold_receipt := set_tester_prepared_hold(true, setup_generation)
	if hold_receipt.get("accepted", false) != true:
		receipt["failure_reason"] = hold_receipt.get("failure_reason", &"hold_rejected")
		receipt["hold_receipt"] = hold_receipt
		_tester_search_fixture_receipt = receipt.duplicate(true)
		return receipt
	set_target(null)
	_has_last_seen_target_position = true
	_last_seen_target_position = global_position - global_basis.z * 4.0
	_last_seen_target_remaining = search_seconds
	_targetless_action = &"tester_search_inspection"
	_targetless_action_remaining = targetless_scan_seconds
	_targetless_watchdog_remaining = targetless_watchdog_seconds
	velocity = -global_basis.z * minf(move_speed, 1.1)
	_set_ai_state(AIState.SEARCH)
	if _presentation_actor != null:
		_presentation_actor.walk()
		_presentation_actor.set_locomotion_speed(Vector2(velocity.x, velocity.z).length())
	_enforce_upright_navigation_root()
	var snapshot := authoritative_snapshot()
	var presentation_state: Dictionary = snapshot.get("presentation", {})
	receipt.merge({
		"resolved": true,
		"accepted": snapshot.get("root_upright", false) == true and StringName(snapshot.get("action", &"")) == &"search",
		"failure_reason": &"" if snapshot.get("root_upright", false) == true and StringName(snapshot.get("action", &"")) == &"search" else &"search_root_state_rejected",
		"hold_receipt": hold_receipt,
		"root_state": {
			"action": snapshot.get("action", &"idle"),
			"root_pitch_degrees": snapshot.get("root_pitch_degrees", 0.0),
			"root_roll_degrees": snapshot.get("root_roll_degrees", 0.0),
			"root_upright": snapshot.get("root_upright", false),
			"velocity": snapshot.get("velocity", Vector3.ZERO),
			"grounded_occupancy": snapshot.get("grounded_occupancy", false),
		},
		"animation": {
			"skin": presentation_state.get("skin_id", ""),
			"clip": presentation_state.get("animation", ""),
			"semantic": presentation_state.get("animation_semantic", &""),
			"normalized_time": presentation_state.get("animation_normalized_time", 0.0),
			"weapon_family": presentation_state.get("weapon_family", &"unbound"),
			"weapon_family_compatible": presentation_state.get("weapon_family_compatible", false),
		},
		"attack_authority": &"visible_actor_root_and_muzzle",
	}, true)
	_tester_search_fixture_receipt = receipt.duplicate(true)
	return receipt


func tester_stage_prepared_combat(stage: StringName, setup_generation: int) -> Dictionary:
	var receipt := {
		"actor_id": stable_id,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"stage": stage,
		"setup_generation": setup_generation,
		"release_guard": &"OS.is_debug_build",
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	if setup_generation <= 0 or not mission_active or not is_alive() or not _tester_prepared_hold:
		receipt["failure_reason"] = &"actor_not_stably_prepared"
		return receipt
	_ensure_presentation()
	cleanup_hidden = false
	_last_pre_shot_authorization.clear()
	_attack_remaining = 0.0
	_fire_pose_remaining = 0.0
	_reload_remaining = 0.0
	_hurt_remaining = 0.0
	_force_reposition = false
	if _health != null and _health.is_dead:
		_health.reset_health()
	match stage:
		&"search":
			set_target(null)
			_has_last_seen_target_position = true
			_last_seen_target_position = global_position - global_basis.z * 5.0
			_last_seen_target_remaining = search_seconds
			_targetless_action = &"tester_region_search"
			_targetless_action_remaining = targetless_scan_seconds
			_targetless_watchdog_remaining = targetless_watchdog_seconds
			velocity = -global_basis.z * minf(move_speed, 1.15)
			_set_ai_state(AIState.SEARCH)
			_drive_locomotion_presentation(&"walk")
		&"flank":
			_prime_target_for_fixture()
			_force_reposition = true
			_reposition_timeout_remaining = reposition_timeout_seconds
			_last_reposition_reason = &"tester_prepared_flank"
			velocity = global_basis.x * minf(move_speed, 1.4)
			_set_ai_state(AIState.REPOSITION)
			_drive_locomotion_presentation(&"run")
		&"reload":
			_prime_target_for_fixture()
			rounds_remaining = 0
			_begin_reload()
		&"hurt":
			_prime_target_for_fixture()
			var damage_report := _apply_tester_self_damage(false, setup_generation, &"prepared_hurt")
			receipt["damage_report"] = damage_report
		_:
			_prime_target_for_fixture()
			_reaction_remaining = 0.0
			_face_target(1.0)
			_set_ai_state(AIState.AIM)
	var snapshot := authoritative_snapshot()
	var accepted: bool = snapshot.get("observation_ready", false) == true and StringName(snapshot.get("action", &"idle")) in [&"search", &"reposition", &"aim", &"reload", &"hurt"]
	receipt.merge({
		"resolved": true,
		"accepted": accepted,
		"failure_reason": &"" if accepted else &"prepared_combat_stage_rejected",
		"snapshot": _fixture_snapshot_page(snapshot),
	}, true)
	return receipt


func tester_commit_combat_transition(setup_generation: int, mode: StringName) -> Dictionary:
	var receipt := {
		"actor_id": stable_id,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"mode": mode,
		"setup_generation": setup_generation,
		"release_guard": &"OS.is_debug_build",
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	if setup_generation <= 0 or _tester_prepared_hold or not mission_active or not is_alive():
		receipt["failure_reason"] = &"actor_not_released_live"
		return receipt
	_prime_target_for_fixture()
	match mode:
		&"enemy_fire":
			var attack := _force_fixture_enemy_shot(setup_generation, mode, false)
			receipt["attack_report"] = attack
		&"lethal_player_hit":
			receipt["attack_report"] = _force_fixture_enemy_shot(setup_generation, mode, true)
		&"nonlethal_player_hit":
			receipt["attack_report"] = _force_fixture_enemy_shot(setup_generation, mode, false)
		&"reload":
			rounds_remaining = 0
			_begin_reload()
		_:
			_set_ai_state(AIState.SEARCH)
			_drive_locomotion_presentation(&"walk")
	var snapshot := authoritative_snapshot()
	receipt.merge({
		"resolved": true,
		"accepted": snapshot.get("observation_ready", false) == true,
		"failure_reason": &"",
		"snapshot": _fixture_snapshot_page(snapshot),
	}, true)
	return receipt


func _prime_target_for_fixture() -> void:
	if _mission_target != null and is_instance_valid(_mission_target):
		set_target(_mission_target)
		remember_target_position(_mission_target.global_position)
		_reaction_remaining = 0.0
		_face_target(1.0)


func _force_fixture_enemy_shot(setup_generation: int, mode: StringName, lethal: bool) -> Dictionary:
	_prime_target_for_fixture()
	if rounds_remaining <= 0:
		rounds_remaining = 1
	_reaction_remaining = 0.0
	_attack_remaining = 0.0
	_reload_remaining = 0.0
	_hurt_remaining = 0.0
	_face_target(1.0)
	var original_damage := attack_damage
	if lethal and _target_health != null and is_instance_valid(_target_health):
		if _target_health is FPSHealth:
			attack_damage = maxf((_target_health as FPSHealth).current_health + 1.0, original_damage)
		elif "health" in _target_health:
			attack_damage = maxf(float(_target_health.get("health")) + 1.0, original_damage)
	_pending_fixture_shot_context = {
		"fixture_authority": &"tester_encounter_advance_authoritative_enemy_shot",
		"fixture_mode": mode,
		"setup_generation": setup_generation,
		"lethal_requested": lethal,
		"fixture_direct_damage": false,
	}
	var attack := force_attack_if_ready()
	_pending_fixture_shot_context.clear()
	attack_damage = original_damage
	attack["fixture_authority"] = &"tester_encounter_advance_authoritative_enemy_shot"
	attack["fixture_mode"] = mode
	attack["setup_generation"] = setup_generation
	attack["lethal_requested"] = lethal
	attack["damage_causality"] = &"enemy_shot_event" if attack.get("applied", false) == true else &"no_fixture_damage"
	attack["fixture_direct_damage"] = false
	attack["accepted_shot_or_valid_negative"] = attack.get("accepted", false) == true and StringName(attack.get("result", &"unknown")) in [&"hit", &"blocked", &"miss"]
	_last_pre_shot_authorization = {
		"accepted": attack.get("accepted", false) == true,
		"fixture_mode": mode,
		"setup_generation": setup_generation,
		"shot_id": attack.get("shot_id", ""),
		"result": attack.get("result", &"unknown"),
		"ammo_before": attack.get("ammo_before", rounds_remaining),
		"ammo_after": attack.get("ammo_after", rounds_remaining),
		"ammo_commit": attack.get("ammo_commit", 0),
		"target_path": attack.get("target_path", ""),
		"receiver_path": attack.get("receiver_path", ""),
		"failure_reason": attack.get("reason", ""),
	}
	return attack


func _apply_tester_self_damage(lethal: bool, setup_generation: int, reason: StringName) -> Dictionary:
	if _health == null:
		return {"accepted": false, "failure_reason": &"health_unavailable"}
	if not lethal and _health.current_health <= 16.0:
		_health.reset_health()
	var amount := maxf(_health.max_health + 1.0, 101.0) if lethal else minf(12.0, maxf(_health.current_health - 1.0, 1.0))
	var shot_id := "run-%06d:tester:%s:%s:%06d" % [run_epoch, stable_id, String(reason), setup_generation]
	return _health.apply_damage(amount, {
		"event_id": shot_id,
		"shot_id": shot_id,
		"source_team": &"player",
		"source_path": String(_mission_target.get_path()) if _mission_target != null and _mission_target.is_inside_tree() else "",
		"origin": _mission_target.global_position if _mission_target != null and _mission_target.is_inside_tree() else global_position - global_basis.z * 4.0,
		"hit_region": &"center_mass",
		"target_id": stable_id,
		"target_path": String(get_path()) if is_inside_tree() else "",
		"fixture_authority": &"tester_encounter_prepare_enemy_hurt_self_damage",
	})


func _fixture_snapshot_page(snapshot: Dictionary) -> Dictionary:
	return {
		"action": snapshot.get("action", &"idle"),
		"alive": snapshot.get("alive", false),
		"health": (snapshot.get("health", {}) as Dictionary).get("current", 0.0),
		"ammo": snapshot.get("ammo", 0),
		"target_visible": snapshot.get("target_visible", false),
		"fire_block_reason": snapshot.get("fire_block_reason", &"unknown"),
		"shot_event_id": snapshot.get("shot_event_id", ""),
		"last_event": snapshot.get("last_event", {}),
		"velocity": snapshot.get("velocity", Vector3.ZERO),
		"nearest_neighbor_distance": snapshot.get("nearest_neighbor_distance", -1.0),
		"presentation_state": snapshot.get("presentation_state", &"inactive"),
		"animation_semantic": snapshot.get("animation_semantic", &""),
		"animation_name": snapshot.get("animation_name", ""),
		"grounded_occupancy": snapshot.get("grounded_occupancy", false),
		"capsule_clear": (snapshot.get("inspection_state", {}) as Dictionary).get("capsule_clear", false),
	}


func resolve_floor_support(context: StringName) -> Dictionary:
	var receipt := {
		"context": context,
		"actor_id": stable_id,
		"requested_root": global_position,
		"accepted": false,
		"failure_reason": &"world_unavailable",
	}
	if not is_inside_tree() or get_world_3d() == null:
		_last_floor_support_receipt = receipt
		return receipt.duplicate(true)
	var excluded: Array[RID] = [get_rid()]
	for peer: Node in get_tree().get_nodes_in_group(&"fps_enemy"):
		if peer is CollisionObject3D and peer != self:
			excluded.append((peer as CollisionObject3D).get_rid())
	var sample_offsets: Array[Vector3] = [
		Vector3.ZERO,
		Vector3(0.28, 0.0, 0.0), Vector3(-0.28, 0.0, 0.0),
		Vector3(0.0, 0.0, 0.28), Vector3(0.0, 0.0, -0.28),
	]
	var supports: Array[Dictionary] = []
	var center_support := false
	var support_y := -INF
	var space_state := get_world_3d().direct_space_state
	for index in sample_offsets.size():
		var origin := global_position + sample_offsets[index]
		var query := PhysicsRayQueryParameters3D.create(
			origin + Vector3.UP * 1.25,
			origin + Vector3.DOWN * 1.5,
			sight_collision_mask,
			excluded,
		)
		query.collide_with_areas = false
		var hit := space_state.intersect_ray(query)
		if hit.is_empty() or (hit.get("normal", Vector3.ZERO) as Vector3).dot(Vector3.UP) < 0.55:
			continue
		var hit_position: Vector3 = hit.get("position", origin)
		support_y = maxf(support_y, hit_position.y)
		center_support = center_support or index == 0
		supports.append({"sample": index, "position": hit_position, "normal": hit.get("normal", Vector3.UP), "collider": String((hit.get("collider") as Node).get_path()) if hit.get("collider") is Node else ""})
	if not center_support or not is_finite(support_y):
		receipt["failure_reason"] = &"static_floor_missing_under_capsule"
		receipt["support_samples"] = supports
		_last_floor_support_receipt = receipt
		return receipt.duplicate(true)
	var previous_position := global_position
	global_position.y = support_y + 0.005
	reserved_position.y = support_y
	var capsule := _capsule_occupancy_snapshot()
	var visual_contact := _presentation_actor.ground_contact_report() if _presentation_actor != null else {"applicable": false}
	var world_contact_y := float(visual_contact.get("world_minimum_contact_y", support_y + 0.075))
	var target_contact_y := float(visual_contact.get("target_contact_y", 0.075))
	var visual_gap_error := absf((world_contact_y - support_y) - target_contact_y)
	var visual_required := _presentation_actor != null and _presentation_actor.visible
	var accepted: bool = capsule.get("capsule_clear", false) == true and (not visual_required or (visual_contact.get("applicable", false) == true and visual_gap_error <= 0.025))
	receipt.merge({
		"accepted": accepted,
		"failure_reason": &"" if accepted else &"capsule_or_visual_contact_invalid",
		"previous_root": previous_position,
		"resolved_root": global_position,
		"floor_y": support_y,
		"root_floor_gap": global_position.y - support_y,
		"support_sample_count": supports.size(),
		"support_samples": supports,
		"full_capsule": capsule,
		"visual_contact": visual_contact,
		"visual_contact_gap_error": visual_gap_error,
		"visual_contact_required": visual_required,
		"settled_physics_frame": Engine.get_physics_frames(),
	}, true)
	_last_floor_support_receipt = receipt.duplicate(true)
	return receipt.duplicate(true)


func clear_tester_prepared_hold() -> void:
	_tester_prepared_hold = false
	_tester_prepared_generation = 0
	_tester_search_fixture_receipt.clear()
	_apply_activation_state()


func apply_weapon_damage(amount: float, shot_id: String, origin: Vector3) -> bool:
	if not mission_active or _health == null:
		return false
	var report := _health.apply_damage(amount, {
		"shot_id": shot_id,
		"source_team": &"player",
		"source_path": String(get_tree().get_first_node_in_group(&"player").get_path()),
		"origin": origin,
		"hit_region": &"center_mass",
		"target_id": stable_id,
		"target_path": String(get_path()),
	})
	if report.get("applied", false) == true:
		_commit_enemy_event(&"player_hit", report)
	return report.get("applied", false) == true


func is_alive() -> bool:
	return _health != null and not _health.is_dead


func is_contesting(objective_position: Vector3, radius: float) -> bool:
	return mission_active and is_alive() and global_position.distance_to(objective_position) <= radius


func authoritative_snapshot() -> Dictionary:
	if not is_observation_ready():
		return {
			"run_epoch": run_epoch,
			"id": stable_id,
			"region": region_id,
			"role": tactical_role,
			"route_slot": route_slot,
			"observation_ready": false,
			"observation_rejected": true,
			"observation_rejection_reason": &"actor_constructing_or_tearing_down",
		}
	var combat := snapshot()
	var presentation_state := _presentation_actor.get_component_state() if _presentation_actor != null else {}
	var capsule_occupancy := _capsule_occupancy_snapshot()
	var muzzle_occupancy := _muzzle_occupancy_snapshot()
	var last_attack: Dictionary = combat.get("last_attack", {})
	var last_shot_id := String(last_attack.get("shot_id", ""))
	return {
		"run_epoch": run_epoch,
		"id": stable_id,
		"observation_ready": true,
		"observation_rejected": false,
		# One compact, front-loaded inspection cell keeps every required combat
		# datum visible even when a bounded runtime digest truncates the richer
		# presentation and feedback payload later in this snapshot.
		"inspection_state": {
			"role": tactical_role,
			"region": region_id,
			"route_slot": route_slot,
			"active": mission_active,
			"alive": is_alive(),
			"position": global_position,
			"rotation": rotation,
			"velocity": velocity,
			"avoidance_velocity": combat.get("navigation_safe_velocity", Vector3.ZERO),
			"nearest_neighbor_spacing": combat.get("nearest_enemy_distance", -1.0),
			"reservation_key": _route_reservation.get("key", ""),
			"reservation_state": _route_reservation.get("state", &"none"),
			"grounded": is_on_floor(),
			"floor_support": _last_floor_support_receipt,
			"capsule_clear": capsule_occupancy.get("capsule_clear", false),
			"capsule_static_blockers": capsule_occupancy.get("static_blocker_count", -1),
			"perception_target_visible": combat.get("target_visible", false),
			"perception_memory_seconds": combat.get("last_seen_target_remaining", 0.0),
			"action": combat.get("state", &"idle"),
			"animation_state": presentation_state.get("state", &"inactive"),
			"animation_clip": presentation_state.get("animation", ""),
			"animation_time_seconds": presentation_state.get("animation_position_seconds", 0.0),
			"ammo": combat.get("rounds_remaining", 0),
			"muzzle_clear": muzzle_occupancy.get("clear", false),
			"muzzle_static_blockers": muzzle_occupancy.get("static_blocker_count", -1),
			"shot_id": last_shot_id,
			"shot_authorized": _last_pre_shot_authorization.get("accepted", false),
			"shot_block_reason": _last_pre_shot_authorization.get("failure_reason", &"none"),
			"reciprocal_static_occlusion": combat.get("fire_block_reason", &"unknown"),
			"restore_epoch": _restore_epoch,
			"tester_prepared_hold": _tester_prepared_hold,
			"setup_generation": _tester_prepared_generation,
		},
		"region": region_id,
		"role": tactical_role,
		"route_slot": route_slot,
		"route_pressure": route_pressure,
		"combat_profile": _combat_profile.duplicate(true),
		"reaction_delay_seconds": reaction_delay,
		"attack_interval_seconds": attack_interval,
		"attack_damage": attack_damage,
		"roster_index": roster_index,
		"reserved_position": reserved_position,
		"active": mission_active,
		"alive": is_alive(),
		"transform": global_transform,
		"velocity": velocity,
		"action": combat.get("state", "idle"),
		"target": combat.get("target", ""),
		"mission_target": String(_mission_target.get_path()) if _mission_target != null and _mission_target.is_inside_tree() else "",
		"target_visible": combat.get("target_visible", false),
		"fire_block_reason": combat.get("fire_block_reason", "unknown"),
		"route_target": combat.get("targetless_route_target", global_position),
		"targetless_action": combat.get("targetless_action", &"none"),
		"targetless_watchdog_remaining": combat.get("targetless_watchdog_remaining", 0.0),
		"navigation_velocity": combat.get("navigation_safe_velocity", Vector3.ZERO),
		"desired_navigation_velocity": combat.get("navigation_desired_velocity", Vector3.ZERO),
		"safe_navigation_velocity": combat.get("navigation_safe_velocity", Vector3.ZERO),
		"safe_velocity_ready": combat.get("navigation_safe_velocity_ready", false),
		"safe_velocity_receipt_frame": combat.get("navigation_safe_velocity_receipt_frame", -1),
		"safe_velocity_consumed_frame": combat.get("navigation_safe_velocity_consumed_frame", -1),
		"safe_velocity_consumption_count": combat.get("navigation_safe_velocity_consumption_count", 0),
		"safe_velocity_callback_count": _safe_velocity_callback_count,
		"safe_velocity_duplicate_callback_count": _safe_velocity_duplicate_callback_count,
		"peer_cache": get_parent().call(&"peer_cache_receipt") if get_parent() != null and get_parent().has_method(&"peer_cache_receipt") else {},
		"reservation": _route_reservation.duplicate(true),
		"stalled_seconds": _stalled_seconds,
		"progress_watchdog_count": _progress_watchdog_count,
		"grounded_occupancy": is_on_floor() or _last_floor_support_receipt.get("accepted", false) == true,
		"full_capsule_occupancy": capsule_occupancy,
		"avoidance_enabled": _navigation_agent != null and _navigation_agent.avoidance_enabled,
		"ammo": combat.get("rounds_remaining", 0),
		"magazine_size": combat.get("magazine_size", 0),
		"shot_event_id": last_shot_id,
		"occlusion": combat.get("fire_block_reason", &"unknown"),
		"pre_shot_authorization": _last_pre_shot_authorization.duplicate(true),
		"muzzle_state": muzzle_occupancy,
		"shot_feedback": _shot_feedback.snapshot(),
		"shot_causality": {
			"shot_id": last_shot_id,
			"ammo_before": last_attack.get("ammo_before", combat.get("rounds_remaining", 0)),
			"ammo_after": last_attack.get("ammo_after", combat.get("rounds_remaining", 0)),
			"ammo_commit": last_attack.get("ammo_commit", 0),
			"animation_action": combat.get("state", &"idle"),
			"tracer_impact_audio_owner": String(_shot_feedback.get_path()),
			"damage_event_id": String(last_attack.get("event_id", last_shot_id)),
		},
		"perception_memory": {
			"target_visible": combat.get("target_visible", false),
			"last_seen_position": combat.get("last_seen_target_position", Vector3.ZERO),
			"remaining_seconds": combat.get("last_seen_target_remaining", 0.0),
			"target_path": combat.get("target", ""),
		},
		"nearest_neighbor_distance": combat.get("nearest_enemy_distance", -1.0),
		"health": combat.get("health", {}),
		"activation_sequence": activation_sequence,
		"cleanup_hidden": cleanup_hidden,
		"presentation_bound": _presentation_actor != null,
		"presentation_state": _presentation_actor.state_name() if _presentation_actor != null else "inactive",
		"presentation": presentation_state,
		"animation_name": presentation_state.get("animation", ""),
		"animation_semantic": presentation_state.get("animation_semantic", &""),
		"rifle_semantic_procedural": presentation_state.get("rifle_semantic_procedural", false),
		"rifle_action_progress": presentation_state.get("rifle_action_progress", 0.0),
		"animation_position_seconds": presentation_state.get("animation_position_seconds", 0.0),
		"animation_normalized_time": presentation_state.get("animation_normalized_time", 0.0),
		"animation_playing": presentation_state.get("animation_playing", false),
		"animation_state_change_count": presentation_state.get("state_change_count", 0),
		"weapon_family": presentation_state.get("weapon_family", &"unbound"),
		"weapon_family_compatible": presentation_state.get("weapon_family_compatible", false),
		"weapon_socket_bound": presentation_state.get("socket_bound", false),
		"weapon_attached": presentation_state.get("weapon_attached", false),
		"root_pitch_degrees": rad_to_deg(rotation.x),
		"root_yaw_degrees": rad_to_deg(rotation.y),
		"root_roll_degrees": rad_to_deg(rotation.z),
		"root_upright": absf(rotation.x) <= 0.001 and absf(rotation.z) <= 0.001,
		"transform_authority": {
			"actor_root_dynamic_axes": ["yaw"],
			"actor_root_pitch_roll_locked": true,
			"presentation_axis_correction": presentation_state.get("presentation_adapter_rotation_degrees", Vector3.ZERO),
			"vertical_aim_layer": &"presentation_upper_body",
		},
		"upright_correction_count": _upright_correction_count,
		"aim_pitch_degrees": _aim_pitch_degrees,
		"binding_accepted": _presentation_actor.binding_report.get("accepted", false) == true if _presentation_actor != null else false,
		"restore_epoch": _restore_epoch,
		"restored_epoch": _restored_epoch,
		"restore_in_progress": _restore_in_progress,
		"restore_quiescent": _restore_quiescent,
		"restore_readiness": _restore_readiness,
		"last_event": _last_enemy_event,
	}


func is_observation_ready() -> bool:
	return (
		is_inside_tree()
		and not is_queued_for_deletion()
		and _health != null
		and is_instance_valid(_health)
		and _shot_feedback != null
		and is_instance_valid(_shot_feedback)
	)


func _capsule_occupancy_snapshot() -> Dictionary:
	var receipt := {
		"checked_frame": Engine.get_physics_frames(),
		"capsule_radius": 0.37,
		"capsule_height": 1.7,
		"static_blocker_count": -1,
		"capsule_clear": false,
		"accepted": false,
	}
	if not is_inside_tree() or get_world_3d() == null:
		return receipt
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.37
	capsule.height = 1.7
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis.IDENTITY, global_position + Vector3.UP * 0.92)
	query.collision_mask = sight_collision_mask
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var blocker_count := 0
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 12):
		if hit.get("collider") is StaticBody3D:
			blocker_count += 1
	receipt["static_blocker_count"] = blocker_count
	receipt["capsule_clear"] = blocker_count == 0
	receipt["accepted"] = blocker_count == 0
	return receipt


func _muzzle_occupancy_snapshot() -> Dictionary:
	var receipt := {
		"checked_frame": Engine.get_physics_frames(),
		"node_path": String(_muzzle.get_path()) if _muzzle != null and _muzzle.is_inside_tree() else "",
		"position": _muzzle.global_position if _muzzle != null and _muzzle.is_inside_tree() else global_position,
		"forward": -_muzzle.global_basis.z if _muzzle != null and _muzzle.is_inside_tree() else -global_basis.z,
		"static_blocker_count": -1,
		"clear": false,
	}
	if _muzzle == null or not _muzzle.is_inside_tree() or get_world_3d() == null:
		return receipt
	var sphere := SphereShape3D.new()
	sphere.radius = 0.12
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, _muzzle.global_position)
	query.collision_mask = sight_collision_mask
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var blocker_count := 0
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 8):
		if hit.get("collider") is StaticBody3D:
			blocker_count += 1
	receipt["static_blocker_count"] = blocker_count
	receipt["clear"] = blocker_count == 0
	return receipt


func begin_checkpoint_restore(epoch: int) -> void:
	_restore_epoch = epoch
	_restore_in_progress = true
	_restore_quiescent = true
	_restore_readiness = &"suspended"
	_shot_feedback.reset_feedback(run_epoch)
	set_physics_process(false)
	velocity = Vector3.ZERO
	reset_volatile_combat_state_for_restore()
	if _collision_shape != null:
		_collision_shape.set_deferred("disabled", true)
	if _navigation_agent != null:
		_navigation_agent.avoidance_enabled = false
	_release_route_reservation()


func apply_checkpoint_snapshot(saved: Dictionary, epoch: int) -> bool:
	if not _restore_in_progress or epoch != _restore_epoch:
		return false
	if StringName(saved.get("id", &"")) != stable_id:
		push_error("Restore identity mismatch for %s" % stable_id)
		return false
	if StringName(saved.get("region", region_id)) != region_id or StringName(saved.get("role", tactical_role)) != tactical_role or StringName(saved.get("route_slot", route_slot)) != route_slot:
		push_error("Restore roster binding mismatch for %s" % stable_id)
		return false
	var saved_reserved: Vector3 = saved.get("reserved_position", reserved_position)
	if not saved_reserved.is_equal_approx(reserved_position):
		push_error("Restore reservation mismatch for %s" % stable_id)
		return false
	global_transform = saved.get("transform", global_transform)
	_enforce_upright_navigation_root()
	velocity = Vector3.ZERO
	rounds_remaining = int(saved.get("ammo", magazine_size))
	activation_sequence = int(saved.get("activation_sequence", activation_sequence))
	cleanup_hidden = false
	_cleanup_remaining = 0.0
	var health_state: Dictionary = saved.get("health", {})
	var restored_health := float(health_state.get("current", _health.max_health if _health != null else 100.0))
	if _health != null:
		_health.reset_health(restored_health)
	mission_active = saved.get("active", false) == true
	reset_volatile_combat_state_for_restore()
	_last_enemy_event.clear()
	if mission_active:
		_ensure_presentation()
		if _health != null and _health.is_dead:
			ai_state = AIState.DEAD
			_presentation_actor.die()
		else:
			ai_state = AIState.IDLE
			_presentation_actor.reset_enemy()
	var floor_support := resolve_floor_support(&"checkpoint_snapshot_applied")
	if floor_support.get("accepted", false) != true:
		push_error("Restore floor support rejected for %s: %s" % [stable_id, floor_support])
		return false
	_restored_epoch = epoch
	_restore_readiness = &"snapshot_applied"
	return true


func finish_checkpoint_restore(epoch: int) -> bool:
	if not _restore_in_progress or epoch != _restore_epoch or _restored_epoch != epoch:
		return false
	_restore_in_progress = false
	_restore_readiness = &"fresh_perception_pending"
	call_deferred(&"_resume_after_restore_boundary", epoch)
	return true


func abort_checkpoint_restore(saved: Dictionary, epoch: int) -> bool:
	if epoch != _restore_epoch:
		return false
	_restore_in_progress = true
	if not apply_checkpoint_snapshot(saved, epoch):
		return false
	_restore_in_progress = false
	_restore_quiescent = true
	_restore_readiness = &"rollback_quiescent"
	set_physics_process(false)
	velocity = Vector3.ZERO
	return true


func _resume_after_restore_boundary(epoch: int) -> void:
	await get_tree().physics_frame
	if _restore_in_progress or epoch != _restore_epoch:
		return
	_restore_quiescent = false
	_restore_readiness = &"fresh_perception_required" if mission_active and is_alive() else &"inactive_or_dead"
	_apply_activation_state()


func restore_authoritative_snapshot(saved: Dictionary) -> void:
	# Compatibility entry point; still observes the same three-phase transaction.
	var epoch := _restore_epoch + 1
	begin_checkpoint_restore(epoch)
	if apply_checkpoint_snapshot(saved, epoch):
		finish_checkpoint_restore(epoch)


func _on_attack_resolved(report: Dictionary) -> void:
	if _restored_epoch > 0:
		_restore_readiness = &"combat_ready"
	var event := report.duplicate(true)
	if not _pending_fixture_shot_context.is_empty():
		event.merge(_pending_fixture_shot_context, true)
		event["damage_causality"] = &"enemy_shot_event" if event.get("applied", false) == true else &"no_fixture_damage"
		event["accepted_shot_or_valid_negative"] = event.get("accepted", false) == true and StringName(event.get("result", &"unknown")) in [&"hit", &"blocked", &"miss"]
	event["actor_id"] = stable_id
	event["weapon_id"] = &"rift_carbine"
	event["region"] = region_id
	event["role"] = tactical_role
	event["ammo_after"] = rounds_remaining
	last_attack_report = event.duplicate(true)
	_shot_feedback.show_shot(event)
	_commit_enemy_event(&"shot_resolved", event)


func reset_shot_feedback() -> void:
	_shot_feedback.begin_run_epoch(run_epoch)


func _on_target_acquired_after_restore(_target: Node3D) -> void:
	if _restored_epoch > 0 and not _restore_in_progress:
		_restore_readiness = &"fresh_aim_window"


func _on_reload_started(combat: Dictionary) -> void:
	_commit_enemy_event(&"reload_started", {"ammo": combat.get("rounds_remaining", 0)})


func _on_reload_finished(combat: Dictionary) -> void:
	_commit_enemy_event(&"reload_finished", {"ammo": combat.get("rounds_remaining", 0)})


func _on_enemy_died(event: Dictionary) -> void:
	_cleanup_remaining = 4.0
	_release_route_reservation()
	_commit_enemy_event(&"died", event)


func _submit_navigation_velocity(desired_velocity: Vector3) -> void:
	_cleanup_route_reservations()
	_navigation_desired_velocity = Vector3(desired_velocity.x, 0.0, desired_velocity.z)
	# The NavigationServer callback is the single avoidance/separation admission
	# point. The parent consumes the previously admitted receipt while this
	# desired velocity is evaluated for the next physics boundary.
	super._submit_navigation_velocity(_navigation_desired_velocity)


func _on_navigation_velocity_computed(safe_velocity: Vector3) -> void:
	# Exactly one separation pass is consumed for each server avoidance receipt.
	var physics_frame := Engine.get_physics_frames()
	if _navigation_safe_velocity_receipt_frame == physics_frame:
		_safe_velocity_duplicate_callback_count += 1
		return
	_navigation_safe_velocity = _separation_safe_velocity(safe_velocity)
	_navigation_safe_velocity_ready = true
	_navigation_safe_velocity_receipt_frame = physics_frame
	_safe_velocity_callback_count += 1
	_reserve_route_window(_navigation_safe_velocity)


func _separation_safe_velocity(candidate: Vector3) -> Vector3:
	var admitted := Vector3(candidate.x, 0.0, candidate.z)
	for peer_node: Node in _ordered_active_peers():
		if peer_node == self or not peer_node is FusepointEnemyAgent:
			continue
		var peer := peer_node as FusepointEnemyAgent
		if not peer.mission_active or not peer.is_alive():
			continue
		var offset := global_position - peer.global_position
		offset.y = 0.0
		var distance := offset.length()
		var away := offset.normalized() if distance > 0.001 else _deterministic_separation_axis(peer)
		var peer_velocity := Vector3(peer.velocity.x, 0.0, peer.velocity.z)
		var peer_reservation: Dictionary = _route_reservations.get(peer.stable_id, {})
		var peer_predicted := peer_reservation.get("position", peer.global_position + peer_velocity * ROUTE_PREDICTION_SECONDS) as Vector3
		var predicted_offset := global_position + admitted * ROUTE_PREDICTION_SECONDS - peer_predicted
		var predicted_distance := predicted_offset.length()
		if distance >= REQUIRED_ACTOR_SEPARATION and predicted_distance >= REQUIRED_ACTOR_SEPARATION:
			continue
		# Remove only the inward component, then add the minimum bounded recovery
		# speed needed to reopen an already-collapsed envelope. This is ordinary
		# velocity admission; no actor transform is ever nudged or teleported.
		var inward_speed := admitted.dot(away)
		if inward_speed < 0.0:
			admitted -= away * inward_speed
		if distance < REQUIRED_ACTOR_SEPARATION:
			var recovery_speed := minf(move_speed, (REQUIRED_ACTOR_SEPARATION - distance) / ROUTE_PREDICTION_SECONDS)
			admitted += away * recovery_speed
	admitted.y = 0.0
	return admitted.limit_length(move_speed)


func _ordered_active_peers() -> Array[Node]:
	var roster := get_parent()
	if roster != null and roster.has_method(&"ordered_peer_cache"):
		return roster.call(&"ordered_peer_cache") as Array[Node]
	return []


func _deterministic_separation_axis(peer: FusepointEnemyAgent) -> Vector3:
	var sign_value := -1.0 if String(stable_id) < String(peer.stable_id) else 1.0
	var angle := float((roster_index * 37 + peer.roster_index * 17) % 360)
	return Vector3(cos(deg_to_rad(angle)) * sign_value, 0.0, sin(deg_to_rad(angle)) * sign_value).normalized()


func _reserve_route_window(admitted_velocity: Vector3) -> void:
	var physics_hz := float(Engine.physics_ticks_per_second)
	var expiry_frame := Engine.get_physics_frames() + maxi(1, int(ceil(ROUTE_RESERVATION_SECONDS * physics_hz)))
	var predicted_position := global_position + admitted_velocity * ROUTE_PREDICTION_SECONDS
	_route_reservation = {
		"key": "%s:%s" % [String(region_id), String(route_slot)],
		"actor_id": stable_id,
		"slot": route_slot,
		"position": predicted_position,
		"desired_velocity": _navigation_desired_velocity,
		"admitted_velocity": admitted_velocity,
		"issued_frame": Engine.get_physics_frames(),
		"expires_frame": expiry_frame,
		"state": &"active",
	}
	_route_reservations[stable_id] = {"actor": self, "expires_frame": expiry_frame, "position": predicted_position}


func _release_route_reservation() -> void:
	_route_reservations.erase(stable_id)
	if not _route_reservation.is_empty():
		_route_reservation["state"] = &"released"
		_route_reservation["released_frame"] = Engine.get_physics_frames()


func _cleanup_route_reservations() -> void:
	var now_frame := Engine.get_physics_frames()
	if _route_reservation_cleanup_frame == now_frame:
		return
	_route_reservation_cleanup_frame = now_frame
	_route_reservation_cleanup_count += 1
	for actor_id: Variant in _route_reservations.keys():
		var record: Dictionary = _route_reservations.get(actor_id, {})
		var actor := record.get("actor") as Node
		if actor == null or not is_instance_valid(actor) or int(record.get("expires_frame", -1)) < now_frame:
			_route_reservations.erase(actor_id)


static func route_reservation_cache_receipt() -> Dictionary:
	return {
		"active_reservation_count": _route_reservations.size(),
		"cleanup_frame": _route_reservation_cleanup_frame,
		"cleanup_count": _route_reservation_cleanup_count,
		"cleanup_scope": &"once_per_physics_frame_global",
	}


func _update_progress_watchdog(delta: float) -> void:
	var horizontal_progress := Vector2(global_position.x - _last_progress_position.x, global_position.z - _last_progress_position.z).length()
	var movement_requested := Vector2(_navigation_desired_velocity.x, _navigation_desired_velocity.z).length() > 0.15
	var legal_hold := ai_state in [AIState.AIM, AIState.FIRE, AIState.RELOAD, AIState.HURT, AIState.IN_COVER, AIState.DEAD]
	if movement_requested and not legal_hold and horizontal_progress < 0.015:
		_stalled_seconds += delta
	else:
		_stalled_seconds = 0.0
	if _stalled_seconds >= STALL_LIMIT_SECONDS:
		_progress_watchdog_count += 1
		_stalled_seconds = 0.0
		if target != null:
			_force_reposition = true
			_last_reposition_reason = &"route_progress_watchdog"
		else:
			_targetless_watchdog_remaining = 0.0
	_last_progress_position = global_position


func _fire_block_reason() -> String:
	var parent_reason := super._fire_block_reason()
	if parent_reason != "ready":
		return parent_reason
	var authorization := _pre_shot_authorization()
	return "ready" if authorization.get("accepted", false) == true else String(authorization.get("reason", &"pre_shot_clearance_blocked"))


func _perform_attack() -> Dictionary:
	var authorization := _pre_shot_authorization()
	_last_pre_shot_authorization = authorization
	if authorization.get("accepted", false) != true:
		if _authorization_allows_negative_shot(authorization):
			return _perform_occluded_negative_attack(authorization)
		_attack_remaining = minf(maxf(attack_interval * 0.25, 0.08), 0.3)
		return {
			"accepted": false,
			"applied": false,
			"hit": false,
			"reason": authorization.get("reason", &"pre_shot_clearance_blocked"),
			"authorization": authorization,
			"ammo_before": rounds_remaining,
			"ammo_after": rounds_remaining,
			"ammo_commit": 0,
		}
	var report := super._perform_attack()
	report["pre_shot_authorization"] = authorization
	_last_pre_shot_authorization = authorization
	return report


func _authorization_allows_negative_shot(authorization: Dictionary) -> bool:
	if target == null or not is_instance_valid(target) or rounds_remaining <= 0:
		return false
	if authorization.get("body_clear", false) != true:
		return false
	var muzzle_occupancy := authorization.get("muzzle_occupancy", {}) as Dictionary
	if muzzle_occupancy.get("clear", false) != true:
		return false
	var reason := StringName(authorization.get("reason", &""))
	return reason in [&"eye_occluded", &"muzzle_occluded", &"reciprocal_occlusion_blocked"]


func _perform_occluded_negative_attack(authorization: Dictionary) -> Dictionary:
	_set_ai_state(AIState.FIRE)
	_fire_pose_remaining = fire_pose_seconds
	_attack_remaining = attack_interval
	rounds_remaining -= 1
	_attack_sequence += 1
	_attack_attempts_on_current_target += 1
	var shot_id := "run-%06d:enemy:%s:%06d" % [run_epoch, name, _attack_sequence]
	var shot_origin := _muzzle.global_position if _muzzle != null else global_position
	var shot_endpoint := _target_aim_position(target) if target != null else shot_origin - global_basis.z
	var shot_direction := shot_origin.direction_to(shot_endpoint)
	var trace := _resolve_attack_trace(shot_origin, shot_endpoint)
	var trace_result := StringName(trace.get("result", &"miss"))
	var result := &"miss" if trace_result == &"miss" else &"blocked"
	var receiver_path := String(_target_health.get_path()) if _target_health != null and is_instance_valid(_target_health) and _target_health.is_inside_tree() else ""
	var receiver_type := StringName(_target_health.get_class()) if _target_health != null and is_instance_valid(_target_health) else &"none"
	if _target_health != null and _target_health.has_method(&"apply_damage") and not _target_health is FPSHealth:
		receiver_type = &"PrototypePlayer"
	var receiver_health_before := float(_target_health.get("current_health")) if _target_health is FPSHealth else float(_target_health.get("health")) if _target_health != null and "health" in _target_health else -1.0
	var report := {
		"event_id": shot_id,
		"shot_id": shot_id,
		"run_epoch": run_epoch,
		"source_team": attack_team,
		"source_path": String(get_path()) if is_inside_tree() else "",
		"damage": attack_damage,
		"accepted": true,
		"hit": false,
		"origin": _eye.global_position if _eye != null else global_position,
		"muzzle_origin": shot_origin,
		"direction": shot_direction,
		"hit_position": trace.get("position", shot_endpoint),
		"hit_normal": trace.get("normal", Vector3.UP),
		"result": result,
		"surface_kind": trace.get("surface_kind", &"air"),
		"ammo_before": rounds_remaining + 1,
		"ammo_after": rounds_remaining,
		"ammo_commit": 1,
		"target_path": String(target.get_path()) if target != null else "",
		"receiver_path": receiver_path,
		"receiver_type": receiver_type,
		"health_before": receiver_health_before,
		"health_authority": &"FPSHealth" if _target_health is FPSHealth else &"PrototypePlayer.health" if receiver_type == &"PrototypePlayer" else &"none",
		"applied": false,
		"reason": "resolved_%s_from_%s" % [String(result), String(authorization.get("reason", &"occluded"))],
		"pre_shot_authorization": authorization.duplicate(true),
		"negative_shot_authority": &"occluded_line_of_fire_receipt",
	}
	last_attack_report = report
	attack_resolved.emit(report)
	return report


func _pre_shot_authorization() -> Dictionary:
	var receipt := {
		"accepted": false,
		"reason": &"no_target",
		"body_clear": false,
		"eye_clear": false,
		"muzzle_clear": false,
		"reciprocal_clear": false,
		"checked_frame": Engine.get_physics_frames(),
	}
	if target == null or not is_instance_valid(target) or _eye == null or _muzzle == null:
		return receipt
	var space_state := get_world_3d().direct_space_state
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.37
	capsule.height = 1.7
	var body_query := PhysicsShapeQueryParameters3D.new()
	body_query.shape = capsule
	body_query.transform = Transform3D(Basis.IDENTITY, global_position + Vector3.UP * 0.92)
	body_query.collision_mask = sight_collision_mask
	body_query.exclude = [get_rid(), target.get_rid()] if target is CollisionObject3D else [get_rid()]
	body_query.collide_with_areas = false
	body_query.collide_with_bodies = true
	var static_blocker_count := 0
	for hit: Dictionary in space_state.intersect_shape(body_query, 12):
		if hit.get("collider") is StaticBody3D:
			static_blocker_count += 1
	var endpoint := _target_aim_position(target)
	var eye_clear := _ray_reaches_target(_eye.global_position, endpoint)
	var muzzle_clear := _ray_reaches_target(_muzzle.global_position, endpoint)
	var reciprocal_clear := _reverse_ray_reaches_self(endpoint, _eye.global_position)
	var muzzle_occupancy := _muzzle_occupancy_snapshot()
	receipt["body_clear"] = static_blocker_count == 0
	receipt["static_blocker_count"] = static_blocker_count
	receipt["eye_clear"] = eye_clear
	receipt["muzzle_clear"] = muzzle_clear and muzzle_occupancy.get("clear", false) == true
	receipt["muzzle_occupancy"] = muzzle_occupancy
	receipt["reciprocal_clear"] = reciprocal_clear
	receipt["accepted"] = static_blocker_count == 0 and eye_clear and muzzle_clear and muzzle_occupancy.get("clear", false) == true and reciprocal_clear
	if static_blocker_count > 0:
		receipt["reason"] = &"body_clearance_blocked"
	elif not eye_clear:
		receipt["reason"] = &"eye_occluded"
	elif not muzzle_clear or muzzle_occupancy.get("clear", false) != true:
		receipt["reason"] = &"muzzle_occluded"
	elif not reciprocal_clear:
		receipt["reason"] = &"reciprocal_occlusion_blocked"
	else:
		receipt["reason"] = &"authorized"
	return receipt


func _ray_reaches_target(origin: Vector3, endpoint: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(origin, endpoint, sight_collision_mask, [get_rid()])
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty() and _belongs_to_target(hit.get("collider") as Node)


func _reverse_ray_reaches_self(origin: Vector3, endpoint: Vector3) -> bool:
	var excluded: Array[RID] = []
	if target is CollisionObject3D:
		excluded.append((target as CollisionObject3D).get_rid())
	var query := PhysicsRayQueryParameters3D.create(origin, endpoint, sight_collision_mask, excluded)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider := hit.get("collider") as Node
	while collider != null:
		if collider == self:
			return true
		collider = collider.get_parent()
	return false


func _on_ai_state_changed(previous: StringName, current: StringName, _combat: Dictionary) -> void:
	_commit_enemy_event(&"action_changed", {"previous": previous, "current": current})


func _commit_enemy_event(kind: StringName, payload: Dictionary) -> void:
	_event_sequence += 1
	_last_enemy_event = {
		"event_id": "run-%06d:enemy:%s:%06d" % [run_epoch, stable_id, _event_sequence],
		"run_epoch": run_epoch,
		"kind": kind,
		"actor_id": stable_id,
		"region": region_id,
		"role": tactical_role,
		"payload": payload.duplicate(true),
	}
	authoritative_enemy_event.emit(_last_enemy_event.duplicate(true))


func _mcp_state() -> Dictionary:
	var snapshot := authoritative_snapshot()
	var inspection: Dictionary = snapshot.get("inspection_state", {})
	return {
		"actor_id": stable_id,
		"presentation_state": {
			"skin": (snapshot.get("presentation", {}) as Dictionary).get("skin_id", ""),
			"library": (snapshot.get("presentation", {}) as Dictionary).get("animation_library", ""),
			"clip": snapshot.get("animation_name", ""),
			"semantic": snapshot.get("animation_semantic", &""),
			"playback_time": snapshot.get("animation_position_seconds", 0.0),
			"normalized_time": snapshot.get("animation_normalized_time", 0.0),
			"playing": snapshot.get("animation_playing", false),
			"weapon_family": snapshot.get("weapon_family", &"unbound"),
			"weapon_family_compatible": snapshot.get("weapon_family_compatible", false),
			"weapon_socket_bound": snapshot.get("weapon_socket_bound", false),
			"weapon_attached": snapshot.get("weapon_attached", false),
			"root_upright": snapshot.get("root_upright", false),
			"action_progress": snapshot.get("rifle_action_progress", 0.0),
		},
		"combat_correlation": {
			"action": snapshot.get("action", &"idle"),
			"velocity": snapshot.get("velocity", Vector3.ZERO),
			"safe_velocity_ready": snapshot.get("safe_velocity_ready", false),
			"safe_velocity_receipt_frame": snapshot.get("safe_velocity_receipt_frame", -1),
			"safe_velocity_consumed_frame": snapshot.get("safe_velocity_consumed_frame", -1),
			"safe_velocity_consumption_count": snapshot.get("safe_velocity_consumption_count", 0),
			"safe_velocity_callback_count": snapshot.get("safe_velocity_callback_count", 0),
			"safe_velocity_duplicate_callback_count": snapshot.get("safe_velocity_duplicate_callback_count", 0),
			"peer_cache": snapshot.get("peer_cache", {}),
			"shot_id": snapshot.get("shot_event_id", ""),
			"shot_result": (snapshot.get("last_event", {}) as Dictionary).get("payload", {}).get("result", &"none") if snapshot.get("last_event", {}) is Dictionary else &"none",
			"ammo": snapshot.get("ammo", 0),
			"last_attack": (snapshot.get("shot_causality", {}) as Dictionary).duplicate(true),
		},
		"presentation_correlation": {
			"skin": (snapshot.get("presentation", {}) as Dictionary).get("skin_id", ""),
			"library": (snapshot.get("presentation", {}) as Dictionary).get("animation_library", ""),
			"clip": snapshot.get("animation_name", ""),
			"semantic": snapshot.get("animation_semantic", &""),
			"playback_time": snapshot.get("animation_position_seconds", 0.0),
			"normalized_time": snapshot.get("animation_normalized_time", 0.0),
			"playing": snapshot.get("animation_playing", false),
			"weapon_family": snapshot.get("weapon_family", &"unbound"),
			"weapon_family_compatible": snapshot.get("weapon_family_compatible", false),
			"weapon_socket_bound": snapshot.get("weapon_socket_bound", false),
			"weapon_attached": snapshot.get("weapon_attached", false),
			"root_upright": snapshot.get("root_upright", false),
			"root_pitch_degrees": snapshot.get("root_pitch_degrees", 0.0),
			"root_roll_degrees": snapshot.get("root_roll_degrees", 0.0),
			"action_progress": snapshot.get("rifle_action_progress", 0.0),
		},
		"active": mission_active,
		"alive": is_alive(),
		"region": region_id,
		"route_slot": route_slot,
		"position": global_position,
		"grounded_physics": is_on_floor(),
		"grounded_occupancy": snapshot.get("grounded_occupancy", false),
		"direct_floor_support": _last_floor_support_receipt,
		"capsule_clear": inspection.get("capsule_clear", false),
		"capsule_static_blockers": inspection.get("capsule_static_blockers", -1),
		"visible_contact": _last_floor_support_receipt.get("visual_contact", {}),
		"tester_prepared_hold": _tester_prepared_hold,
		"setup_generation": _tester_prepared_generation,
		"tester_search_fixture_receipt": _tester_search_fixture_receipt,
		"restore_epoch": _restore_epoch,
		"run_epoch": run_epoch,
	}
