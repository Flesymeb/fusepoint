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
var _last_progress_position := Vector3.ZERO
var _stalled_seconds := 0.0
var _progress_watchdog_count := 0
var _combat_profile: Dictionary = {}
var _tester_prepared_hold := false
var _tester_prepared_generation := 0


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
	}, true)
	return receipt


func clear_tester_prepared_hold() -> void:
	_tester_prepared_hold = false
	_tester_prepared_generation = 0
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
		"reservation": _route_reservation.duplicate(true),
		"stalled_seconds": _stalled_seconds,
		"progress_watchdog_count": _progress_watchdog_count,
		"grounded_occupancy": is_on_floor(),
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
	event["actor_id"] = stable_id
	event["weapon_id"] = &"rift_carbine"
	event["region"] = region_id
	event["role"] = tactical_role
	event["ammo_after"] = rounds_remaining
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
	var admitted_velocity := _separation_safe_velocity(desired_velocity)
	_reserve_route_window(admitted_velocity)
	super._submit_navigation_velocity(admitted_velocity)
	# The parent consumes the last NavigationServer receipt. Apply the same
	# admission rule to that receipt before CharacterBody3D moves this frame.
	var admitted_safe := _separation_safe_velocity(Vector3(velocity.x, 0.0, velocity.z))
	velocity.x = admitted_safe.x
	velocity.z = admitted_safe.z


func _on_navigation_velocity_computed(safe_velocity: Vector3) -> void:
	_navigation_safe_velocity = _separation_safe_velocity(safe_velocity)
	_navigation_safe_velocity_ready = true
	_reserve_route_window(_navigation_safe_velocity)


func _separation_safe_velocity(candidate: Vector3) -> Vector3:
	var admitted := Vector3(candidate.x, 0.0, candidate.z)
	var peers: Array[Node] = get_tree().get_nodes_in_group(&"fusepoint_enemy")
	peers.sort_custom(func(a: Node, b: Node) -> bool: return String(a.get("stable_id")) < String(b.get("stable_id")))
	for peer_node: Node in peers:
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
	for actor_id: Variant in _route_reservations.keys():
		var record: Dictionary = _route_reservations.get(actor_id, {})
		var actor := record.get("actor") as Node
		if actor == null or not is_instance_valid(actor) or int(record.get("expires_frame", -1)) < now_frame:
			_route_reservations.erase(actor_id)


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
	return authoritative_snapshot()
