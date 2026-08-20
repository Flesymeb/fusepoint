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
var _cleanup_remaining := 0.0
var _event_sequence := 0
var _last_enemy_event: Dictionary = {}


func _ready() -> void:
	super._ready()
	add_to_group(&"mcp_watch")
	add_to_group(&"fusepoint_enemy")
	attack_resolved.connect(_on_attack_resolved)
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


func configure_roster_entry(entry: Dictionary, _target_node: Node3D) -> void:
	stable_id = StringName(entry["id"])
	region_id = StringName(entry["region"])
	tactical_role = StringName(entry["role"])
	route_slot = StringName(entry["slot"])
	route_pressure = entry["route_pressure"] == true
	roster_index = int(entry["index"])
	tactical_random_seed = 17041 + roster_index * 131
	difficulty = int(entry.get("difficulty", Difficulty.MEDIUM))
	target_group = &"player"
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
		"navigation_velocity": combat.get("navigation_safe_velocity", Vector3.ZERO),
		"avoidance_enabled": _navigation_agent != null and _navigation_agent.avoidance_enabled,
		"ammo": combat.get("rounds_remaining", 0),
		"magazine_size": combat.get("magazine_size", 0),
		"shot_event_id": String((combat.get("last_attack", {}) as Dictionary).get("shot_id", "")),
		"nearest_neighbor_distance": combat.get("nearest_enemy_distance", -1.0),
		"health": combat.get("health", {}),
		"activation_sequence": activation_sequence,
		"cleanup_hidden": cleanup_hidden,
		"presentation_bound": _presentation_actor != null,
		"presentation_state": _presentation_actor.state_name() if _presentation_actor != null else "inactive",
		"binding_accepted": _presentation_actor.binding_report.get("accepted", false) == true if _presentation_actor != null else false,
		"last_event": _last_enemy_event,
	}


func restore_authoritative_snapshot(saved: Dictionary) -> void:
	global_transform = saved.get("transform", global_transform)
	velocity = Vector3.ZERO
	rounds_remaining = int(saved.get("ammo", magazine_size))
	activation_sequence = int(saved.get("activation_sequence", activation_sequence))
	cleanup_hidden = saved.get("cleanup_hidden", false) == true
	var health_state: Dictionary = saved.get("health", {})
	var restored_health := float(health_state.get("current", _health.max_health if _health != null else 100.0))
	if _health != null:
		_health.reset_health(restored_health)
	mission_active = saved.get("active", false) == true
	if mission_active:
		_ensure_presentation()
		if _health != null and _health.is_dead:
			ai_state = AIState.DEAD
			_presentation_actor.die()
		else:
			ai_state = AIState.IDLE
			_presentation_actor.reset_enemy()
	_apply_activation_state()


func _on_attack_resolved(report: Dictionary) -> void:
	var event := report.duplicate(true)
	event["actor_id"] = stable_id
	event["weapon_id"] = &"rift_carbine"
	event["region"] = region_id
	event["role"] = tactical_role
	event["ammo_after"] = rounds_remaining
	_commit_enemy_event(&"shot_resolved", event)


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
