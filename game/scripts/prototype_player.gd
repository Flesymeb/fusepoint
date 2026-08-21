extends CharacterBody3D

signal spawn_reset
signal authoritative_damage_received(event: Dictionary)
signal checkpoint_restored(event: Dictionary)
signal player_died(event: Dictionary)

@export_group("Ground locomotion")
@export var walk_speed := 4.5
@export var sprint_speed := 7.2
@export var crouch_speed := 2.4
@export var ground_acceleration := 24.0
@export var ground_deceleration := 28.0
@export var air_acceleration := 8.0
@export var jump_velocity := 5.2

@export_group("Stance")
@export var standing_height := 1.8
@export var crouching_height := 1.2
@export var standing_eye_height := 0.62
@export var crouching_eye_height := 0.22

@export_group("Camera")
@export var mouse_sensitivity := 0.0022
@export_range(30.0, 360.0, 1.0) var gamepad_look_speed_degrees := 150.0
@export_range(0.0, 0.95, 0.01) var gamepad_look_deadzone := 0.18
@export_range(30.0, 89.0, 1.0) var pitch_limit_degrees := 82.0
@export var stance_camera_speed := 3.2

@export_group("Mission survivability")
@export var max_health := 100.0

@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _spawn_transform: Transform3D
var _spawn_head_rotation: Vector3
var _pitch := 0.0
var _mouse_captured := false
var _stance := "standing"
var _locomotion_mode := "idle"
var _jump_phase := "grounded"
var _current_target_speed := 0.0
var _landing_time_left := 0.0
var _stand_clearance := true
var _jump_started := false
var _standing_clearance_shape := CapsuleShape3D.new()
var health := 100.0
var _damage_serial := 0
var _damage_commits: Dictionary = {}
var _last_damage_event: Dictionary = {}
var gameplay_input_enabled := true
var terminal_locked := false
var terminal_event_id := ""
var combat_death_locked := false
var _deployment_collision_layer := 1
var _deployment_collision_mask := 1
var restore_epoch := 0
var reduced_camera_motion := false
var screen_shake_enabled := true
var _look_input_serial := 0
var _last_look_receipt: Dictionary = {}
var _look_history: Array[Dictionary] = []
var _deployment_reset_count := 0
var _last_deployment_reset_receipt: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_spawn_transform = global_transform
	_spawn_head_rotation = head.rotation
	health = max_health
	_deployment_collision_layer = collision_layer
	_deployment_collision_mask = collision_mask
	_standing_clearance_shape.radius = 0.4
	_standing_clearance_shape.height = standing_height
	floor_snap_length = 0.25
	floor_stop_on_slope = true
	_capture_mouse()


func _input(event: InputEvent) -> void:
	if not gameplay_input_enabled:
		return
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_LEFT and not _mouse_captured:
			_capture_mouse()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion and _mouse_captured:
		var mouse_motion := event as InputEventMouseMotion
		_apply_look_delta(
			-mouse_motion.relative.x * mouse_sensitivity,
			-mouse_motion.relative.y * mouse_sensitivity,
			&"mouse_relative",
			mouse_motion.relative,
			0.0,
		)
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not gameplay_input_enabled:
		velocity = Vector3.ZERO
		return
	_apply_gamepad_look(delta)
	if Input.is_action_just_pressed("restart"):
		_reset_to_spawn(&"restart_input")
		return

	var was_on_floor := is_on_floor()
	_update_stance()
	_update_camera_height(delta)

	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var desired_direction := transform.basis * Vector3(input_vector.x, 0.0, input_vector.y)
	desired_direction.y = 0.0
	desired_direction = desired_direction.normalized()

	var grounded := is_on_floor()
	var sprinting := grounded and _stance == "standing" and Input.is_action_pressed("sprint") and input_vector.y < -0.1
	_current_target_speed = 0.0 if desired_direction.is_zero_approx() else _get_target_speed(sprinting)
	var acceleration := ground_acceleration if grounded else air_acceleration
	if desired_direction.is_zero_approx():
		acceleration = ground_deceleration if grounded else air_acceleration

	velocity.x = move_toward(velocity.x, desired_direction.x * _current_target_speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, desired_direction.z * _current_target_speed, acceleration * delta)

	if grounded:
		if velocity.y < 0.0:
			velocity.y = 0.0
		if Input.is_action_just_pressed("jump") and _stance == "standing":
			velocity.y = jump_velocity
			_jump_started = true
			_jump_phase = "ascending"
	else:
		velocity.y -= _gravity * delta

	move_and_slide()
	_update_authoritative_state(was_on_floor, input_vector, sprinting, delta)


func _apply_gamepad_look(delta: float) -> void:
	var stick := Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	if stick.length() <= gamepad_look_deadzone:
		return
	var normalized_strength := (stick.length() - gamepad_look_deadzone) / maxf(1.0 - gamepad_look_deadzone, 0.001)
	var shaped := stick.normalized() * clampf(normalized_strength, 0.0, 1.0)
	var radians_per_second := deg_to_rad(gamepad_look_speed_degrees)
	_apply_look_delta(
		-shaped.x * radians_per_second * delta,
		-shaped.y * radians_per_second * delta,
		&"gamepad_right_stick",
		stick,
		delta,
	)


func _apply_look_delta(yaw_delta: float, pitch_delta: float, source: StringName, raw_input: Vector2, delta_seconds: float) -> void:
	if not gameplay_input_enabled or not _mouse_captured:
		return
	var yaw_before := rotation.y
	var pitch_before := _pitch
	rotate_y(yaw_delta)
	_pitch = clampf(
		_pitch + pitch_delta,
		-deg_to_rad(pitch_limit_degrees),
		deg_to_rad(pitch_limit_degrees),
	)
	head.rotation.x = _pitch
	_look_input_serial += 1
	_last_look_receipt = {
		"edge_id": "look-input-%06d" % _look_input_serial,
		"source": source,
		"raw_input": raw_input,
		"delta_seconds": delta_seconds,
		"yaw_delta_degrees": rad_to_deg(angle_difference(yaw_before, rotation.y)),
		"pitch_delta_degrees": rad_to_deg(_pitch - pitch_before),
		"yaw_after_degrees": rotation_degrees.y,
		"pitch_after_degrees": head.rotation_degrees.x,
		"gameplay_enabled": gameplay_input_enabled,
		"mouse_captured": _mouse_captured,
	}
	_look_history.append(_last_look_receipt.duplicate(true))
	while _look_history.size() > 24:
		_look_history.pop_front()


func _get_target_speed(sprinting: bool) -> float:
	if _stance == "crouched":
		return crouch_speed
	if sprinting:
		return sprint_speed
	return walk_speed


func _update_stance() -> void:
	if Input.is_action_pressed("crouch"):
		if _stance != "crouched":
			_set_stance(true)
		_stand_clearance = _can_stand()
		return

	_stand_clearance = _can_stand()
	if _stance == "crouched" and _stand_clearance:
		_set_stance(false)


func _set_stance(crouched: bool) -> void:
	var capsule := collision_shape.shape as CapsuleShape3D
	if crouched:
		_stance = "crouched"
		capsule.height = crouching_height
		collision_shape.position.y = -(standing_height - crouching_height) * 0.5
	else:
		_stance = "standing"
		capsule.height = standing_height
		collision_shape.position.y = 0.0


func _update_camera_height(delta: float) -> void:
	var target_height := crouching_eye_height if _stance == "crouched" else standing_eye_height
	head.position.y = move_toward(head.position.y, target_height, stance_camera_speed * delta)


func _camera_height_above_feet() -> float:
	var capsule := collision_shape.shape as CapsuleShape3D
	return head.position.y - collision_shape.position.y + capsule.height * 0.5


func _can_stand() -> bool:
	if _stance == "standing":
		return true
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _standing_clearance_shape
	query.transform = Transform3D(global_transform.basis, global_position + Vector3.UP * 0.02)
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _update_authoritative_state(was_on_floor: bool, input_vector: Vector2, sprinting: bool, delta: float) -> void:
	var grounded := is_on_floor()
	if not was_on_floor and grounded:
		_landing_time_left = 0.16
		_jump_phase = "landed"
		_jump_started = false
	elif not grounded:
		_landing_time_left = 0.0
		_jump_phase = "ascending" if velocity.y > 0.0 else "descending"
	elif _landing_time_left > 0.0:
		_landing_time_left = maxf(0.0, _landing_time_left - delta)
		_jump_phase = "landed" if _landing_time_left > 0.0 else "grounded"
	else:
		_jump_phase = "grounded"

	if not grounded:
		_locomotion_mode = "jump" if _jump_started and velocity.y > 0.0 else "airborne"
	elif _landing_time_left > 0.0:
		_locomotion_mode = "landing"
	elif _stance == "crouched":
		_locomotion_mode = "crouch" if not input_vector.is_zero_approx() else "crouch_idle"
	elif input_vector.is_zero_approx():
		_locomotion_mode = "idle"
	elif sprinting:
		_locomotion_mode = "sprint"
	elif absf(input_vector.x) > absf(input_vector.y):
		_locomotion_mode = "strafe"
	else:
		_locomotion_mode = "walk"


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mouse_captured = false


func _reset_to_spawn(source: StringName = &"mission_setup") -> void:
	exit_terminal_lock()
	global_transform = _spawn_transform
	head.rotation = _spawn_head_rotation
	_pitch = _spawn_head_rotation.x
	velocity = Vector3.ZERO
	_landing_time_left = 0.0
	_jump_started = false
	_jump_phase = "grounded"
	_locomotion_mode = "idle"
	_current_target_speed = 0.0
	_stand_clearance = true
	health = max_health
	_damage_commits.clear()
	_last_damage_event.clear()
	_set_stance(false)
	head.position.y = standing_eye_height
	_capture_mouse()
	_deployment_reset_count += 1
	_last_deployment_reset_receipt = {
		"event_id": "deployment-reset-%06d" % _deployment_reset_count,
		"source": source,
		"destination": &"deployment_spawn",
		"position": global_position,
		"health": health,
		"checkpoint_restore_epoch": restore_epoch,
		"mission_checkpoint_transaction_requested": false,
		"transient_state_reset": true,
	}
	spawn_reset.emit()


func reset_to_deployment_without_mission_reset() -> void:
	_restore_movement_state(_spawn_transform, max_health)
	checkpoint_restored.emit({"event_id": "checkpoint-restore-deployment", "health_after": health})


func restore_checkpoint_state(checkpoint_transform: Transform3D, checkpoint_health: float, epoch := 0) -> void:
	restore_epoch = maxi(restore_epoch, epoch)
	reset_transient_state_for_restore()
	_restore_movement_state(checkpoint_transform, checkpoint_health)
	checkpoint_restored.emit({"event_id": "checkpoint-restore-%06d" % restore_epoch, "health_after": health, "restore_epoch": restore_epoch})


func reset_transient_state_for_restore() -> void:
	_damage_commits.clear()
	_last_damage_event.clear()
	terminal_locked = false
	terminal_event_id = ""
	velocity = Vector3.ZERO


func apply_accessibility_settings(values: Dictionary) -> void:
	reduced_camera_motion = values.get("reduced_camera_motion", false) == true
	screen_shake_enabled = values.get("screen_shake", true) == true
	camera.fov = clampf(float(values.get("fov", camera.fov)), 65.0, 95.0)


func _restore_movement_state(target_transform: Transform3D, target_health: float) -> void:
	exit_terminal_lock()
	global_transform = target_transform
	head.rotation = _spawn_head_rotation
	_pitch = _spawn_head_rotation.x
	velocity = Vector3.ZERO
	_landing_time_left = 0.0
	_jump_started = false
	_jump_phase = "grounded"
	_locomotion_mode = "idle"
	_current_target_speed = 0.0
	_stand_clearance = true
	_set_stance(false)
	head.position.y = standing_eye_height
	health = clampf(target_health, 1.0, max_health)
	_capture_mouse()


func apply_authoritative_damage(amount: float, damage_event_id := "", metadata: Dictionary = {}) -> bool:
	if amount <= 0.0 or health <= 0.0:
		return false
	_damage_serial += 1
	var event_id := damage_event_id if not damage_event_id.is_empty() else String(metadata.get("event_id", metadata.get("shot_id", "")))
	if event_id.is_empty():
		event_id = "player-damage-%06d" % _damage_serial
	if _damage_commits.has(event_id):
		return false
	_damage_commits[event_id] = true
	var health_before := health
	health = maxf(0.0, health - amount)
	var source_position: Variant = metadata.get("source_position", metadata.get("origin", global_position))
	if not source_position is Vector3:
		source_position = global_position
	var severity_ratio := clampf(amount / maxf(max_health, 1.0), 0.0, 1.0)
	var severity := &"critical" if health <= max_health * 0.25 else &"heavy" if severity_ratio >= 0.2 else &"light"
	_last_damage_event = {
		"event_id": event_id,
		"shot_id": String(metadata.get("shot_id", event_id)),
		"source_path": String(metadata.get("source_path", "")),
		"source_position": source_position,
		"damage_class": StringName(metadata.get("damage_class", &"ballistic")),
		"amount": amount,
		"severity": severity,
		"severity_ratio": severity_ratio,
		"health_before": health_before,
		"health_after": health,
		"max_health": max_health,
		"killed": health <= 0.0,
	}
	authoritative_damage_received.emit(_last_damage_event.duplicate(true))
	if health <= 0.0:
		var death_event := _last_damage_event.duplicate(true)
		death_event["position"] = global_position
		player_died.emit(death_event)
	return true


func apply_damage(amount: float, event: Dictionary = {}) -> Dictionary:
	var report := event.duplicate(true)
	var damage_event_id := String(report.get("event_id", report.get("shot_id", "")))
	var applied := apply_authoritative_damage(amount, damage_event_id, report)
	if applied:
		report.merge(_last_damage_event, true)
	report["amount"] = amount
	report["health_after"] = health
	report["max_health"] = max_health
	report["applied"] = applied
	report["hit"] = applied
	report["killed"] = health <= 0.0
	report["reason"] = "applied" if applied else "duplicate_or_dead"
	return report


func bind_deployment_to_walkable(walkable_position: Vector3, look_target := Vector3.INF) -> void:
	global_position = walkable_position
	if look_target != Vector3.INF:
		var flat_target := Vector3(look_target.x, global_position.y, look_target.z)
		if global_position.distance_to(flat_target) > 0.1:
			look_at(flat_target, Vector3.UP)
	_spawn_transform = global_transform
	_spawn_head_rotation = head.rotation
	velocity = Vector3.ZERO


func set_gameplay_input_enabled(enabled: bool) -> void:
	gameplay_input_enabled = enabled and not terminal_locked and not combat_death_locked
	velocity = Vector3.ZERO
	if gameplay_input_enabled:
		_capture_mouse()
	else:
		_release_mouse()


func prepare_new_mission() -> void:
	_reset_to_spawn(&"new_mission")


func enter_terminal_lock(event_id: String) -> bool:
	if terminal_locked:
		return terminal_event_id == event_id
	terminal_locked = true
	terminal_event_id = event_id
	gameplay_input_enabled = false
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	collision_shape.set_deferred(&"disabled", true)
	_release_mouse()
	return true


func enter_combat_death_lock() -> void:
	combat_death_locked = true
	gameplay_input_enabled = false
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	if collision_shape != null:
		collision_shape.set_deferred(&"disabled", true)
	_release_mouse()


func exit_terminal_lock() -> void:
	terminal_locked = false
	terminal_event_id = ""
	combat_death_locked = false
	collision_layer = _deployment_collision_layer
	collision_mask = _deployment_collision_mask
	if collision_shape != null:
		collision_shape.set_deferred(&"disabled", false)


func _mcp_state() -> Dictionary:
	return {
		"position": global_position,
		"velocity": velocity,
		"yaw_degrees": rotation_degrees.y,
		"pitch_degrees": head.rotation_degrees.x,
		"mouse_captured": _mouse_captured,
		"on_floor": is_on_floor(),
		"camera_current": camera.current,
		"camera_forward": -camera.global_transform.basis.z,
		"camera_height": _camera_height_above_feet(),
		"camera_fov": camera.fov,
		"collision_height": (collision_shape.shape as CapsuleShape3D).height,
		"spawn_position": _spawn_transform.origin,
		"pitch_limit_degrees": pitch_limit_degrees,
		"locomotion_mode": _locomotion_mode,
		"stance": _stance,
		"target_speed": _current_target_speed,
		"horizontal_speed": Vector2(velocity.x, velocity.z).length(),
		"jump_phase": _jump_phase,
		"jump_available": is_on_floor() and _stance == "standing",
		"landing_active": _landing_time_left > 0.0,
		"stand_clearance": _stand_clearance,
		"health": health,
		"max_health": max_health,
		"damage_commit_count": _damage_commits.size(),
		"last_damage_event": _last_damage_event,
		"gameplay_input_enabled": gameplay_input_enabled,
		"terminal_locked": terminal_locked,
		"terminal_event_id": terminal_event_id,
		"combat_death_locked": combat_death_locked,
		"restore_epoch": restore_epoch,
		"reduced_camera_motion": reduced_camera_motion,
		"screen_shake_enabled": screen_shake_enabled,
		"look_input_authority": &"player_raw_input_and_physics_stick",
		"look_input_count": _look_input_serial,
		"last_look_receipt": _last_look_receipt,
		"deployment_reset_count": _deployment_reset_count,
		"last_deployment_reset_receipt": _last_deployment_reset_receipt,
	}
