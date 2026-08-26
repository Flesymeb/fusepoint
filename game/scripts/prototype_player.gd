extends CharacterBody3D

signal spawn_reset
signal authoritative_damage_received(event: Dictionary)
signal checkpoint_restored(event: Dictionary)
signal player_died(event: Dictionary)

const MOVEMENT_RECEIPT_HISTORY_LIMIT := 24
const MOVEMENT_SAMPLE_INTERVAL_SECONDS := 0.25
const DEPLOYMENT_EGRESS_DISTANCE := 1.25

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
var _damage_attempt_serial := 0
var _last_damage_attempt: Dictionary = {}
var _damage_attempt_history: Array[Dictionary] = []
var _terminal_damage_rejection_count := 0
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
var _mouse_capture_sync_serial := 0
var _last_mouse_capture_sync_receipt: Dictionary = {}
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
var _movement_receipt_serial := 0
var _movement_receipt_history: Array[Dictionary] = []
var _last_movement_receipt: Dictionary = {}
var _movement_hold_active := false
var _movement_release_pending := false
var _movement_hold_elapsed := 0.0
var _movement_sample_elapsed := 0.0
var _movement_hold_origin := Vector3.ZERO
var _movement_egress_latched := false
var _movement_gate_observed := true

var yaw_degrees: float:
	get:
		return rotation_degrees.y

var pitch_degrees: float:
	get:
		return head.rotation_degrees.x if head != null else rad_to_deg(_pitch)


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
	# Input.mouse_mode is the engine authority. Reconcile the retained player
	# flag at the raw-input boundary so a shell/page lifecycle transition cannot
	# leave captured motion gated behind a stale internal boolean.
	_reconcile_mouse_capture(&"raw_input")
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
		var disabled_position := global_position
		var disabled_velocity := velocity
		velocity = Vector3.ZERO
		_update_movement_transaction(
			delta,
			Input.get_vector("move_left", "move_right", "move_forward", "move_backward"),
			Vector3.ZERO,
			disabled_position,
			disabled_velocity,
			is_on_floor(),
			&"gameplay_disabled",
		)
		_sync_grounded_foley(&"gameplay_disabled")
		return
	_apply_gamepad_look(delta)

	var was_on_floor := is_on_floor()
	var position_before := global_position
	var velocity_before := velocity
	_update_stance()
	_update_camera_height(delta)

	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var desired_direction := transform.basis * Vector3(input_vector.x, 0.0, input_vector.y)
	desired_direction.y = 0.0
	desired_direction = desired_direction.normalized()

	var grounded := is_on_floor()
	var sprinting := grounded and _stance == "standing" and Input.is_action_pressed("sprint") and input_vector.y < -0.1
	_current_target_speed = 0.0 if desired_direction.is_zero_approx() else _get_target_speed(sprinting)
	var desired_velocity := desired_direction * _current_target_speed
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
	_update_movement_transaction(delta, input_vector, desired_velocity, position_before, velocity_before, was_on_floor)
	_sync_grounded_foley(&"physics_state")


func _update_movement_transaction(
	delta: float,
	input_vector: Vector2,
	desired_velocity: Vector3,
	position_before: Vector3,
	velocity_before: Vector3,
	grounded_before: bool,
	boundary := &"physics_window",
) -> void:
	var input_active := input_vector.length() > 0.05 and gameplay_input_enabled
	var started := input_active and not _movement_hold_active
	var released := not input_active and _movement_hold_active
	if started:
		_movement_hold_active = true
		_movement_release_pending = false
		_movement_hold_elapsed = 0.0
		_movement_sample_elapsed = 0.0
		_movement_hold_origin = position_before
		_movement_egress_latched = false
	if input_active:
		_movement_hold_elapsed += delta
		_movement_sample_elapsed += delta
	var frame_displacement := Vector2(global_position.x - position_before.x, global_position.z - position_before.z).length()
	var hold_displacement := Vector2(global_position.x - _movement_hold_origin.x, global_position.z - _movement_hold_origin.z).length() if (_movement_hold_active or released) else 0.0
	var egress_completed_now := not _movement_egress_latched and hold_displacement >= DEPLOYMENT_EGRESS_DISTANCE
	if egress_completed_now:
		_movement_egress_latched = true
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var release_settled := _movement_release_pending and horizontal_speed <= 0.05
	var gate_changed := gameplay_input_enabled != _movement_gate_observed
	var should_sample := started or released or egress_completed_now or release_settled or gate_changed or (input_active and _movement_sample_elapsed >= MOVEMENT_SAMPLE_INTERVAL_SECONDS)
	if boundary != &"physics_window" and (_movement_hold_active or _movement_release_pending or gate_changed):
		should_sample = true
	if should_sample:
		_movement_sample_elapsed = 0.0
		_movement_receipt_serial += 1
		var shell := get_tree().get_first_node_in_group(&"product_shell")
		var app_state := StringName(shell.get("app_state")) if shell != null else &"unknown"
		var paused := get_tree().paused
		var input_authorized := gameplay_input_enabled and not paused and app_state == &"gameplay"
		var result := &"gate_enabled" if gate_changed and gameplay_input_enabled else &"input_gated"
		if released:
			result = &"released_decelerating" if horizontal_speed > 0.05 else &"released_stopped"
		elif release_settled:
			result = &"release_settled"
		elif input_active and frame_displacement > 0.001:
			result = &"moved"
		elif input_active and get_slide_collision_count() > 0:
			result = &"collision_blocked"
		elif input_active:
			result = &"awaiting_displacement"
		_last_movement_receipt = {
			"receipt_id": "movement-g%04d-%06d" % [_deployment_generation, _movement_receipt_serial],
			"deployment_generation": _deployment_generation,
			"boundary": boundary,
			"phase": &"press" if started else &"release" if released else &"release_settled" if release_settled else &"hold",
			"app_state": app_state,
			"tree_paused": paused,
			"gameplay_input_enabled": gameplay_input_enabled,
			"input_authorized": input_authorized,
			"mouse_captured": _mouse_captured,
			"action_strengths": {
				"forward": Input.get_action_strength(&"move_forward"),
				"backward": Input.get_action_strength(&"move_backward"),
				"left": Input.get_action_strength(&"move_left"),
				"right": Input.get_action_strength(&"move_right"),
			},
			"action_vector": input_vector,
			"desired_velocity": desired_velocity,
			"velocity_before": velocity_before,
			"velocity_after": velocity,
			"position_before": position_before,
			"position_after": global_position,
			"frame_displacement": snappedf(frame_displacement, 0.0001),
			"hold_elapsed_seconds": snappedf(_movement_hold_elapsed, 0.001),
			"hold_displacement": snappedf(hold_displacement, 0.001),
			"deployment_egress_distance": DEPLOYMENT_EGRESS_DISTANCE,
			"deployment_egress_complete": _movement_egress_latched,
			"grounded_before": grounded_before,
			"grounded_after": is_on_floor(),
			"slide_collision_count": get_slide_collision_count(),
			"slide_contacts": _slide_contact_snapshot(),
			"result": result,
			"committed_frame": Engine.get_process_frames(),
			"committed_at_usec": Time.get_ticks_usec(),
		}
		_movement_receipt_history.append(_last_movement_receipt.duplicate(true))
		while _movement_receipt_history.size() > MOVEMENT_RECEIPT_HISTORY_LIMIT:
			_movement_receipt_history.pop_front()
	if released:
		_movement_hold_active = false
		_movement_release_pending = horizontal_speed > 0.05
	elif release_settled:
		_movement_release_pending = false
	_movement_gate_observed = gameplay_input_enabled


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
	var yaw_change_degrees := rad_to_deg(angle_difference(yaw_before, rotation.y))
	var pitch_change_degrees := rad_to_deg(_pitch - pitch_before)
	var requested_horizontal := absf(float(raw_input.x)) > 0.001 or absf(yaw_delta) > 0.000001
	var requested_vertical := absf(float(raw_input.y)) > 0.001 or absf(pitch_delta) > 0.000001
	var horizontal_verified := not requested_horizontal or absf(yaw_change_degrees) > 0.0001
	var vertical_verified := not requested_vertical or absf(pitch_change_degrees) > 0.0001
	var axis_change_verified := (requested_horizontal or requested_vertical) and horizontal_verified and vertical_verified
	_last_look_receipt = {
		"event_id": "look-g%04d-%04d" % [_deployment_generation, _look_generation_sequence],
		"receipt_id": "look-input-%06d" % _look_input_serial,
		"edge_id": "look-input-%06d" % _look_input_serial,
		"deployment_generation": _deployment_generation,
		"input_generation": _deployment_generation,
		"generation_sequence": _look_generation_sequence,
		"actual_player_path": String(get_path()),
		"actual_player_instance_id": get_instance_id(),
		"source": source,
		"raw_input": raw_input,
		"requested_axes": {"horizontal": requested_horizontal, "vertical": requested_vertical},
		"delta_seconds": delta_seconds,
		"yaw_before_degrees": rad_to_deg(yaw_before),
		"pitch_before_degrees": rad_to_deg(pitch_before),
		"yaw_delta_degrees": yaw_change_degrees,
		"pitch_delta_degrees": pitch_change_degrees,
		"yaw_after_degrees": rotation_degrees.y,
		"pitch_after_degrees": head.rotation_degrees.x,
		"accepted": axis_change_verified,
		"axis_change_verified": axis_change_verified,
		"failure_reason": &"" if axis_change_verified else &"requested_axis_unchanged",
		"gameplay_enabled": gameplay_input_enabled,
		"mouse_captured": _mouse_captured,
		"engine_mouse_mode": Input.mouse_mode,
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
	_movement_hold_active = false
	_movement_release_pending = false
	_movement_hold_elapsed = 0.0
	_movement_sample_elapsed = 0.0
	_movement_hold_origin = global_position
	_movement_egress_latched = false


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
	var requested: StringName = &"idle"
	if grounded and _landing_time_left <= 0.0 and horizontal_speed > 0.24:
		requested = &"run" if _locomotion_mode == "sprint" else &"crouch" if _stance == "crouched" else &"walk"
	var playback_state := &"run" if requested == &"run" else &"walk" if requested in [&"walk", &"crouch"] else &"idle"
	var walk := _foley_feedback.get_node_or_null("WalkAudio") as AudioStreamPlayer
	var run := _foley_feedback.get_node_or_null("RunAudio") as AudioStreamPlayer
	var state_changed := requested != _foley_locomotion or playback_state != _foley_state
	# PrototypePlayer translates authoritative locomotion state only. The
	# retained component remains the sole cadence, stream, and playback owner.
	if state_changed:
		match playback_state:
			&"run":
				_foley_feedback.call(&"start_run")
			&"walk":
				_foley_feedback.call(&"start_walk")
			_:
				_foley_feedback.call(&"stop_movement")
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
			"component_transition": playback_state,
			"surface": _surface_below(),
			"walk_playing": walk.playing if walk != null else false,
			"run_playing": run.playing if run != null else false,
			"walk_audio": _audio_owner_snapshot(walk),
			"run_audio": _audio_owner_snapshot(run),
			"active_stream_inventory": _active_audio_inventory(),
			"owner_count": 1,
			"runtime_generated_stream": false,
			"frame": Engine.get_physics_frames(),
		}


func _surface_below() -> StringName:
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.25, global_position + Vector3.DOWN * 1.4)
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var path := String((hit.get("collider") as Node).get_path()).to_lower() if hit.get("collider") is Node else ""
	return &"metal" if "metal" in path or "container" in path or "catwalk" in path or "grate" in path or "rail" in path else &"concrete"


func _audio_owner_snapshot(player: AudioStreamPlayer) -> Dictionary:
	if player == null:
		return {"bound": false}
	var bus_index := AudioServer.get_bus_index(player.bus)
	var bus_db := AudioServer.get_bus_volume_db(bus_index) if bus_index >= 0 else 0.0
	var master_index := AudioServer.get_bus_index(&"Master")
	var master_db := AudioServer.get_bus_volume_db(master_index) if master_index >= 0 else 0.0
	return {
		"bound": player.stream != null,
		"path": String(player.get_path()),
		"stream_path": player.stream.resource_path if player.stream != null else "",
		"duration_seconds": player.stream.get_length() if player.stream != null else 0.0,
		"playing": player.playing,
		"playback_position_seconds": player.get_playback_position() if player.playing else 0.0,
		"volume_db": player.volume_db,
		"pitch_scale": player.pitch_scale,
		"bus": player.bus,
		"bus_volume_db": bus_db,
		"bus_muted": AudioServer.is_bus_mute(bus_index) if bus_index >= 0 else false,
		"bus_solo": AudioServer.is_bus_solo(bus_index) if bus_index >= 0 else false,
		"bus_effect_count": AudioServer.get_bus_effect_count(bus_index) if bus_index >= 0 else 0,
		"master_volume_db": master_db,
		"effective_gain_db": player.volume_db + bus_db + master_db,
		"retained_component_stream": true,
		"runtime_generated": player.stream is AudioStreamGenerator,
	}


func _active_audio_inventory() -> Dictionary:
	var active: Array[Dictionary] = []
	var generated_count := 0
	var scene := get_tree().current_scene
	if scene == null:
		return {"active_count": 0, "runtime_generated_count": 0, "active": active}
	for type_name in [&"AudioStreamPlayer", &"AudioStreamPlayer3D"]:
		for node: Node in scene.find_children("*", String(type_name), true, false):
			var playing := bool(node.get("playing"))
			if not playing:
				continue
			var stream := node.get("stream") as AudioStream
			var generated := stream is AudioStreamGenerator
			generated_count += 1 if generated else 0
			active.append({
				"path": String(node.get_path()),
				"type": String(type_name),
				"bus": node.get("bus"),
				"stream_path": stream.resource_path if stream != null else "",
				"duration_seconds": stream.get_length() if stream != null else 0.0,
				"runtime_generated": generated,
			})
	return {
		"active_count": active.size(),
		"runtime_generated_count": generated_count,
		"active": active,
	}


func _configure_authoritative_foley_owner() -> void:
	# Preserve the retained component's authored WalkAudio/RunAudio resources.
	# Product code owns only state translation through the component API.
	if _foley_feedback == null:
		return
	_foley_feedback.call(&"stop_movement")


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_reconcile_mouse_capture(&"player_capture_request")


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_reconcile_mouse_capture(&"player_release_request")


func _reconcile_mouse_capture(source: StringName) -> bool:
	var observed := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if observed == _mouse_captured:
		return observed
	var previous := _mouse_captured
	_mouse_captured = observed
	_mouse_capture_sync_serial += 1
	_last_mouse_capture_sync_receipt = {
		"event_id": "mouse-capture-sync-%06d" % _mouse_capture_sync_serial,
		"source": source,
		"previous_captured": previous,
		"observed_captured": observed,
		"input_mouse_mode": Input.mouse_mode,
		"gameplay_enabled": gameplay_input_enabled,
		"committed_frame": Engine.get_process_frames(),
		"committed_at_usec": Time.get_ticks_usec(),
	}
	return observed


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
	_last_damage_attempt.clear()
	_damage_attempt_history.clear()
	_terminal_damage_rejection_count = 0
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


func tester_relocate_for_fixture(target_transform: Transform3D, fixture_id: StringName) -> Dictionary:
	var receipt := {
		"fixture_id": fixture_id,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	var validation := validate_recovery_destination(target_transform, [])
	receipt["validation"] = validation
	if validation.get("accepted", false) != true:
		receipt["failure_reason"] = validation.get("failure_reason", &"destination_rejected")
		return receipt
	_restore_movement_state(target_transform, health)
	receipt.merge({
		"resolved": true,
		"accepted": true,
		"position": global_position,
		"basis": global_basis,
		"input_enabled": gameplay_input_enabled,
		"mouse_captured": _mouse_captured,
		"failure_reason": &"",
	}, true)
	return receipt


func reset_transient_state_for_restore() -> void:
	_damage_commits.clear()
	_last_damage_event.clear()
	_last_damage_attempt.clear()
	_damage_attempt_history.clear()
	_terminal_damage_rejection_count = 0
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
	var event_id := damage_event_id if not damage_event_id.is_empty() else String(metadata.get("event_id", metadata.get("shot_id", "")))
	if event_id.is_empty():
		event_id = "player-damage-%06d" % (_damage_serial + 1)
	var damage_class := StringName(metadata.get("damage_class", &"ballistic"))
	if terminal_locked and damage_class != &"bomb_terminal_explosion":
		_terminal_damage_rejection_count += 1
		_last_damage_attempt = metadata.duplicate(true)
		_last_damage_attempt.merge({
			"event_id": event_id,
			"shot_id": String(metadata.get("shot_id", event_id)),
			"amount": amount,
			"health_before": health,
			"health_after": health,
			"max_health": max_health,
			"applied": false,
			"hit": false,
			"killed": false,
			"reason": &"terminal_damage_fence",
			"receiver_path": String(get_path()) if is_inside_tree() else "",
			"receiver_type": &"PrototypePlayer",
			"health_authority": &"PrototypePlayer.health",
			"terminal_event_id": terminal_event_id,
			"terminal_locked": terminal_locked,
			"rejection_count": _terminal_damage_rejection_count,
			"attempt_serial": _damage_attempt_serial + 1,
		}, true)
		_damage_attempt_serial += 1
		_damage_attempt_history.append(_last_damage_attempt.duplicate(true))
		while _damage_attempt_history.size() > 12:
			_damage_attempt_history.pop_front()
		return false
	if amount <= 0.0 or health <= 0.0:
		return false
	_damage_serial += 1
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
			"damage_class": damage_class,
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
	var health_before := health
	var duplicate_before := _damage_commits.has(damage_event_id) if not damage_event_id.is_empty() else false
	var applied := apply_authoritative_damage(amount, damage_event_id, report)
	if applied:
		report.merge(_last_damage_event, true)
	_damage_attempt_serial += 1
	report["event_id"] = damage_event_id if not damage_event_id.is_empty() else String(_last_damage_event.get("event_id", ""))
	report["shot_id"] = String(report.get("shot_id", report["event_id"]))
	report["amount"] = amount
	report["health_before"] = health_before
	report["health_after"] = health
	report["max_health"] = max_health
	report["applied"] = applied
	report["hit"] = applied
	report["killed"] = health <= 0.0
	report["reason"] = "applied" if applied else "duplicate_event" if duplicate_before else "dead_or_rejected"
	report["receiver_path"] = String(get_path()) if is_inside_tree() else ""
	report["receiver_type"] = &"PrototypePlayer"
	report["health_authority"] = &"PrototypePlayer.health"
	report["damage_commit_count"] = _damage_commits.size()
	report["restore_epoch"] = restore_epoch
	report["attempt_serial"] = _damage_attempt_serial
	_last_damage_attempt = report.duplicate(true)
	_damage_attempt_history.append(_last_damage_attempt)
	while _damage_attempt_history.size() > 12:
		_damage_attempt_history.pop_front()
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


func force_mouse_capture_reconcile(source: StringName = &"external_lifecycle_sync") -> Dictionary:
	var observed := _reconcile_mouse_capture(source)
	return {
		"source": source,
		"mouse_captured": _mouse_captured,
		"engine_mouse_captured": observed,
		"input_mouse_mode": Input.mouse_mode,
		"gameplay_input_enabled": gameplay_input_enabled,
		"sync_count": _mouse_capture_sync_serial,
		"last_sync_receipt": _last_mouse_capture_sync_receipt,
	}


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
		"damage_state": {
			"health": health,
			"max_health": max_health,
			"commit_count": _damage_commits.size(),
			"last_event": _last_damage_event,
			"last_attempt": _last_damage_attempt,
			"receiver_path": String(get_path()) if is_inside_tree() else "",
			"receiver_type": &"PrototypePlayer",
			"health_authority": &"PrototypePlayer.health",
			"event_id_deduplication": true,
				"restore_epoch": restore_epoch,
				"combat_death_locked": combat_death_locked,
				"terminal_damage_rejection_count": _terminal_damage_rejection_count,
			},
		"axis_change_receipt": _last_look_receipt,
		"position": global_position,
		"velocity": velocity,
		"yaw_degrees": rotation_degrees.y,
		"pitch_degrees": head.rotation_degrees.x if head_ready else rad_to_deg(_pitch),
		"mouse_captured": _mouse_captured,
		"engine_mouse_captured": Input.mouse_mode == Input.MOUSE_MODE_CAPTURED,
		"mouse_capture_sync_count": _mouse_capture_sync_serial,
		"last_mouse_capture_sync_receipt": _last_mouse_capture_sync_receipt,
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
		"foley_runtime_audit": {
			"sole_owner_path": String(_foley_feedback.get_path()) if _foley_feedback != null else "",
			"owner_count": 1 if _foley_feedback != null else 0,
			"retained_player_names": [&"WalkAudio", &"RunAudio"],
			"cadence_authority": String(_foley_feedback.get_path()) if _foley_feedback != null else "",
			"source_profile": &"retained_component_authored_streams",
			"walk_audio": _audio_owner_snapshot(_foley_feedback.get_node_or_null("WalkAudio") as AudioStreamPlayer) if _foley_feedback != null else {"bound": false},
			"run_audio": _audio_owner_snapshot(_foley_feedback.get_node_or_null("RunAudio") as AudioStreamPlayer) if _foley_feedback != null else {"bound": false},
			"active_stream_inventory": _active_audio_inventory(),
			"per_contact_long_recording_restart": false,
		},
		"blocked_seconds": _blocked_seconds,
		"last_stuck_diagnostic": _last_stuck_diagnostic,
		"slide_contacts": _slide_contact_snapshot(),
		"health": health,
		"max_health": max_health,
			"damage_commit_count": _damage_commits.size(),
			"terminal_damage_rejection_count": _terminal_damage_rejection_count,
		"last_damage_event": _last_damage_event,
		"last_damage_attempt": _last_damage_attempt,
		"damage_attempt_history": _damage_attempt_history.duplicate(true),
		"damage_receiver_contract": {
			"receiver_path": String(get_path()) if is_inside_tree() else "",
			"receiver_type": &"PrototypePlayer",
			"method": &"apply_damage",
			"health_authority": &"PrototypePlayer.health",
			"event_id_deduplication": true,
			"restore_epoch": restore_epoch,
		},
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
		"movement_receipt_history_limit": MOVEMENT_RECEIPT_HISTORY_LIMIT,
		"movement_receipt_history": _movement_receipt_history.duplicate(true),
		"last_movement_receipt": _last_movement_receipt,
	}
