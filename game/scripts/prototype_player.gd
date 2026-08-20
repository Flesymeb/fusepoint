extends CharacterBody3D

signal spawn_reset

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
@export_range(30.0, 89.0, 1.0) var pitch_limit_degrees := 82.0

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


func _ready() -> void:
	_spawn_transform = global_transform
	_spawn_head_rotation = head.rotation
	_standing_clearance_shape.radius = 0.4
	_standing_clearance_shape.height = standing_height
	floor_snap_length = 0.25
	floor_stop_on_slope = true
	_capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_release_mouse()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_LEFT and not _mouse_captured:
			_capture_mouse()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion and _mouse_captured:
		var mouse_motion := event as InputEventMouseMotion
		rotate_y(-mouse_motion.relative.x * mouse_sensitivity)
		_pitch = clampf(
			_pitch - mouse_motion.relative.y * mouse_sensitivity,
			-deg_to_rad(pitch_limit_degrees),
			deg_to_rad(pitch_limit_degrees)
		)
		head.rotation.x = _pitch
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		_reset_to_spawn()
		return

	var was_on_floor := is_on_floor()
	_update_stance()

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
		_stand_clearance = false
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
		head.position.y = crouching_eye_height
	else:
		_stance = "standing"
		capsule.height = standing_height
		collision_shape.position.y = 0.0
		head.position.y = standing_eye_height


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
	else:
		_locomotion_mode = "walk"


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mouse_captured = false


func _reset_to_spawn() -> void:
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
	_set_stance(false)
	_capture_mouse()
	spawn_reset.emit()


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
		"camera_height": head.position.y,
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
	}
