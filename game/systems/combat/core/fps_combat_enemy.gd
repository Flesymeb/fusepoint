class_name FPSCombatEnemy
extends CharacterBody3D

signal ai_state_changed(previous: StringName, current: StringName, snapshot: Dictionary)
signal target_acquired(target: Node3D)
signal attack_resolved(event: Dictionary)
signal reload_started(snapshot: Dictionary)
signal reload_finished(snapshot: Dictionary)
signal enemy_died(event: Dictionary)
signal squad_alert_received(event: Dictionary)

enum AIState { IDLE, ALERT, SEARCH, CHASE, REPOSITION, SEEK_COVER, IN_COVER, EVADE, AIM, FIRE, RELOAD, HURT, DEAD }
enum Difficulty { EASY, MEDIUM, HARD }

@export_group("Bindings")
@export_node_path("FPSHealth") var health_path: NodePath = ^"Health"
@export_node_path("NavigationAgent3D") var navigation_agent_path: NodePath = ^"NavigationAgent3D"
@export_node_path("CollisionShape3D") var collision_shape_path: NodePath = ^"CollisionShape3D"
@export_node_path("Node3D") var eye_path: NodePath = ^"Eye"
@export_node_path("Node3D") var muzzle_path: NodePath = ^"Eye/Muzzle"
@export_node_path("Node") var presentation_path: NodePath
@export_node_path("Node3D") var target_path: NodePath
@export var target_group: StringName = &"fps_player"

@export_group("Perception and movement")
@export_range(1.0, 200.0, 0.5) var vision_range := 28.0
@export_range(30.0, 180.0, 1.0) var vision_fov_degrees := 120.0
@export_range(1.0, 100.0, 0.5) var forget_range := 40.0
@export_range(0.5, 100.0, 0.5) var attack_range := 18.0
@export_range(0.5, 100.0, 0.5) var walk_distance := 11.0
@export_range(0.5, 100.0, 0.5) var crouch_distance := 6.0
@export_range(0.25, 10.0, 0.05) var search_seconds := 3.0
@export_range(0.25, 10.0, 0.05) var home_return_distance := 1.5
@export_range(0.1, 20.0, 0.1) var move_speed := 3.5
@export_range(0.1, 30.0, 0.1) var rotation_speed := 8.0
@export_range(0.0, 3.0, 0.05) var reaction_delay := 0.45
@export_range(0.0, 3.0, 0.05) var hurt_stun_seconds := 0.34
@export_range(0.0, 3.0, 0.05) var target_height := 1.15
@export_range(1.0, 90.0, 1.0) var fire_facing_tolerance_degrees := 10.0
@export_flags_3d_physics var sight_collision_mask := 0xFFFFFFFF
@export_range(0.5, 5.0, 0.1) var targetless_patrol_radius := 2.8
@export_range(0.5, 5.0, 0.1) var targetless_scan_seconds := 1.2
@export_range(1.0, 5.0, 0.1) var targetless_watchdog_seconds := 4.0

@export_group("Tactical response")
@export var difficulty: Difficulty = Difficulty.MEDIUM
@export var cover_group: StringName = &"fps_enemy_cover"
@export_range(1.0, 50.0, 0.5) var cover_search_radius := 16.0
@export_range(0.1, 3.0, 0.05) var cover_arrival_distance := 0.75
@export_range(0.1, 10.0, 0.05) var cover_hold_seconds := 1.8
@export_range(-1.0, 1.0, 0.01) var cover_response_chance_override := -1.0
@export_range(-1.0, 1.0, 0.01) var evade_response_chance_override := -1.0
@export_range(0.5, 8.0, 0.1) var evade_distance := 3.0
@export_range(0.1, 3.0, 0.05) var evade_seconds := 0.8
@export_range(0.1, 3.0, 0.05) var cover_crouch_eye_height := 0.85
@export var require_cover_occlusion := true
@export var tactical_random_seed := 0
@export_range(2, 24, 1) var engagement_slot_count := 12
@export_range(0.2, 1.0, 0.05) var engagement_radius_ratio := 0.72
@export_range(1.0, 30.0, 0.5) var engagement_radius_min := 4.0
@export_range(1.0, 40.0, 0.5) var engagement_radius_max := 12.0
@export_range(0.5, 5.0, 0.1) var personal_space_radius := 1.4
@export_range(0.1, 3.0, 0.05) var engagement_arrival_distance := 0.9
@export_range(0.5, 15.0, 0.1) var reposition_interval_seconds := 5.0
@export_range(0.5, 15.0, 0.1) var reposition_timeout_seconds := 7.0
@export_range(-1.0, 1.0, 0.01) var flank_reposition_chance_override := -1.0
@export_range(0.5, 20.0, 0.5) var max_navigation_projection_distance := 4.0
@export_range(1.0, 80.0, 0.5) var squad_alert_radius := 22.0
@export_range(0.0, 1.0, 0.01) var squad_alert_reaction_jitter := 0.22
@export var squad_alert_group: StringName = &"fps_enemy"

@export_group("Attack")
@export_range(0.1, 1000.0, 0.5) var attack_damage := 10.0
@export_range(0.1, 10.0, 0.05) var attack_interval := 0.85
@export_range(0.05, 1.0, 0.01) var fire_pose_seconds := 0.18
@export_range(1, 200, 1) var magazine_size := 12
@export_range(0.05, 10.0, 0.05) var reload_seconds := 1.8
@export var attack_team: StringName = &"enemy"

@export_group("Physics")
@export_range(0.1, 80.0, 0.1) var gravity := 18.0
@export var direct_chase_without_navigation := true

@export_group("Audio")
@export_node_path("AudioStreamPlayer3D") var death_audio_path: NodePath = ^"DeathAudio"
@export var death_sound: AudioStream
@export var synthesize_default_death_sound := true
@export_range(-40.0, 12.0, 0.5) var death_sound_volume_db := -5.0
@export_range(0.25, 2.0, 0.01) var death_sound_pitch_scale := 0.92

var ai_state := AIState.IDLE
var target: Node3D
var last_attack_report: Dictionary = {}
var rounds_remaining := 0
var death_sound_event_count := 0
var run_epoch := 0

var _health: FPSHealth
var _navigation_agent: NavigationAgent3D
var _collision_shape: CollisionShape3D
var _eye: Node3D
var _muzzle: Node3D
var _presentation: Node
var _death_audio: AudioStreamPlayer3D
var _generated_death_sound: AudioStreamWAV
var _target_health: Node
var _home_position := Vector3.ZERO
var _has_home_position := false
var _last_seen_target_position := Vector3.ZERO
var _has_last_seen_target_position := false
var _last_seen_target_remaining := 0.0
var _reaction_remaining := 0.0
var _attack_remaining := 0.0
var _hurt_remaining := 0.0
var _fire_pose_remaining := 0.0
var _reload_remaining := 0.0
var _attack_sequence := 0
var _navigation_safe_velocity := Vector3.ZERO
var _navigation_safe_velocity_ready := false
var _navigation_desired_velocity := Vector3.ZERO
var _navigation_default_target_desired_distance := 0.0
var _cover_anchor: FPSCoverAnchor
var _pending_cover_after_hurt := false
var _cover_remaining := 0.0
var _cover_hold_started := false
var _evade_remaining := 0.0
var _evade_destination := Vector3.ZERO
var _last_threat_position := Vector3.ZERO
var _has_last_threat_position := false
var _last_tactical_decision: StringName = &"none"
var _cover_response_chance := 0.55
var _evade_response_chance := 0.35
var _flank_reposition_chance := 0.18
var _rng := RandomNumberGenerator.new()
var _engagement_slot_index := -1
var _engagement_projected_position := Vector3.ZERO
var _engagement_projection_rejection := &"unreserved"
var _reposition_decision_remaining := 0.0
var _reposition_timeout_remaining := 0.0
var _force_reposition := false
var _last_reposition_reason: StringName = &"none"
var _attack_attempts_on_current_target := 0
var _squad_alert_count := 0
var _last_alert_source_path := ""
var _targetless_destination := Vector3.ZERO
var _has_targetless_destination := false
var _targetless_action_remaining := 0.0
var _targetless_watchdog_remaining := 0.0
var _targetless_action: StringName = &"spawn_scan"
var _targetless_action_serial := 0
var _scan_direction := 1.0


func _ready() -> void:
	_apply_difficulty_profile()
	_rng.seed = tactical_random_seed if tactical_random_seed != 0 else hash("%s:%s" % [name, String(get_path())])
	_reposition_decision_remaining = _rng.randf_range(0.4, reposition_interval_seconds)
	_targetless_action_remaining = _rng.randf_range(0.15, 0.65)
	_targetless_watchdog_remaining = targetless_watchdog_seconds
	_scan_direction = -1.0 if _rng.randf() < 0.5 else 1.0
	_health = get_node_or_null(health_path) as FPSHealth
	_navigation_agent = get_node_or_null(navigation_agent_path) as NavigationAgent3D
	_collision_shape = get_node_or_null(collision_shape_path) as CollisionShape3D
	_eye = get_node_or_null(eye_path) as Node3D
	_muzzle = get_node_or_null(muzzle_path) as Node3D
	_presentation = get_node_or_null(presentation_path) if not presentation_path.is_empty() else null
	_death_audio = get_node_or_null(death_audio_path) as AudioStreamPlayer3D
	if _death_audio != null:
		_death_audio.volume_db = death_sound_volume_db
		_death_audio.pitch_scale = death_sound_pitch_scale
	_home_position = global_position
	_has_home_position = true
	if _presentation != null:
		_set_calibration_visuals_visible(false)
	if _navigation_agent != null:
		_navigation_default_target_desired_distance = _navigation_agent.target_desired_distance
		_navigation_agent.velocity_computed.connect(_on_navigation_velocity_computed)
		_navigation_agent.avoidance_enabled = true
		_navigation_agent.max_speed = move_speed
	rounds_remaining = maxi(magazine_size, 1)
	if _health == null:
		push_error("FPSCombatEnemy requires an FPSHealth child")
	else:
		_health.damaged.connect(_on_damaged)
		_health.died.connect(_on_died)
	if not target_path.is_empty():
		set_target(get_node_or_null(target_path) as Node3D)


func _physics_process(delta: float) -> void:
	if _health == null or _health.is_dead:
		velocity = Vector3.ZERO
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = -0.1
	_attack_remaining = maxf(0.0, _attack_remaining - delta)
	_hurt_remaining = maxf(0.0, _hurt_remaining - delta)
	_fire_pose_remaining = maxf(0.0, _fire_pose_remaining - delta)
	_last_seen_target_remaining = maxf(0.0, _last_seen_target_remaining - delta)
	if ai_state == AIState.IN_COVER and _cover_hold_started:
		_cover_remaining = maxf(0.0, _cover_remaining - delta)
	if ai_state == AIState.EVADE:
		_evade_remaining = maxf(0.0, _evade_remaining - delta)
	_reposition_decision_remaining = maxf(0.0, _reposition_decision_remaining - delta)
	if ai_state == AIState.REPOSITION:
		_reposition_timeout_remaining = maxf(0.0, _reposition_timeout_remaining - delta)
	if _reload_remaining > 0.0:
		_reload_remaining = maxf(0.0, _reload_remaining - delta)
		velocity.x = 0.0
		velocity.z = 0.0
		_set_ai_state(AIState.RELOAD)
		if _reload_remaining <= 0.0:
			rounds_remaining = maxi(magazine_size, 1)
			# Reloading does not make an already-tracked target "new" again.
			_reaction_remaining = 0.0
			reload_finished.emit(snapshot())
		move_and_slide()
		return
	if _hurt_remaining > 0.0:
		velocity.x = 0.0
		velocity.z = 0.0
		_set_ai_state(AIState.HURT)
		move_and_slide()
		return
	if _pending_cover_after_hurt and _cover_anchor != null:
		_pending_cover_after_hurt = false
		_set_ai_state(AIState.SEEK_COVER)
		_process_cover_response(delta)
		move_and_slide()
		return
	if _cover_anchor != null:
		_process_cover_response(delta)
		move_and_slide()
		return
	if _evade_remaining > 0.0:
		_process_evade(delta)
		move_and_slide()
		return
	if target == null or not is_instance_valid(target):
		_acquire_target()
	if _target_health != null and _target_health.get("is_dead") == true:
		set_target(null)
	if target == null:
		_search_or_return_home(delta)
		move_and_slide()
		return

	var distance := global_position.distance_to(target.global_position)
	if distance > forget_range:
		remember_target_position(target.global_position)
		set_target(null)
		_search_or_return_home(delta)
		move_and_slide()
		return
	var visible := _can_detect_target(target)
	if visible:
		remember_target_position(target.global_position)
	if _force_reposition:
		_process_engagement_reposition(delta)
	elif _fire_pose_remaining > 0.0:
		velocity.x = 0.0
		velocity.z = 0.0
		_face_target(delta)
		_set_ai_state(AIState.FIRE)
	elif distance <= attack_range and visible:
		if _should_reposition_from_combat():
			_process_engagement_reposition(delta)
			move_and_slide()
			return
		velocity.x = 0.0
		velocity.z = 0.0
		_face_target(delta)
		_reaction_remaining = maxf(0.0, _reaction_remaining - delta)
		if _reaction_remaining > 0.0 or not _is_facing_target():
			_set_ai_state(AIState.AIM)
		elif rounds_remaining <= 0:
			_begin_reload()
		elif _attack_remaining <= 0.0:
			_perform_attack()
		else:
			_set_ai_state(AIState.AIM)
	elif visible or _last_seen_target_remaining > 0.0:
		_chase_or_search(delta, visible)
	else:
		_search_or_return_home(delta)
	move_and_slide()


func set_target(next_target: Node3D) -> void:
	var target_changed := target != next_target
	if target_changed:
		_release_engagement_slot()
		_attack_attempts_on_current_target = 0
	target = next_target
	_target_health = _find_damage_receiver(target)
	if target != null:
		remember_target_position(target.global_position)
		if target_changed:
			_reaction_remaining = reaction_delay
			_reserve_engagement_slot(false)
			target_acquired.emit(target)
			_set_ai_state(AIState.ALERT)
	elif target_changed:
		_reaction_remaining = 0.0
		_set_ai_state(AIState.IDLE)


func acquire_candidate_if_visible(candidate: Node3D) -> bool:
	if candidate == null or not is_instance_valid(candidate) or not _can_detect_candidate(candidate):
		return false
	set_target(candidate)
	return true


func force_attack_if_ready() -> Dictionary:
	if target == null or _reaction_remaining > 0.0 or _attack_remaining > 0.0 or _reload_remaining > 0.0:
		return {"applied": false, "reason": "not_ready"}
	if not _is_facing_target():
		return {
			"applied": false,
			"reason": "not_facing_target",
			"facing_error_degrees": _facing_error_degrees(),
		}
	if rounds_remaining <= 0:
		_begin_reload()
		return {"applied": false, "reason": "reload_started"}
	return _perform_attack()


func set_run_epoch(epoch: int) -> bool:
	if epoch <= 0 or epoch < run_epoch:
		return false
	if epoch > run_epoch:
		_attack_sequence = 0
	run_epoch = epoch
	return true


func _fire_block_reason() -> String:
	if _health == null or _health.is_dead:
		return "dead"
	if target == null or not is_instance_valid(target):
		return "no_target"
	if _hurt_remaining > 0.0:
		return "hurt"
	if _cover_anchor != null:
		return "cover_response"
	if _evade_remaining > 0.0:
		return "evading"
	if _force_reposition:
		return "repositioning"
	if global_position.distance_to(target.global_position) > attack_range:
		return "outside_attack_range"
	if not _has_line_of_sight():
		return "line_of_fire_blocked"
	if _reaction_remaining > 0.0:
		return "reaction_delay"
	if _reload_remaining > 0.0:
		return "reloading"
	if rounds_remaining <= 0:
		return "empty_magazine"
	if not _is_facing_target():
		return "not_facing_target"
	if _attack_remaining > 0.0:
		return "attack_cooldown"
	return "ready"


func snapshot() -> Dictionary:
	return {
		"run_epoch": run_epoch,
		"state": state_name(),
		"target": String(target.get_path()) if target != null and target.is_inside_tree() else "",
		"target_distance": global_position.distance_to(target.global_position) if target != null and is_instance_valid(target) else -1.0,
		"target_visible": _can_detect_target(target) if target != null and is_instance_valid(target) else false,
		"fire_block_reason": _fire_block_reason(),
		"health": _health.snapshot() if _health != null else {},
		"reaction_remaining": _reaction_remaining,
		"attack_remaining": _attack_remaining,
		"fire_pose_remaining": _fire_pose_remaining,
		"rounds_remaining": rounds_remaining,
		"magazine_size": magazine_size,
		"reload_remaining": _reload_remaining,
		"is_reloading": _reload_remaining > 0.0,
		"last_seen_target_position": _last_seen_target_position,
		"last_seen_target_remaining": _last_seen_target_remaining,
		"facing_error_degrees": _facing_error_degrees(),
		"facing_target": _is_facing_target(),
		"last_attack": last_attack_report.duplicate(true),
		"can_attack": _health != null and not _health.is_dead and target != null,
		"death_audio_bound": _death_audio != null,
		"death_audio_stream_bound": _death_audio != null and _death_audio.stream != null,
		"death_audio_playing": _death_audio != null and _death_audio.playing,
		"death_sound_event_count": death_sound_event_count,
		"difficulty": Difficulty.keys()[difficulty].to_lower(),
		"cover_response_chance": _effective_cover_response_chance(),
		"evade_response_chance": _effective_evade_response_chance(),
		"cover_anchor": String(_cover_anchor.get_path()) if _cover_anchor != null and is_instance_valid(_cover_anchor) and _cover_anchor.is_inside_tree() else "",
		"in_cover": ai_state == AIState.IN_COVER,
		"cover_remaining": _cover_remaining,
		"evade_remaining": _evade_remaining,
		"last_tactical_decision": String(_last_tactical_decision),
		"last_threat_position": _last_threat_position,
		"has_last_threat_position": _has_last_threat_position,
		"navigation_safe_velocity": _navigation_safe_velocity,
		"navigation_desired_velocity": _navigation_desired_velocity,
		"navigation_safe_velocity_ready": _navigation_safe_velocity_ready,
		"engagement_slot_index": _engagement_slot_index,
		"engagement_slot_position": _engagement_destination(),
		"engagement_projection_rejection": _engagement_projection_rejection,
		"engagement_reservation_count": FPSEngagementSlots.reservation_count(target),
		"nearest_enemy_distance": _nearest_enemy_distance(),
		"crowded": _is_crowded(),
		"reposition_decision_remaining": _reposition_decision_remaining,
		"reposition_timeout_remaining": _reposition_timeout_remaining,
		"flank_reposition_chance": _effective_flank_reposition_chance(),
		"last_reposition_reason": String(_last_reposition_reason),
		"attack_attempts_on_current_target": _attack_attempts_on_current_target,
		"squad_alert_count": _squad_alert_count,
		"last_alert_source_path": _last_alert_source_path,
		"targetless_action": _targetless_action,
		"targetless_route_target": _targetless_destination if _has_targetless_destination else _home_position,
		"targetless_watchdog_remaining": _targetless_watchdog_remaining,
		"targetless_action_serial": _targetless_action_serial,
	}


func reset_volatile_combat_state_for_restore() -> void:
	# Checkpoint durability ends at identity/transform/health/ammo/activation.
	# Everything below is perception, authorization, navigation, reservation, or
	# transient presentation state and must never survive a restore boundary.
	target = null
	_target_health = null
	last_attack_report.clear()
	_last_seen_target_position = Vector3.ZERO
	_has_last_seen_target_position = false
	_last_seen_target_remaining = 0.0
	_reaction_remaining = 0.0
	_attack_remaining = 0.0
	_hurt_remaining = 0.0
	_fire_pose_remaining = 0.0
	_reload_remaining = 0.0
	_navigation_safe_velocity = Vector3.ZERO
	_navigation_desired_velocity = Vector3.ZERO
	_navigation_safe_velocity_ready = false
	_release_cover()
	_evade_remaining = 0.0
	_evade_destination = Vector3.ZERO
	_last_threat_position = Vector3.ZERO
	_has_last_threat_position = false
	_last_tactical_decision = &"checkpoint_quiescent"
	_release_engagement_slot()
	_reposition_decision_remaining = minf(reposition_interval_seconds, 1.0 + float(absi(tactical_random_seed) % 7) * 0.11)
	_reposition_timeout_remaining = 0.0
	_force_reposition = false
	_last_reposition_reason = &"checkpoint_restore"
	_attack_attempts_on_current_target = 0
	_squad_alert_count = 0
	_last_alert_source_path = ""
	_targetless_destination = Vector3.ZERO
	_has_targetless_destination = false
	_targetless_action_remaining = 0.0
	_targetless_watchdog_remaining = targetless_watchdog_seconds
	_targetless_action = &"checkpoint_quiescent"
	_targetless_action_serial = 0
	_scan_direction = -1.0 if absi(tactical_random_seed) % 2 == 0 else 1.0
	_rng.seed = tactical_random_seed if tactical_random_seed != 0 else hash("%s:%s" % [name, String(get_path())])
	_home_position = global_position
	_has_home_position = true
	velocity = Vector3.ZERO
	ai_state = AIState.IDLE
	if _navigation_agent != null:
		_navigation_agent.avoidance_enabled = false
		_navigation_agent.target_position = global_position
	if _death_audio != null:
		_death_audio.stop()


func state_name() -> String:
	return AIState.keys()[ai_state].to_lower()


static func difficulty_profile_for(level: Difficulty) -> Dictionary:
	match level:
		Difficulty.EASY:
			return {
				"reaction_scale": 1.45,
				"attack_interval_scale": 1.25,
				"facing_tolerance_scale": 1.35,
				"cover_chance": 0.30,
				"evade_chance": 0.15,
				"flank_chance": 0.06,
				"cover_hold_scale": 1.20,
			}
		Difficulty.HARD:
			return {
				"reaction_scale": 0.65,
				"attack_interval_scale": 0.78,
				"facing_tolerance_scale": 0.75,
				"cover_chance": 0.78,
				"evade_chance": 0.58,
				"flank_chance": 0.34,
				"cover_hold_scale": 0.75,
			}
		_:
			return {
				"reaction_scale": 1.0,
				"attack_interval_scale": 1.0,
				"facing_tolerance_scale": 1.0,
				"cover_chance": 0.55,
				"evade_chance": 0.35,
				"flank_chance": 0.18,
				"cover_hold_scale": 1.0,
			}


func _apply_difficulty_profile() -> void:
	var profile := difficulty_profile_for(difficulty)
	reaction_delay *= float(profile["reaction_scale"])
	attack_interval *= float(profile["attack_interval_scale"])
	fire_facing_tolerance_degrees *= float(profile["facing_tolerance_scale"])
	cover_hold_seconds *= float(profile["cover_hold_scale"])
	_cover_response_chance = float(profile["cover_chance"])
	_evade_response_chance = float(profile["evade_chance"])
	_flank_reposition_chance = float(profile["flank_chance"])


func _effective_cover_response_chance() -> float:
	return cover_response_chance_override if cover_response_chance_override >= 0.0 else _cover_response_chance


func _effective_evade_response_chance() -> float:
	return evade_response_chance_override if evade_response_chance_override >= 0.0 else _evade_response_chance


func _effective_flank_reposition_chance() -> float:
	return flank_reposition_chance_override if flank_reposition_chance_override >= 0.0 else _flank_reposition_chance


func _acquire_target() -> void:
	var best_candidate: Node3D = null
	var best_distance := INF
	for node: Node in get_tree().get_nodes_in_group(target_group):
		if not node is Node3D:
			continue
		var candidate := node as Node3D
		if not _can_detect_candidate(candidate):
			continue
		var distance := global_position.distance_to(candidate.global_position)
		if distance < best_distance:
			best_candidate = candidate
			best_distance = distance
	if best_candidate != null:
		set_target(best_candidate)


func _chase_or_search(delta: float, visible: bool) -> void:
	var destination := _engagement_destination() if visible and target != null else _last_seen_target_position
	if not visible and not _has_last_seen_target_position and _has_home_position:
		destination = _home_position
	var dist_to_destination := global_position.distance_to(destination)
	var move_state := _attack_locomotion_state(dist_to_destination)
	if visible:
		_set_ai_state(AIState.CHASE)
	else:
		_set_ai_state(AIState.SEARCH)
		if _last_seen_target_remaining <= 0.0:
			destination = _home_position
			move_state = _attack_locomotion_state(global_position.distance_to(destination))
	var next_point := destination
	if _navigation_agent != null:
		_navigation_agent.target_position = destination
		if not _navigation_agent.is_navigation_finished():
			var navigation_point := _navigation_agent.get_next_path_position()
			var navigation_path := _navigation_agent.get_current_navigation_path()
			# An agent without a baked/connected navigation region commonly
			# returns its own position or an empty path. Treat that as no usable
			# path and keep the direct-chase fallback instead of freezing in place.
			if navigation_path.size() >= 2 and navigation_point.distance_squared_to(global_position) > 0.01:
				next_point = navigation_point
			elif not direct_chase_without_navigation:
				velocity.x = 0.0
				velocity.z = 0.0
				_drive_locomotion_presentation(move_state)
				return
		elif not direct_chase_without_navigation:
			velocity.x = 0.0
			velocity.z = 0.0
			_drive_locomotion_presentation(move_state)
			return
	var direction := global_position.direction_to(next_point)
	direction.y = 0.0
	direction = direction.normalized()
	var desired_velocity := direction * move_speed
	if _navigation_agent != null:
		_submit_navigation_velocity(desired_velocity)
	else:
		velocity.x = desired_velocity.x
		velocity.z = desired_velocity.z
	_face_direction(direction, delta)
	_drive_locomotion_presentation(move_state)


func _should_reposition_from_combat() -> bool:
	# Personal-space authority precedes attack authority. An actor in a collapsed
	# occupancy must clear its reserved slot before its first legal shot.
	if _is_crowded():
		_force_reposition = true
		_reposition_timeout_remaining = reposition_timeout_seconds
		_last_reposition_reason = &"personal_space"
		return true
	# Once occupancy is clear, keep the first readable contact free of an
	# optional flank decision.
	if _attack_attempts_on_current_target <= 0:
		return false
	if _reposition_decision_remaining > 0.0:
		return false
	_reposition_decision_remaining = reposition_interval_seconds
	if _rng.randf() > _effective_flank_reposition_chance():
		return false
	if not _reserve_engagement_slot(true):
		_last_reposition_reason = &"no_alternate_slot"
		return false
	_force_reposition = true
	_reposition_timeout_remaining = reposition_timeout_seconds
	_last_reposition_reason = &"flank_change"
	return true


func _process_engagement_reposition(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		_force_reposition = false
		return
	if _engagement_slot_index < 0 and not _reserve_engagement_slot(false):
		_force_reposition = false
		_last_reposition_reason = &"no_slot"
		return
	var destination := _engagement_destination()
	var horizontal_delta := destination - global_position
	horizontal_delta.y = 0.0
	if horizontal_delta.length() <= engagement_arrival_distance:
		velocity.x = 0.0
		velocity.z = 0.0
		_force_reposition = false
		_reposition_timeout_remaining = 0.0
		_last_reposition_reason = &"slot_reached"
		_restore_navigation_arrival_distance()
		_face_target(delta)
		_set_ai_state(AIState.AIM)
		return
	if _reposition_timeout_remaining <= 0.0:
		_force_reposition = false
		_last_reposition_reason = &"slot_timeout"
		_restore_navigation_arrival_distance()
		return
	_set_ai_state(AIState.REPOSITION)
	_move_to_tactical_destination(destination, delta, &"run", engagement_arrival_distance)


func _reserve_engagement_slot(prefer_different: bool) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var available := FPSEngagementSlots.available_indices(self, target, engagement_slot_count)
	if prefer_different and available.size() > 1:
		available.erase(_engagement_slot_index)
	if available.is_empty():
		return false
	var radius := _engagement_radius()
	var best_index := -1
	var best_score := INF
	var best_position := Vector3.ZERO
	for slot_index: int in available:
		var candidate := FPSEngagementSlots.position_for(target, slot_index, engagement_slot_count, radius)
		candidate = _project_engagement_position(candidate)
		if not FPSEngagementSlots.projected_position_available(self, target, candidate, personal_space_radius):
			continue
		var score := global_position.distance_to(candidate)
		if not _candidate_has_line_of_fire(candidate):
			score += attack_range * 2.0
		if score < best_score:
			best_score = score
			best_index = slot_index
			best_position = candidate
	if best_index < 0:
		_engagement_projection_rejection = &"no_separated_projected_slot"
		return false
	if not FPSEngagementSlots.reserve(self, target, best_index, best_position, personal_space_radius):
		_engagement_projection_rejection = &"projection_reservation_race"
		return false
	_engagement_slot_index = best_index
	_engagement_projected_position = best_position
	_engagement_projection_rejection = &""
	return true


func _release_engagement_slot() -> void:
	if target != null and is_instance_valid(target):
		FPSEngagementSlots.release(self, target)
	_engagement_slot_index = -1
	_engagement_projected_position = Vector3.ZERO
	_engagement_projection_rejection = &"released"
	_force_reposition = false
	_reposition_timeout_remaining = 0.0


func _engagement_radius() -> float:
	return clampf(attack_range * engagement_radius_ratio, engagement_radius_min, engagement_radius_max)


func _engagement_destination() -> Vector3:
	if target == null or not is_instance_valid(target):
		return _last_seen_target_position
	if _engagement_slot_index < 0:
		# No reservation means no movement authority toward the shared target
		# origin. Hold the current capsule until a separated slot is available.
		return global_position
	var raw_position := FPSEngagementSlots.position_for(
		target,
		_engagement_slot_index,
		engagement_slot_count,
		_engagement_radius(),
	)
	var projected := _project_engagement_position(raw_position)
	if FPSEngagementSlots.update_projected_position(self, target, projected, personal_space_radius):
		_engagement_projected_position = projected
		_engagement_projection_rejection = &""
	else:
		_engagement_projection_rejection = &"moving_target_projection_collapsed"
	return _engagement_projected_position


func _project_engagement_position(position: Vector3) -> Vector3:
	if _navigation_agent == null:
		return position
	var navigation_map := _navigation_agent.get_navigation_map()
	if not navigation_map.is_valid() or NavigationServer3D.map_get_iteration_id(navigation_map) <= 0:
		return position
	var projected := NavigationServer3D.map_get_closest_point(navigation_map, position)
	return projected if projected.distance_to(position) <= max_navigation_projection_distance else position


func _candidate_has_line_of_fire(position: Vector3) -> bool:
	if target == null:
		return false
	var start := position + Vector3.UP * (target_height + 0.3)
	var endpoint := _target_aim_position(target)
	var query := PhysicsRayQueryParameters3D.create(start, endpoint, sight_collision_mask, [get_rid()])
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty() or _belongs_to_target(hit.get("collider") as Node)


func _nearest_enemy_distance() -> float:
	var nearest := INF
	for node: Node in get_tree().get_nodes_in_group(&"fps_enemy"):
		if node == self or not node is Node3D:
			continue
		var actor := node as Node3D
		var actor_health := _find_damage_receiver(actor)
		if actor_health != null and actor_health.get("is_dead") == true:
			continue
		nearest = minf(nearest, global_position.distance_to(actor.global_position))
	return nearest


func _is_crowded() -> bool:
	return _nearest_enemy_distance() < personal_space_radius


func _process_cover_response(delta: float) -> void:
	if _cover_anchor == null or not is_instance_valid(_cover_anchor):
		_cover_anchor = null
		_pending_cover_after_hurt = false
		return
	var destination := _cover_anchor.crouch_position()
	var horizontal_delta := destination - global_position
	horizontal_delta.y = 0.0
	if horizontal_delta.length() <= cover_arrival_distance:
		velocity.x = 0.0
		velocity.z = 0.0
		if not _cover_hold_started:
			_cover_hold_started = true
			_cover_remaining = cover_hold_seconds
		_set_ai_state(AIState.IN_COVER)
		_drive_locomotion_presentation(&"crouch_idle")
		_face_known_threat(delta)
		if _cover_remaining <= 0.0:
			_last_tactical_decision = &"cover_hold_complete"
			_release_cover()
		return
	_set_ai_state(AIState.SEEK_COVER)
	_move_to_tactical_destination(destination, delta, &"crouch_move", cover_arrival_distance)


func _process_evade(delta: float) -> void:
	if _evade_remaining <= 0.0:
		_restore_navigation_arrival_distance()
		_last_tactical_decision = &"evade_complete"
		return
	var horizontal_delta := _evade_destination - global_position
	horizontal_delta.y = 0.0
	if horizontal_delta.length() <= cover_arrival_distance:
		_evade_remaining = 0.0
		velocity.x = 0.0
		velocity.z = 0.0
		_restore_navigation_arrival_distance()
		_last_tactical_decision = &"evade_complete"
		return
	_set_ai_state(AIState.EVADE)
	_move_to_tactical_destination(_evade_destination, delta, &"run", cover_arrival_distance)


func _move_to_tactical_destination(
	destination: Vector3,
	delta: float,
	locomotion: StringName,
	arrival_distance: float,
) -> void:
	var next_point := destination
	if _navigation_agent != null:
		_navigation_agent.target_desired_distance = arrival_distance
		_navigation_agent.target_position = destination
		if not _navigation_agent.is_navigation_finished():
			var navigation_point := _navigation_agent.get_next_path_position()
			var navigation_path := _navigation_agent.get_current_navigation_path()
			if navigation_path.size() >= 2 and navigation_point.distance_squared_to(global_position) > 0.01:
				next_point = navigation_point
			elif not direct_chase_without_navigation:
				velocity.x = 0.0
				velocity.z = 0.0
				_drive_locomotion_presentation(locomotion)
				return
		elif not direct_chase_without_navigation:
			velocity.x = 0.0
			velocity.z = 0.0
			_drive_locomotion_presentation(locomotion)
			return
	var direction := global_position.direction_to(next_point)
	direction.y = 0.0
	direction = direction.normalized()
	var desired_velocity := direction * move_speed
	if _navigation_agent != null:
		_submit_navigation_velocity(desired_velocity)
	else:
		velocity.x = desired_velocity.x
		velocity.z = desired_velocity.z
	_face_direction(direction, delta)
	_drive_locomotion_presentation(locomotion)


func _submit_navigation_velocity(desired_velocity: Vector3) -> void:
	_navigation_desired_velocity = Vector3(desired_velocity.x, 0.0, desired_velocity.z)
	_navigation_agent.set_velocity(_navigation_desired_velocity)
	# Navigation avoidance is computed at the server sync boundary. Consume only
	# the last velocity_computed receipt; never move on an unqualified desired
	# velocity during the first frame of activation or after a restore.
	if _navigation_safe_velocity_ready:
		velocity.x = _navigation_safe_velocity.x
		velocity.z = _navigation_safe_velocity.z
	else:
		velocity.x = 0.0
		velocity.z = 0.0


func _select_cover_anchor(threat_position: Vector3) -> FPSCoverAnchor:
	var best_anchor: FPSCoverAnchor
	var best_score := INF
	for node: Node in get_tree().get_nodes_in_group(cover_group):
		if not node is FPSCoverAnchor:
			continue
		var anchor := node as FPSCoverAnchor
		if not anchor.is_available_for(self):
			continue
		var distance := global_position.distance_to(anchor.crouch_position())
		if distance > cover_search_radius:
			continue
		var occluded := _is_cover_occluded_from(threat_position, anchor.crouch_position())
		if require_cover_occlusion and not occluded:
			continue
		# Occlusion is the primary contract. Within the valid set, select the
		# nearest anchor so taking cover remains readable and bounded.
		var score := distance + (0.0 if occluded else cover_search_radius)
		if score < best_score:
			best_score = score
			best_anchor = anchor
	return best_anchor


func _is_cover_occluded_from(threat_position: Vector3, cover_position: Vector3) -> bool:
	var endpoint := cover_position + Vector3.UP * cover_crouch_eye_height
	# Start beyond the attacker's own character collider. A ray that merely hits
	# the player/enemy who fired is not proof that the destination has cover.
	var start := threat_position + threat_position.direction_to(endpoint) * 0.75
	var query := PhysicsRayQueryParameters3D.create(start, endpoint, sight_collision_mask, [get_rid()])
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var collider := hit.get("collider") as Node
	return not _node_or_ancestor_is_actor(collider)


func _node_or_ancestor_is_actor(node: Node) -> bool:
	var cursor := node
	while cursor != null:
		if cursor.is_in_group(target_group) or cursor.is_in_group(&"fps_enemy"):
			return true
		cursor = cursor.get_parent()
	return false


func _plan_tactical_response(event: Dictionary) -> void:
	var threat_position: Variant = _threat_position_from_event(event)
	if threat_position == null:
		return
	_last_threat_position = threat_position
	_has_last_threat_position = true
	remember_target_position(threat_position)
	_face_position_immediately(threat_position)
	var attacker := _attacker_from_event(event)
	if attacker == null:
		attacker = _find_target_near_threat(threat_position)
	if attacker != null and attacker != target:
		set_target(attacker)
	var cover_roll := _rng.randf()
	if cover_roll <= _effective_cover_response_chance():
		var candidate := _select_cover_anchor(threat_position)
		if candidate != null and candidate.try_reserve(self):
			if _cover_anchor != candidate:
				_release_cover()
			_cover_anchor = candidate
			_cover_hold_started = false
			_cover_remaining = 0.0
			_pending_cover_after_hurt = true
			_evade_remaining = 0.0
			_last_tactical_decision = &"seek_cover"
			return
	_release_cover()
	if _rng.randf() <= _effective_evade_response_chance():
		_plan_evade(threat_position)
	else:
		_last_tactical_decision = &"hold_and_return_fire"


func _plan_evade(threat_position: Vector3) -> void:
	var away := threat_position.direction_to(global_position)
	away.y = 0.0
	if away.length_squared() <= 0.0001:
		away = -global_basis.z
	away = away.normalized()
	var lateral := Vector3(-away.z, 0.0, away.x)
	if _rng.randf() < 0.5:
		lateral = -lateral
	_evade_destination = global_position + (lateral * evade_distance) + (away * evade_distance * 0.25)
	_evade_remaining = evade_seconds
	_pending_cover_after_hurt = false
	_last_tactical_decision = &"evade"


func _threat_position_from_event(event: Dictionary) -> Variant:
	var origin: Variant = event.get("origin", null)
	if origin is Vector3:
		return origin
	var hit_position: Variant = event.get("hit_position", null)
	var direction: Variant = event.get("direction", null)
	if hit_position is Vector3 and direction is Vector3 and (direction as Vector3).length_squared() > 0.0001:
		return (hit_position as Vector3) - (direction as Vector3).normalized() * 4.0
	return null


func _find_target_near_threat(threat_position: Vector3) -> Node3D:
	var best: Node3D
	var best_distance := INF
	for node: Node in get_tree().get_nodes_in_group(target_group):
		if not node is Node3D:
			continue
		var candidate := node as Node3D
		var distance := candidate.global_position.distance_to(threat_position)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


func _attacker_from_event(event: Dictionary) -> Node3D:
	var source_path := NodePath(String(event.get("source_path", "")))
	if source_path.is_empty():
		return null
	return get_node_or_null(source_path) as Node3D


func _face_position_immediately(position: Vector3) -> void:
	var direction := global_position.direction_to(position)
	direction.y = 0.0
	if direction.length_squared() <= 0.0001:
		return
	rotation.y = atan2(-direction.x, -direction.z)


func _face_known_threat(delta: float) -> void:
	if target != null and is_instance_valid(target):
		_face_target(delta)
	elif _has_last_threat_position:
		var direction := global_position.direction_to(_last_threat_position)
		direction.y = 0.0
		_face_direction(direction.normalized(), delta)


func _release_cover() -> void:
	if _cover_anchor != null and is_instance_valid(_cover_anchor):
		_cover_anchor.release(self)
	_cover_anchor = null
	_pending_cover_after_hurt = false
	_cover_hold_started = false
	_cover_remaining = 0.0
	_restore_navigation_arrival_distance()


func _restore_navigation_arrival_distance() -> void:
	if _navigation_agent != null and _navigation_default_target_desired_distance > 0.0:
		_navigation_agent.target_desired_distance = _navigation_default_target_desired_distance


func _search_or_return_home(delta: float) -> void:
	if _last_seen_target_remaining > 0.0 and _has_last_seen_target_position:
		_set_ai_state(AIState.SEARCH)
		_chase_or_search(delta, false)
		return
	_process_targetless_behavior(delta)


func _process_targetless_behavior(delta: float) -> void:
	_targetless_action_remaining = maxf(0.0, _targetless_action_remaining - delta)
	_targetless_watchdog_remaining = maxf(0.0, _targetless_watchdog_remaining - delta)
	if _targetless_watchdog_remaining <= 0.0:
		_has_targetless_destination = false
		_targetless_action_remaining = 0.0
		_targetless_action = &"watchdog_replan"
	if not _has_targetless_destination and _targetless_action_remaining <= 0.0:
		_select_targetless_patrol_destination()
	if _has_targetless_destination:
		var horizontal := _targetless_destination - global_position
		horizontal.y = 0.0
		if horizontal.length() > home_return_distance * 0.55:
			_set_ai_state(AIState.SEARCH)
			_move_to_tactical_destination(_targetless_destination, delta, &"walk", home_return_distance * 0.45)
			_targetless_action = &"patrol"
			return
		_has_targetless_destination = false
		_targetless_action = &"scan"
		_targetless_action_remaining = targetless_scan_seconds
		_targetless_watchdog_remaining = targetless_watchdog_seconds
	velocity.x = 0.0
	velocity.z = 0.0
	rotation.y += _scan_direction * rotation_speed * 0.18 * delta
	_set_ai_state(AIState.SEARCH)
	_drive_locomotion_presentation(&"idle")


func _select_targetless_patrol_destination() -> void:
	_targetless_action_serial += 1
	var angle := float(_targetless_action_serial) * 2.399963 + _rng.randf_range(-0.3, 0.3)
	var radius := targetless_patrol_radius * _rng.randf_range(0.72, 1.0)
	var candidate := _home_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
	if _navigation_agent != null:
		var navigation_map := _navigation_agent.get_navigation_map()
		if navigation_map.is_valid() and NavigationServer3D.map_get_iteration_id(navigation_map) > 0:
			var projected := NavigationServer3D.map_get_closest_point(navigation_map, candidate)
			if projected.distance_to(candidate) <= max_navigation_projection_distance:
				candidate = projected
	_targetless_destination = candidate
	_has_targetless_destination = true
	_targetless_action = &"patrol_planned"
	_targetless_action_remaining = targetless_scan_seconds
	_targetless_watchdog_remaining = targetless_watchdog_seconds
	_scan_direction *= -1.0


func remember_target_position(position: Vector3) -> void:
	_last_seen_target_position = position
	_has_last_seen_target_position = true
	_last_seen_target_remaining = search_seconds


func _can_detect_candidate(candidate: Node3D) -> bool:
	if candidate == null:
		return false
	var distance := global_position.distance_to(candidate.global_position)
	if distance > vision_range:
		return false
	if not _is_inside_vision_cone(candidate):
		return false
	return _has_line_of_sight_to(candidate)


func _can_detect_target(candidate: Node3D) -> bool:
	if candidate == null or global_position.distance_to(candidate.global_position) > vision_range:
		return false
	# Horizontal FOV is an acquisition gate, not a permanent-awareness gate.
	# Once an actor has confirmed a target, path-facing or a brief flank must not
	# erase that target while range and line of sight still prove its presence.
	return _has_line_of_sight_to(candidate)


func _is_inside_vision_cone(candidate: Node3D) -> bool:
	if candidate == null:
		return false
	var direction := global_position.direction_to(candidate.global_position)
	direction.y = 0.0
	if direction.length_squared() <= 0.0001:
		return true
	var actor_forward := -global_basis.z.normalized()
	actor_forward.y = 0.0
	actor_forward = actor_forward.normalized()
	var angle := rad_to_deg(acos(clampf(actor_forward.dot(direction.normalized()), -1.0, 1.0)))
	return angle <= vision_fov_degrees * 0.5


func _has_line_of_sight_to(candidate: Node3D) -> bool:
	if candidate == null or _eye == null:
		return false
	var endpoint := _target_aim_position(candidate)
	var query := PhysicsRayQueryParameters3D.create(
		_eye.global_position,
		endpoint,
		sight_collision_mask,
		_perception_excluded_rids(),
	)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider := hit.get("collider") as Node
	var cursor := collider
	while cursor != null:
		if cursor == candidate:
			return true
		cursor = cursor.get_parent()
	return false


func _perception_excluded_rids() -> Array[RID]:
	var excluded: Array[RID] = [get_rid()]
	# Friendly bodies should block bullets, but they should not erase an already
	# visible target from squad perception or make rear agents forget the player.
	for node: Node in get_tree().get_nodes_in_group(&"fps_enemy"):
		if node is CollisionObject3D and node != self:
			excluded.append((node as CollisionObject3D).get_rid())
	return excluded


func _attack_locomotion_state(distance: float) -> StringName:
	# Distance to a target is not a reason to crouch. Crouch presentation is
	# owned exclusively by _process_cover_response(), where a real, reserved
	# cover anchor supplies the semantic reason for that pose.
	if distance <= walk_distance:
		return &"walk"
	return &"run"


func _drive_locomotion_presentation(state: StringName) -> void:
	if _presentation == null:
		return
	if _presentation.has_method("set_locomotion_state"):
		_presentation.call("set_locomotion_state", state)
	elif _presentation.has_method(state):
		_presentation.call(state)
	if _presentation.has_method("set_locomotion_speed"):
		_presentation.call("set_locomotion_speed", Vector2(velocity.x, velocity.z).length())


func _perform_attack() -> Dictionary:
	if not _is_facing_target():
		return {
			"applied": false,
			"reason": "not_facing_target",
			"facing_error_degrees": _facing_error_degrees(),
		}
	if rounds_remaining <= 0:
		_begin_reload()
		return {"applied": false, "reason": "reload_started"}
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
	var result := StringName(trace.get("result", &"miss"))
	var report := {
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
		"applied": false,
		"reason": "resolved_%s" % String(result),
	}
	if result == &"hit" and target != null and _target_health != null:
		report = _target_health.call("apply_damage", attack_damage, report)
		report["accepted"] = true
		report["hit"] = report.get("applied", false) == true
		report["origin"] = _eye.global_position if _eye != null else global_position
		report["muzzle_origin"] = _muzzle.global_position if _muzzle != null else global_position
		report["direction"] = shot_direction
		report["hit_position"] = trace.get("position", shot_endpoint)
		report["hit_normal"] = trace.get("normal", Vector3.UP)
		report["result"] = &"hit"
		report["surface_kind"] = &"character"
		report["ammo_before"] = rounds_remaining + 1
		report["ammo_after"] = rounds_remaining
		report["ammo_commit"] = 1
	last_attack_report = report
	attack_resolved.emit(report)
	return report


func _resolve_attack_trace(origin: Vector3, endpoint: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(origin, endpoint, sight_collision_mask, [get_rid()])
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"result": &"miss", "position": endpoint, "normal": Vector3.UP, "surface_kind": &"air"}
	var collider := hit.get("collider") as Node
	if _belongs_to_target(collider):
		return {"result": &"hit", "position": hit.get("position", endpoint), "normal": hit.get("normal", Vector3.UP), "surface_kind": &"character"}
	return {
		"result": &"blocked",
		"position": hit.get("position", endpoint),
		"normal": hit.get("normal", Vector3.UP),
		"surface_kind": _surface_kind_for(collider),
	}


func _surface_kind_for(collider: Node) -> StringName:
	if collider == null:
		return &"concrete"
	var hint := String(collider.name).to_lower()
	if "metal" in hint or "fence" in hint or "container" in hint or "gate" in hint:
		return &"metal"
	return &"concrete"


func _begin_reload() -> void:
	if _health == null or _health.is_dead or _reload_remaining > 0.0:
		return
	_reload_remaining = maxf(reload_seconds, 0.05)
	_set_ai_state(AIState.RELOAD)
	reload_started.emit(snapshot())


func _has_line_of_sight() -> bool:
	if target == null or _eye == null:
		return false
	var endpoint := _target_aim_position(target)
	var query := PhysicsRayQueryParameters3D.create(
		_eye.global_position,
		endpoint,
		sight_collision_mask,
		[get_rid()],
	)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	return _belongs_to_target(hit.get("collider") as Node)


func _belongs_to_target(node: Node) -> bool:
	var cursor := node
	while cursor != null:
		if cursor == target:
			return true
		cursor = cursor.get_parent()
	return false


func _target_aim_position(candidate: Node3D) -> Vector3:
	if candidate == null:
		return global_position - global_basis.z
	var head := candidate.get_node_or_null("Head") as Node3D
	return head.global_position if head != null else candidate.global_position + Vector3.UP * target_height


func _find_damage_receiver(root: Node) -> Node:
	if root == null:
		return null
	if root.has_method("apply_damage"):
		return root
	for child: Node in root.get_children():
		if child.has_method("apply_damage"):
			return child
	return null


func _face_target(delta: float) -> void:
	if target != null:
		var direction := global_position.direction_to(target.global_position)
		direction.y = 0.0
		_face_direction(direction.normalized(), delta)


func _on_navigation_velocity_computed(safe_velocity: Vector3) -> void:
	_navigation_safe_velocity = safe_velocity
	_navigation_safe_velocity_ready = true


func _face_direction(direction: Vector3, delta: float) -> void:
	if direction.length_squared() <= 0.0001:
		return
	var target_yaw := atan2(-direction.x, -direction.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, clampf(rotation_speed * delta, 0.0, 1.0))


func _is_facing_target() -> bool:
	return target != null and _facing_error_degrees() <= fire_facing_tolerance_degrees


func _facing_error_degrees() -> float:
	if target == null:
		return 180.0
	var target_direction := global_position.direction_to(target.global_position)
	target_direction.y = 0.0
	if target_direction.length_squared() <= 0.0001:
		return 0.0
	var actor_forward := -global_basis.z.normalized()
	actor_forward.y = 0.0
	actor_forward = actor_forward.normalized()
	return rad_to_deg(acos(clampf(actor_forward.dot(target_direction.normalized()), -1.0, 1.0)))


func _set_ai_state(next_state: AIState) -> void:
	if ai_state == next_state:
		return
	var previous := StringName(state_name())
	ai_state = next_state
	var current := StringName(state_name())
	match next_state:
		AIState.AIM:
			_drive_action_presentation(&"aim")
		AIState.FIRE:
			_drive_action_presentation(&"fire")
		AIState.RELOAD:
			_drive_action_presentation(&"reload")
		AIState.HURT:
			_drive_action_presentation(&"take_hit")
		AIState.DEAD:
			_drive_action_presentation(&"die")
	ai_state_changed.emit(previous, current, snapshot())


func _drive_action_presentation(state: StringName) -> void:
	if _presentation == null:
		return
	if _presentation.has_method(state):
		_presentation.call(state)


func _on_damaged(event: Dictionary) -> void:
	if _health == null or _health.is_dead:
		return
	_reload_remaining = 0.0
	_plan_tactical_response(event)
	_broadcast_squad_alert(event)
	_hurt_remaining = hurt_stun_seconds
	if ai_state == AIState.HURT:
		# Consecutive real hits restart the reaction instead of being swallowed
		# merely because the semantic state name did not change.
		_drive_action_presentation(&"take_hit")
	else:
		_set_ai_state(AIState.HURT)


func receive_squad_alert(attacker: Node3D, threat_position: Vector3, source: FPSCombatEnemy) -> bool:
	if not is_physics_processing() or _health == null or _health.is_dead or source == null or source == self:
		return false
	if not _is_same_squad(source):
		return false
	_last_threat_position = threat_position
	_has_last_threat_position = true
	remember_target_position(threat_position)
	var acquired_new_attacker := attacker != null and is_instance_valid(attacker) and attacker != target
	if attacker != null and is_instance_valid(attacker):
		set_target(attacker)
		if acquired_new_attacker:
			_reaction_remaining += _rng.randf_range(0.0, squad_alert_reaction_jitter)
	elif target == null:
		_set_ai_state(AIState.ALERT)
	_squad_alert_count += 1
	_last_alert_source_path = String(source.get_path()) if source.is_inside_tree() else ""
	var alert_event := {
		"source_path": _last_alert_source_path,
		"attacker_path": String(attacker.get_path()) if attacker != null and attacker.is_inside_tree() else "",
		"threat_position": threat_position,
	}
	squad_alert_received.emit(alert_event)
	return true


func _broadcast_squad_alert(event: Dictionary) -> void:
	var threat_position: Variant = _threat_position_from_event(event)
	if threat_position == null:
		return
	var attacker := _attacker_from_event(event)
	if attacker == null:
		attacker = _find_target_near_threat(threat_position)
	for node: Node in get_tree().get_nodes_in_group(squad_alert_group):
		if not node is FPSCombatEnemy or node == self:
			continue
		var ally := node as FPSCombatEnemy
		if global_position.distance_to(ally.global_position) > squad_alert_radius:
			continue
		ally.receive_squad_alert(attacker, threat_position, self)


func _is_same_squad(other: FPSCombatEnemy) -> bool:
	if other == null or other._health == null or _health == null:
		return false
	return other._health.team == _health.team


func _on_died(event: Dictionary) -> void:
	velocity = Vector3.ZERO
	_fire_pose_remaining = 0.0
	_reload_remaining = 0.0
	_evade_remaining = 0.0
	_release_cover()
	_release_engagement_slot()
	target = null
	_target_health = null
	if _collision_shape != null:
		_collision_shape.set_deferred("disabled", true)
	if _navigation_agent != null:
		_navigation_agent.avoidance_enabled = false
		_navigation_agent.set_velocity_forced(Vector3.ZERO)
	# Presentation follows authoritative shutdown: a death pose can never precede
	# attack, navigation and collision revocation.
	_set_ai_state(AIState.DEAD)
	_play_death_sound()
	enemy_died.emit(event)


func _exit_tree() -> void:
	_release_cover()
	_release_engagement_slot()


func _play_death_sound() -> void:
	if _death_audio == null:
		return
	var stream := death_sound
	if stream == null and synthesize_default_death_sound:
		stream = _get_generated_death_sound()
	if stream == null:
		return
	_death_audio.stream = stream
	_death_audio.volume_db = death_sound_volume_db
	_death_audio.pitch_scale = death_sound_pitch_scale
	_death_audio.play()
	death_sound_event_count += 1


func _get_generated_death_sound() -> AudioStreamWAV:
	if _generated_death_sound != null:
		return _generated_death_sound
	const MIX_RATE := 22050
	const DURATION_SECONDS := 0.36
	var sample_count := int(MIX_RATE * DURATION_SECONDS)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	var write_index := 0
	for sample_index in sample_count:
		var t := float(sample_index) / float(MIX_RATE)
		var decay := pow(1.0 - (float(sample_index) / float(sample_count)), 2.1)
		var low_hit := sin(TAU * 94.0 * t) * 0.58
		var chest_tone := sin(TAU * 142.0 * t) * 0.24
		var rasp_seed := float(((sample_index * 1103515245 + 12345) >> 16) & 0x7fff) / 32767.0
		var rasp := (rasp_seed * 2.0 - 1.0) * 0.15
		var value := clampf((low_hit + chest_tone + rasp) * decay, -1.0, 1.0)
		var pcm := int(value * 32767.0)
		if pcm < 0:
			pcm += 65536
		bytes[write_index] = pcm & 0xff
		bytes[write_index + 1] = (pcm >> 8) & 0xff
		write_index += 2
	_generated_death_sound = AudioStreamWAV.new()
	_generated_death_sound.format = AudioStreamWAV.FORMAT_16_BITS
	_generated_death_sound.mix_rate = MIX_RATE
	_generated_death_sound.stereo = false
	_generated_death_sound.data = bytes
	return _generated_death_sound


func _set_calibration_visuals_visible(is_visible: bool) -> void:
	for node_name in [&"CalibrationVisual", &"Visor"]:
		var visual := get_node_or_null(NodePath(String(node_name))) as VisualInstance3D
		if visual != null:
			visual.visible = is_visible
