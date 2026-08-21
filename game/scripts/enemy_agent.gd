class_name FusepointEnemyAgent
extends FPSCombatEnemy

signal authoritative_enemy_event(event: Dictionary)

const PRESENTATION_SCENE := preload("res://systems/actors/humanoid/enemy_humanoid_actor.tscn")

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


func _ready() -> void:
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


func _physics_process(delta: float) -> void:
	if not mission_active:
		return
	super._physics_process(delta)
	if _cleanup_remaining > 0.0:
		_cleanup_remaining = maxf(0.0, _cleanup_remaining - delta)
		if _cleanup_remaining <= 0.0 and _presentation_actor != null:
			_presentation_actor.visible = false
			cleanup_hidden = true


func configure_roster_entry(entry: Dictionary, target_node: Node3D) -> void:
	stable_id = StringName(entry["id"])
	region_id = StringName(entry["region"])
	tactical_role = StringName(entry["role"])
	route_slot = StringName(entry["slot"])
	route_pressure = entry["route_pressure"] == true
	roster_index = int(entry["index"])
	tactical_random_seed = 17041 + roster_index * 131
	difficulty = int(entry.get("difficulty", Difficulty.MEDIUM))
	target_group = &"player"
	_mission_target = target_node
	# Preserve a readable squad contact window instead of allowing every actor
	# activated in the same region to resolve its first shot on the same tick.
	# The stable roster index makes the telegraph deterministic across restarts.
	reaction_delay += float(roster_index % 5) * 0.35
	attack_interval *= 1.25
	attack_damage *= 0.375
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
	if active:
		activation_sequence = sequence
		_ensure_presentation()
		acquire_candidate_if_visible(_mission_target)
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
	set_physics_process(mission_active)
	if _collision_shape != null:
		_collision_shape.set_deferred("disabled", not mission_active or (_health != null and _health.is_dead))
	if _navigation_agent != null:
		_navigation_agent.avoidance_enabled = mission_active and (_health == null or not _health.is_dead)
	if _presentation_actor != null:
		_presentation_actor.visible = mission_active and not cleanup_hidden
	if not mission_active:
		velocity = Vector3.ZERO


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
	var combat := snapshot()
	return {
		"id": stable_id,
		"region": region_id,
		"role": tactical_role,
		"route_slot": route_slot,
		"route_pressure": route_pressure,
		"roster_index": roster_index,
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
		"avoidance_enabled": _navigation_agent != null and _navigation_agent.avoidance_enabled,
		"ammo": combat.get("rounds_remaining", 0),
		"magazine_size": combat.get("magazine_size", 0),
		"shot_event_id": String((combat.get("last_attack", {}) as Dictionary).get("shot_id", "")),
		"shot_feedback": _shot_feedback.snapshot(),
		"nearest_neighbor_distance": combat.get("nearest_enemy_distance", -1.0),
		"health": combat.get("health", {}),
		"activation_sequence": activation_sequence,
		"cleanup_hidden": cleanup_hidden,
		"presentation_bound": _presentation_actor != null,
		"presentation_state": _presentation_actor.state_name() if _presentation_actor != null else "inactive",
		"binding_accepted": _presentation_actor.binding_report.get("accepted", false) == true if _presentation_actor != null else false,
		"restore_epoch": _restore_epoch,
		"restored_epoch": _restored_epoch,
		"restore_in_progress": _restore_in_progress,
		"restore_quiescent": _restore_quiescent,
		"restore_readiness": _restore_readiness,
		"last_event": _last_enemy_event,
	}


func begin_checkpoint_restore(epoch: int) -> void:
	_restore_epoch = epoch
	_restore_in_progress = true
	_restore_quiescent = true
	_restore_readiness = &"suspended"
	_shot_feedback.reset_feedback()
	set_physics_process(false)
	velocity = Vector3.ZERO
	reset_volatile_combat_state_for_restore()
	if _collision_shape != null:
		_collision_shape.set_deferred("disabled", true)
	if _navigation_agent != null:
		_navigation_agent.avoidance_enabled = false


func apply_checkpoint_snapshot(saved: Dictionary, epoch: int) -> bool:
	if not _restore_in_progress or epoch != _restore_epoch:
		return false
	if StringName(saved.get("id", &"")) != stable_id:
		push_error("Restore identity mismatch for %s" % stable_id)
		return false
	if StringName(saved.get("region", region_id)) != region_id or StringName(saved.get("role", tactical_role)) != tactical_role or StringName(saved.get("route_slot", route_slot)) != route_slot:
		push_error("Restore roster binding mismatch for %s" % stable_id)
		return false
	global_transform = saved.get("transform", global_transform)
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


func _on_target_acquired_after_restore(_target: Node3D) -> void:
	if _restored_epoch > 0 and not _restore_in_progress:
		_restore_readiness = &"fresh_aim_window"


func _on_reload_started(combat: Dictionary) -> void:
	_commit_enemy_event(&"reload_started", {"ammo": combat.get("rounds_remaining", 0)})


func _on_reload_finished(combat: Dictionary) -> void:
	_commit_enemy_event(&"reload_finished", {"ammo": combat.get("rounds_remaining", 0)})


func _on_enemy_died(event: Dictionary) -> void:
	_cleanup_remaining = 4.0
	_commit_enemy_event(&"died", event)


func _on_ai_state_changed(previous: StringName, current: StringName, _combat: Dictionary) -> void:
	_commit_enemy_event(&"action_changed", {"previous": previous, "current": current})


func _commit_enemy_event(kind: StringName, payload: Dictionary) -> void:
	_event_sequence += 1
	_last_enemy_event = {
		"event_id": "enemy:%s:%06d" % [stable_id, _event_sequence],
		"kind": kind,
		"actor_id": stable_id,
		"region": region_id,
		"role": tactical_role,
		"payload": payload.duplicate(true),
	}
	authoritative_enemy_event.emit(_last_enemy_event.duplicate(true))


func _mcp_state() -> Dictionary:
	return authoritative_snapshot()
