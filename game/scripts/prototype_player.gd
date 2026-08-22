extends CharacterBody3D

signal spawn_reset
signal authoritative_damage_received(event: Dictionary)
signal checkpoint_restored(event: Dictionary)
signal player_died(event: Dictionary)

@export_group("Ground locomotion")
@export var walk_speed := 4.5
@export var sprint_speed := 7.2
@export var crouch_speed := 2.4
@export var prone_speed := 1.15
@export var ground_acceleration := 24.0
@export var ground_deceleration := 28.0
@export var air_acceleration := 8.0
@export var jump_velocity := 5.2

@export_group("Stance")
@export var standing_height := 1.8
@export var crouching_height := 1.2
@export var prone_height := 0.65
@export var standing_radius := 0.4
@export var crouching_radius := 0.4
@export var prone_radius := 0.28
@export var standing_eye_height := 0.62
@export var crouching_eye_height := 0.22
@export var prone_eye_height := -0.43
@export var auto_step_enabled := true
@export var max_step_height := 0.45
@export var step_forward_distance := 0.2
@export var step_down_snap := 0.35

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
@onready var _foley_feedback: Node = $Head/Camera3D/FPSViewmodelSwitcher/FPSViewmodelFeedback

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
var _deployment_generation := 0
var _look_generation_sequence := 0
var _look_observation_boundary: Dictionary = {}
var _deployment_reset_count := 0
var _last_deployment_reset_receipt: Dictionary = {}
var _last_restore_receipt: Dictionary = {}
var _base_camera_fov := 76.0
var _blocked_seconds := 0.0
var _unstuck_cooldown := 0.0
var _last_stuck_diagnostic: Dictionary = {}
var _auto_step_count := 0
var _last_step_height := 0.0
var _foley_state := &"idle"
var _foley_locomotion := &"idle"
var _foley_sync_serial := 0
var _foley_last_receipt: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_spawn_transform = global_transform
	_spawn_head_rotation = head.rotation
	health = max_health
	_deployment_collision_layer = collision_layer
	_deployment_collision_mask = collision_mask
	_standing_clearance_shape.radius = standing_radius
	_standing_clearance_shape.height = standing_height
	_base_camera_fov = camera.fov
	floor_snap_length = step_down_snap
	floor_constant_speed = true
	floor_stop_on_slope = true
	safe_margin = 0.03
	max_slides = 8
	_configure_authoritative_foley_owner()
	_capture_mouse()
	_begin_look_observation_generation(&"initial_ready")


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
		_sync_grounded_foley(&"gameplay_disabled")
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

	var horizontal_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	var step_motion := horizontal_motion
	if not desired_direction.is_zero_approx():
		step_motion = desired_direction * maxf(horizontal_motion.length(), step_forward_distance)
	if not _try_step_up(step_motion):
		move_and_slide()
	_update_ground_recovery(delta, desired_direction)
	_update_authoritative_state(was_on_floor, input_vector, sprinting, delta)
	_sync_grounded_foley(&"physics_state")


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
	_look_generation_sequence += 1
	_last_look_receipt = {
		"event_id": "look-g%04d-%04d" % [_deployment_generation, _look_generation_sequence],
		"receipt_id": "look-input-%06d" % _look_input_serial,
		"edge_id": "look-input-%06d" % _look_input_serial,
		"deployment_generation": _deployment_generation,
		"generation_sequence": _look_generation_sequence,
		"source": source,
		"raw_input": raw_input,
		"delta_seconds": delta_seconds,
		"yaw_before_degrees": rad_to_deg(yaw_before),
		"pitch_before_degrees": rad_to_deg(pitch_before),
		"yaw_delta_degrees": rad_to_deg(angle_difference(yaw_before, rotation.y)),
		"pitch_delta_degrees": rad_to_deg(_pitch - pitch_before),
		"yaw_after_degrees": rotation_degrees.y,
		"pitch_after_degrees": head.rotation_degrees.x,
		"accepted": true,
		"gameplay_enabled": gameplay_input_enabled,
		"mouse_captured": _mouse_captured,
		"capture_eligible": gameplay_input_enabled and _mouse_captured,
	}
	_look_history.append(_last_look_receipt.duplicate(true))
	while _look_history.size() > 24:
		_look_history.pop_front()


func _begin_look_observation_generation(source: StringName) -> void:
	var previous_generation := _deployment_generation
	var boundary_pitch_degrees := head.rotation_degrees.x if head != null else rad_to_deg(_pitch)
	_deployment_generation += 1
	_look_generation_sequence = 0
	_look_history.clear()
	_last_look_receipt.clear()
	_look_observation_boundary = {
		"event_id": "look-boundary-%04d" % _deployment_generation,
		"source": source,
		"previous_generation": previous_generation,
		"deployment_generation": _deployment_generation,
		"yaw_degrees": rotation_degrees.y,
		"pitch_degrees": boundary_pitch_degrees,
		"gameplay_enabled": gameplay_input_enabled,
		"mouse_captured": _mouse_captured,
	}


func _get_target_speed(sprinting: bool) -> float:
	if _stance == "prone":
		return prone_speed
	if _stance == "crouched":
		return crouch_speed
	if sprinting:
		return sprint_speed
	return walk_speed


func _update_stance() -> void:
	if Input.is_action_pressed("prone"):
		if _stance != "prone":
			_set_posture(&"prone")
		_stand_clearance = _can_stand()
		return
	if Input.is_action_pressed("crouch"):
		if _stance != "crouched":
			_set_posture(&"crouched")
		_stand_clearance = _can_stand()
		return

	_stand_clearance = _can_stand()
	if _stance != "standing" and _stand_clearance:
		_set_posture(&"standing")


func _set_stance(crouched: bool) -> void:
	_set_posture(&"crouched" if crouched else &"standing")


func _set_posture(next_posture: StringName) -> void:
	var capsule := collision_shape.shape as CapsuleShape3D
	var target_height := standing_height
	var target_radius := standing_radius
	match next_posture:
		&"prone":
			target_height = prone_height
			target_radius = prone_radius
		&"crouched":
			target_height = crouching_height
			target_radius = crouching_radius
		_:
			next_posture = &"standing"
	if target_height > capsule.height and not _can_expand_to(target_height, target_radius):
		return
	capsule.height = maxf(target_height, target_radius * 2.0 + 0.02)
	capsule.radius = target_radius
	collision_shape.position.y = -(standing_height - target_height) * 0.5
	_stance = String(next_posture)


func _update_camera_height(delta: float) -> void:
	var target_height := prone_eye_height if _stance == "prone" else crouching_eye_height if _stance == "crouched" else standing_eye_height
	var target_fov := _base_camera_fov - (4.0 if _stance == "prone" else 2.0 if _stance == "crouched" else 0.0)
	head.position.y = move_toward(head.position.y, target_height, stance_camera_speed * delta)
	camera.fov = move_toward(camera.fov, target_fov, stance_camera_speed * 4.0 * delta)


func _camera_height_above_feet() -> float:
	var capsule := collision_shape.shape as CapsuleShape3D
	return head.position.y - collision_shape.position.y + capsule.height * 0.5


func _can_stand() -> bool:
	if _stance == "standing":
		return true
	return _can_expand_to(standing_height, standing_radius)


func _can_expand_to(target_height: float, target_radius: float) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	var target_shape := CapsuleShape3D.new()
	target_shape.height = maxf(target_height, target_radius * 2.0 + 0.02)
	target_shape.radius = target_radius
	query.shape = target_shape
	var center_offset := -(standing_height - target_height) * 0.5
	query.transform = Transform3D(global_transform.basis, global_position + Vector3.UP * (center_offset + 0.02))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _try_step_up(horizontal_motion: Vector3) -> bool:
	if not auto_step_enabled or _stance == "prone" or not is_on_floor() or velocity.y > 0.01:
		return false
	if horizontal_motion.length_squared() < 0.000001 or not test_move(global_transform, horizontal_motion):
		return false
	var up_motion := Vector3.UP * max_step_height
	if test_move(global_transform, up_motion):
		return false
	var raised_transform := global_transform
	raised_transform.origin += up_motion
	if test_move(raised_transform, horizontal_motion):
		return false
	var raised_forward := raised_transform
	raised_forward.origin += horizontal_motion
	var parameters := PhysicsTestMotionParameters3D.new()
	parameters.from = raised_forward
	parameters.motion = Vector3.DOWN * (max_step_height + safe_margin * 2.0)
	parameters.margin = safe_margin
	var result := PhysicsTestMotionResult3D.new()
	if not PhysicsServer3D.body_test_motion(get_rid(), parameters, result) or result.get_collision_count() == 0:
		return false
	if result.get_collision_normal().dot(Vector3.UP) < 0.5:
		return false
	var step_height := max_step_height + result.get_travel().y
	if step_height <= safe_margin or step_height > max_step_height + safe_margin:
		return false
	raised_forward.origin += result.get_travel()
	global_transform = raised_forward
	velocity.y = 0.0
	_auto_step_count += 1
	_last_step_height = step_height
	return true


func _update_ground_recovery(delta: float, desired_direction: Vector3) -> void:
	_unstuck_cooldown = maxf(0.0, _unstuck_cooldown - delta)
	var horizontal_speed := Vector2(get_real_velocity().x, get_real_velocity().z).length()
	if desired_direction.is_zero_approx() or not is_on_floor() or get_slide_collision_count() == 0 or horizontal_speed > 0.08:
		_blocked_seconds = 0.0
		return
	_blocked_seconds += delta
	_last_stuck_diagnostic = {
		"position": global_position,
		"requested_direction": desired_direction,
		"horizontal_speed": horizontal_speed,
		"blocked_seconds": _blocked_seconds,
		"slide_contacts": _slide_contact_snapshot(),
	}
	if _blocked_seconds < 0.65 or _unstuck_cooldown > 0.0:
		return
	var side := desired_direction.cross(Vector3.UP).normalized()
	for offset in [side * 0.10, -side * 0.10, -desired_direction * 0.10]:
		if not test_move(global_transform, offset):
			global_position += offset
			velocity.x = 0.0
			velocity.z = 0.0
			_last_stuck_diagnostic["recovery_offset"] = offset
			_last_stuck_diagnostic["recovered"] = true
			_blocked_seconds = 0.0
			_unstuck_cooldown = 1.25
			return
	_last_stuck_diagnostic["recovered"] = false


func _slide_contact_snapshot() -> Array[Dictionary]:
	var contacts: Array[Dictionary] = []
	for index in get_slide_collision_count():
		var collision := get_slide_collision(index)
		var collider: Variant = collision.get_collider()
		contacts.append({
			"collider_path": String(collider.get_path()) if collider is Node else String(collider),
			"normal": collision.get_normal(),
			"position": collision.get_position(),
		})
	return contacts


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


func _sync_grounded_foley(source: StringName) -> void:
	if _foley_feedback == null:
		return
	var grounded := is_on_floor() and gameplay_input_enabled and not terminal_locked and not combat_death_locked
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var requested := &"idle"
	if grounded and _landing_time_left <= 0.0 and horizontal_speed > 0.24:
		requested = &"run" if _locomotion_mode == "sprint" else &"crouch" if _stance == "crouched" else &"walk"
	var playback_state := &"run" if requested == &"run" else &"walk" if requested in [&"walk", &"crouch"] else &"idle"
	var walk := _foley_feedback.get_node_or_null("WalkAudio") as AudioStreamPlayer
	var run := _foley_feedback.get_node_or_null("RunAudio") as AudioStreamPlayer
	if walk != null:
		walk.pitch_scale = 0.82 if requested == &"crouch" else 0.96
	if run != null:
		run.pitch_scale = 1.04
	# Fail closed every airborne/idle physics frame. The retained component may
	# resync its clip state during the same render interval; authoritative player
	# contact still owns whether either retained playback node may remain active.
	if playback_state == &"idle":
		_foley_feedback.call(&"stop_movement")
		if walk != null and walk.playing:
			walk.stop()
		if run != null and run.playing:
			run.stop()
	elif playback_state == &"run":
		_foley_feedback.call(&"start_run")
	elif playback_state == &"walk":
		_foley_feedback.call(&"start_walk")
	if requested != _foley_locomotion or playback_state != _foley_state:
		_foley_locomotion = requested
		_foley_state = playback_state
		_foley_sync_serial += 1
		_foley_last_receipt = {
			"serial": _foley_sync_serial,
			"source": source,
			"grounded": grounded,
			"locomotion": requested,
			"playback_state": playback_state,
			"stance": _stance,
			"horizontal_speed": horizontal_speed,
			"jump_phase": _jump_phase,
			"walk_playing": walk.playing if walk != null else false,
			"run_playing": run.playing if run != null else false,
			"frame": Engine.get_physics_frames(),
		}


func _configure_authoritative_foley_owner() -> void:
	# PrototypePlayer is the sole product driver for retained locomotion audio.
	# WeaponController may use the same feedback component for weapon-only VFX
	# and audio, but never starts, stops, or configures WalkAudio/RunAudio.
	if _foley_feedback == null:
		return
	for player_name: StringName in [&"WalkAudio", &"RunAudio"]:
		var player := _foley_feedback.get_node_or_null(NodePath(player_name)) as AudioStreamPlayer
		if player != null:
			player.bus = &"Foley"
			player.stop()


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mouse_captured = false


func _reset_to_spawn(source: StringName = &"mission_setup") -> void:
	var validation := validate_recovery_destination(_spawn_transform, [])
	if validation.get("accepted", false) != true:
		_deployment_reset_count += 1
		_last_deployment_reset_receipt = {
			"event_id": "deployment-reset-%06d" % _deployment_reset_count,
			"source": source,
			"destination": &"deployment_spawn",
			"accepted": false,
			"failure_reason": validation.get("failure_reason", &"destination_rejected"),
			"validation": validation,
			"mission_checkpoint_transaction_requested": false,
		}
		return
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
	_foley_locomotion = &"idle"
	_foley_state = &"idle"
	if _foley_feedback != null:
		_foley_feedback.call(&"stop_movement")
	_stand_clearance = true
	health = max_health
	_damage_commits.clear()
	_last_damage_event.clear()
	_last_stuck_diagnostic.clear()
	_blocked_seconds = 0.0
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
		"accepted": true,
		"validation": validation,
	}
	_begin_look_observation_generation(source)
	_last_deployment_reset_receipt["deployment_generation"] = _deployment_generation
	spawn_reset.emit()


func reset_to_deployment_without_mission_reset() -> void:
	_restore_movement_state(_spawn_transform, max_health)
	checkpoint_restored.emit({"event_id": "checkpoint-restore-deployment", "health_after": health})


func restore_checkpoint_state(checkpoint_transform: Transform3D, checkpoint_health: float, epoch := 0, allow_same_epoch := false) -> Dictionary:
	if epoch < restore_epoch or (epoch == restore_epoch and not allow_same_epoch):
		_last_restore_receipt = {
			"accepted": false,
			"restore_epoch": epoch,
			"failure_reason": &"non_monotonic_epoch",
		}
		return _last_restore_receipt.duplicate(true)
	restore_epoch = maxi(restore_epoch, epoch)
	reset_transient_state_for_restore()
	_restore_movement_state(checkpoint_transform, checkpoint_health)
	_last_restore_receipt = {
		"accepted": true,
		"event_id": "player-restore-%06d" % restore_epoch,
		"restore_epoch": restore_epoch,
		"position": global_position,
		"health_after": health,
		"collision_restored": collision_layer == _deployment_collision_layer and collision_mask == _deployment_collision_mask,
		"transient_reset_complete": _damage_commits.is_empty() and _last_damage_event.is_empty(),
	}
	checkpoint_restored.emit(_last_restore_receipt.duplicate(true))
	return _last_restore_receipt.duplicate(true)


func reset_transient_state_for_restore() -> void:
	_damage_commits.clear()
	_last_damage_event.clear()
	terminal_locked = false
	terminal_event_id = ""
	velocity = Vector3.ZERO
	_last_stuck_diagnostic.clear()
	_blocked_seconds = 0.0
	_foley_locomotion = &"idle"
	_foley_state = &"idle"
	if _foley_feedback != null:
		_foley_feedback.call(&"stop_movement")


func apply_accessibility_settings(values: Dictionary) -> void:
	reduced_camera_motion = values.get("reduced_camera_motion", false) == true
	screen_shake_enabled = values.get("screen_shake", true) == true
	_base_camera_fov = clampf(float(values.get("fov", camera.fov)), 65.0, 95.0)
	camera.fov = _base_camera_fov


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
	_foley_locomotion = &"idle"
	_foley_state = &"idle"
	if _foley_feedback != null:
		_foley_feedback.call(&"stop_movement")
	_stand_clearance = true
	_set_stance(false)
	head.position.y = standing_eye_height
	health = clampf(target_health, 1.0, max_health)
	if gameplay_input_enabled:
		_capture_mouse()
	else:
		_release_mouse()


func validate_recovery_destination(target_transform: Transform3D, hostile_positions: Array) -> Dictionary:
	var destination := target_transform.origin
	if not destination.is_finite():
		return {"accepted": false, "failure_reason": &"destination_not_finite"}
	var space_state := get_world_3d().direct_space_state
	var excluded: Array[RID] = [get_rid()]
	for hostile: Node in get_tree().get_nodes_in_group(&"fps_enemy"):
		if hostile is CollisionObject3D:
			excluded.append((hostile as CollisionObject3D).get_rid())
	var clearance_shape := CapsuleShape3D.new()
	clearance_shape.radius = maxf(0.1, (collision_shape.shape as CapsuleShape3D).radius - 0.04)
	clearance_shape.height = maxf(clearance_shape.radius * 2.0, standing_height - 0.12)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = clearance_shape
	query.transform = Transform3D(target_transform.basis, destination + Vector3.UP * 0.08)
	query.collision_mask = collision_mask if collision_mask != 0 else _deployment_collision_mask
	query.exclude = excluded
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var blockers := space_state.intersect_shape(query, 8)
	var ground_query := PhysicsRayQueryParameters3D.create(
		destination + Vector3.UP * 0.4,
		destination + Vector3.DOWN * 1.7,
		query.collision_mask,
		excluded,
	)
	ground_query.collide_with_areas = false
	var ground_hit := space_state.intersect_ray(ground_query)
	var nearest_hostile := INF
	for value: Variant in hostile_positions:
		if value is Vector3:
			nearest_hostile = minf(nearest_hostile, destination.distance_to(value as Vector3))
	var hostile_clear := is_inf(nearest_hostile) or nearest_hostile >= 1.2
	var accepted := blockers.is_empty() and not ground_hit.is_empty() and hostile_clear
	return {
		"accepted": accepted,
		"failure_reason": &"" if accepted else &"static_occupancy_blocked" if not blockers.is_empty() else &"ground_missing" if ground_hit.is_empty() else &"hostile_separation_blocked",
		"destination": destination,
		"static_blocker_count": blockers.size(),
		"grounded": not ground_hit.is_empty(),
		"ground_position": ground_hit.get("position", Vector3.ZERO),
		"nearest_hostile_distance": -1.0 if is_inf(nearest_hostile) else nearest_hostile,
		"required_hostile_separation": 1.2,
	}


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
	_begin_look_observation_generation(&"native_anchor_bound")


func set_gameplay_input_enabled(enabled: bool) -> void:
	gameplay_input_enabled = enabled and not terminal_locked and not combat_death_locked
	velocity = Vector3.ZERO
	if gameplay_input_enabled:
		_capture_mouse()
	else:
		_sync_grounded_foley(&"gameplay_disabled")
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
	_sync_grounded_foley(&"terminal_lock")
	collision_layer = 0
	collision_mask = 0
	collision_shape.set_deferred(&"disabled", true)
	_release_mouse()
	return true


func enter_combat_death_lock() -> void:
	combat_death_locked = true
	gameplay_input_enabled = false
	velocity = Vector3.ZERO
	_sync_grounded_foley(&"combat_death_lock")
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
	var head_ready := head != null
	var camera_ready := camera != null
	var collision_ready := collision_shape != null and collision_shape.shape is CapsuleShape3D
	return {
		"position": global_position,
		"velocity": velocity,
		"yaw_degrees": rotation_degrees.y,
		"pitch_degrees": head.rotation_degrees.x if head_ready else rad_to_deg(_pitch),
		"mouse_captured": _mouse_captured,
		"on_floor": is_on_floor(),
		"camera_current": camera.current if camera_ready else false,
		"camera_forward": -camera.global_transform.basis.z if camera_ready else -global_transform.basis.z,
		"camera_height": _camera_height_above_feet() if camera_ready else 0.0,
		"camera_fov": camera.fov if camera_ready else _base_camera_fov,
		"collision_height": (collision_shape.shape as CapsuleShape3D).height if collision_ready else standing_height,
		"spawn_position": _spawn_transform.origin,
		"deployment_reset_count": _deployment_reset_count,
		"last_deployment_reset_receipt": _last_deployment_reset_receipt,
		"last_restore_receipt": _last_restore_receipt,
		"pitch_limit_degrees": pitch_limit_degrees,
		"locomotion_mode": _locomotion_mode,
		"stance": _stance,
		"target_speed": _current_target_speed,
		"horizontal_speed": Vector2(velocity.x, velocity.z).length(),
		"jump_phase": _jump_phase,
		"jump_available": is_on_floor() and _stance == "standing",
		"landing_active": _landing_time_left > 0.0,
		"stand_clearance": _stand_clearance,
		"posture_height": (collision_shape.shape as CapsuleShape3D).height if collision_ready else standing_height,
		"posture_radius": (collision_shape.shape as CapsuleShape3D).radius if collision_ready else standing_radius,
		"auto_step_enabled": auto_step_enabled,
		"max_step_height": max_step_height,
		"auto_step_count": _auto_step_count,
		"last_step_height": _last_step_height,
		"foley_state": _foley_state,
		"foley_locomotion": _foley_locomotion,
		"foley_sync_serial": _foley_sync_serial,
		"foley_last_receipt": _foley_last_receipt,
		"blocked_seconds": _blocked_seconds,
		"last_stuck_diagnostic": _last_stuck_diagnostic,
		"slide_contacts": _slide_contact_snapshot(),
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
		"deployment_generation": _deployment_generation,
		"look_generation_sequence": _look_generation_sequence,
		"look_observation_boundary": _look_observation_boundary,
		"look_receipt_history": _look_history.duplicate(true),
		"look_receipt_history_limit": 24,
		"last_look_receipt": _last_look_receipt,
	}
