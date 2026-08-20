class_name FPSHitscanWeapon
extends Node3D

## Camera-aimed, muzzle-occlusion-aware hitscan resolver. Every accepted trigger
## produces one immutable shot report and at most one health mutation.

signal shot_requested(event: Dictionary)
signal shot_resolved(event: Dictionary)
signal ammo_changed(magazine: int, reserve: int, weapon_id: StringName)
signal reload_started(weapon_id: StringName, duration: float)
signal reload_finished(weapon_id: StringName, magazine: int, reserve: int)

@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("Node3D") var muzzle_path: NodePath
@export_node_path("Node") var visual_driver_path: NodePath
@export_node_path("CollisionObject3D") var owner_body_path: NodePath
@export_flags_3d_physics var collision_mask := 0xFFFFFFFF
@export var source_team: StringName = &"player"
@export var require_muzzle_clearance := true

var weapon_id: StringName = &"rifle"
var damage := 30.0
var range_meters := 160.0
var rounds_per_minute := 600.0
var magazine_size := 30
var magazine := 30
var reserve := 120
var reload_seconds := 1.8
var hip_spread_degrees := 0.7
var aim_spread_degrees := 0.12
var aiming := false
var reloading := false
var last_shot_report: Dictionary = {}

var _camera: Camera3D
var _muzzle: Node3D
var _visual_driver: Node
var _owner_body: CollisionObject3D
var _next_fire_msec := 0
var _shot_sequence := 0
var _reload_timer: SceneTreeTimer


func _ready() -> void:
	_resolve_nodes()


func configure(spec: FPSWeaponSpec, restored_state: Dictionary = {}) -> void:
	if spec == null:
		return
	weapon_id = spec.weapon_id
	damage = spec.damage
	range_meters = spec.range_meters
	rounds_per_minute = spec.rounds_per_minute
	magazine_size = spec.magazine_size
	reload_seconds = spec.reload_seconds
	hip_spread_degrees = spec.hip_spread_degrees
	aim_spread_degrees = spec.aim_spread_degrees
	magazine = clampi(int(restored_state.get("magazine", magazine_size)), 0, magazine_size)
	reserve = maxi(0, int(restored_state.get("reserve", spec.starting_reserve)))
	reloading = false
	_next_fire_msec = 0
	ammo_changed.emit(magazine, reserve, weapon_id)


func set_aiming(enabled: bool) -> void:
	aiming = enabled


func can_fire() -> bool:
	return not reloading and magazine > 0 and Time.get_ticks_msec() >= _next_fire_msec


func try_fire(explicit_direction := Vector3.ZERO, bypass_cooldown := false) -> Dictionary:
	if _camera == null or _muzzle == null:
		_resolve_nodes()
	if _camera == null or _muzzle == null:
		return _rejected_shot("unbound_camera_or_muzzle")
	if reloading:
		return _rejected_shot("reloading")
	if magazine <= 0:
		return _rejected_shot("empty_magazine")
	var now := Time.get_ticks_msec()
	if not bypass_cooldown and now < _next_fire_msec:
		return _rejected_shot("cooldown")

	magazine -= 1
	_shot_sequence += 1
	var shot_id := "%s:%d:%d" % [weapon_id, now, _shot_sequence]
	var interval_msec := int(round(60000.0 / maxf(rounds_per_minute, 1.0)))
	_next_fire_msec = now + interval_msec
	var direction := explicit_direction.normalized() if explicit_direction.length_squared() > 0.0001 else -_camera.global_basis.z.normalized()
	direction = _spread_direction(direction, aim_spread_degrees if aiming else hip_spread_degrees)
	var base_event := {
		"shot_id": shot_id,
		"weapon_id": String(weapon_id),
		"source_team": source_team,
		"source_path": String(_owner_body.get_path()) if _owner_body != null and _owner_body.is_inside_tree() else "",
		"damage": damage,
		"origin": _camera.global_position,
		"muzzle_origin": _muzzle.global_position,
		"direction": direction,
		"range_meters": range_meters,
		"magazine_after": magazine,
		"reserve_after": reserve,
	}
	shot_requested.emit(base_event)
	_drive_visual(&"fire")
	last_shot_report = _resolve_shot(base_event)
	shot_resolved.emit(last_shot_report)
	ammo_changed.emit(magazine, reserve, weapon_id)
	return last_shot_report


func start_reload() -> bool:
	if reloading or magazine >= magazine_size or reserve <= 0:
		return false
	reloading = true
	_drive_visual(&"reload")
	reload_started.emit(weapon_id, reload_seconds)
	_reload_timer = get_tree().create_timer(reload_seconds)
	_reload_timer.timeout.connect(_finish_reload, CONNECT_ONE_SHOT)
	return true


func state_snapshot() -> Dictionary:
	return {
		"weapon_id": String(weapon_id),
		"magazine": magazine,
		"reserve": reserve,
		"magazine_size": magazine_size,
		"reloading": reloading,
		"aiming": aiming,
		"last_shot": last_shot_report.duplicate(true),
	}


func _resolve_nodes() -> void:
	_camera = get_node_or_null(camera_path) as Camera3D if not camera_path.is_empty() else null
	_muzzle = get_node_or_null(muzzle_path) as Node3D if not muzzle_path.is_empty() else null
	_visual_driver = get_node_or_null(visual_driver_path) if not visual_driver_path.is_empty() else null
	_owner_body = get_node_or_null(owner_body_path) as CollisionObject3D if not owner_body_path.is_empty() else null


func _resolve_shot(base_event: Dictionary) -> Dictionary:
	var camera_origin: Vector3 = base_event["origin"]
	var direction: Vector3 = base_event["direction"]
	var far_target := camera_origin + direction * range_meters
	var camera_hit := _ray(camera_origin, far_target)
	var aim_point: Vector3 = camera_hit.get("position", far_target)
	var muzzle_origin: Vector3 = base_event["muzzle_origin"]
	var muzzle_direction := muzzle_origin.direction_to(aim_point)
	var muzzle_target := aim_point + muzzle_direction * 0.08
	var muzzle_hit := _ray(muzzle_origin, muzzle_target) if require_muzzle_clearance else {}
	var final_hit: Dictionary = muzzle_hit if not muzzle_hit.is_empty() else camera_hit
	var report := base_event.duplicate(true)
	report["accepted"] = true
	report["hit"] = not final_hit.is_empty()
	report["blocked_at_muzzle"] = (
		require_muzzle_clearance
		and not muzzle_hit.is_empty()
		and not camera_hit.is_empty()
		and muzzle_hit.get("collider") != camera_hit.get("collider")
	)
	if final_hit.is_empty():
		report["outcome"] = "miss"
		report["hit_position"] = far_target
		report["damage_applied"] = false
		return report

	var collider := final_hit.get("collider") as Object
	var health := _find_damage_receiver(collider)
	report["outcome"] = "blocked" if report["blocked_at_muzzle"] else "hit"
	report["hit_position"] = final_hit.get("position", aim_point)
	report["hit_normal"] = final_hit.get("normal", Vector3.ZERO)
	report["collider_path"] = _node_path_string(collider)
	report["damage_applied"] = false
	if health != null:
		var damage_event := report.duplicate(true)
		damage_event["target_path"] = health.get_path()
		var damage_report: Dictionary = health.call("apply_damage", damage, damage_event)
		report["damage_applied"] = bool(damage_report.get("applied", false))
		report["damage_report"] = damage_report
	return report


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask, _excluded_rids())
	query.collide_with_areas = true
	query.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_ray(query)


func _excluded_rids() -> Array[RID]:
	var excluded: Array[RID] = []
	if _owner_body != null:
		excluded.append(_owner_body.get_rid())
	return excluded


func _find_damage_receiver(value: Object) -> Node:
	var node := value as Node
	var depth := 0
	while node != null and depth < 10:
		if node.has_method("apply_damage"):
			return node
		for child: Node in node.get_children():
			if child.has_method("apply_damage"):
				return child
		node = node.get_parent()
		depth += 1
	return null


func _spread_direction(direction: Vector3, spread_degrees: float) -> Vector3:
	if spread_degrees <= 0.0001:
		return direction
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	var right := direction.cross(up).normalized()
	up = right.cross(direction).normalized()
	var radius := tan(deg_to_rad(spread_degrees))
	return (direction + right * randf_range(-radius, radius) + up * randf_range(-radius, radius)).normalized()


func _finish_reload() -> void:
	if not reloading:
		return
	var loaded := mini(magazine_size - magazine, reserve)
	magazine += loaded
	reserve -= loaded
	reloading = false
	reload_finished.emit(weapon_id, magazine, reserve)
	ammo_changed.emit(magazine, reserve, weapon_id)


func _drive_visual(alias: StringName) -> void:
	if _visual_driver != null and _visual_driver.has_method("play_clip"):
		_visual_driver.call("play_clip", alias)


func _rejected_shot(reason: String) -> Dictionary:
	last_shot_report = {
		"accepted": false,
		"reason": reason,
		"weapon_id": String(weapon_id),
		"magazine_after": magazine,
		"reserve_after": reserve,
	}
	return last_shot_report


func _node_path_string(value: Object) -> String:
	var node := value as Node
	return String(node.get_path()) if node != null and node.is_inside_tree() else ""
