class_name FPSPlayerMotor
extends CharacterBody3D

signal locomotion_state_changed(state: StringName, snapshot: Dictionary)
signal stance_changed(crouched: bool, height: float)
signal jumped(vertical_velocity: float)
signal landed(impact_speed: float)

@export_group("Movement")
@export_range(0.1, 30.0, 0.1) var walk_speed := 4.8
@export_range(0.1, 40.0, 0.1) var sprint_speed := 7.6
@export_range(0.1, 20.0, 0.1) var crouch_speed := 2.8
@export_range(0.1, 30.0, 0.1) var ground_acceleration := 18.0
@export_range(0.1, 30.0, 0.1) var air_acceleration := 4.0
@export_range(0.1, 30.0, 0.1) var jump_velocity := 5.3
@export_range(0.1, 80.0, 0.1) var gravity := 18.0
@export_range(0.02, 1.0, 0.02) var landing_state_seconds := 0.16

@export_group("Stance")
@export_range(0.6, 3.0, 0.05) var standing_height := 1.8
@export_range(0.4, 2.0, 0.05) var crouch_height := 1.15
@export_range(0.2, 2.5, 0.05) var standing_camera_height := 1.62
@export_range(0.2, 2.0, 0.05) var crouch_camera_height := 0.96
@export_range(1.0, 30.0, 0.5) var stance_transition_speed := 10.0
@export var crouch_is_toggle := false

@export_group("Bindings")
@export_node_path("CollisionShape3D") var collision_shape_path: NodePath = ^"CollisionShape3D"
@export_node_path("Node3D") var head_path: NodePath = ^"Head"
@export_node_path("Camera3D") var camera_path: NodePath = ^"Head/Camera3D"
@export_node_path("Node") var presentation_path: NodePath
@export var mouse_sensitivity := 0.0022
@export var capture_mouse_on_ready := true

@export_group("Input actions")
@export var move_left_action: StringName = &"move_left"
@export var move_right_action: StringName = &"move_right"
@export var move_forward_action: StringName = &"move_forward"
@export var move_back_action: StringName = &"move_back"
@export var sprint_action: StringName = &"sprint"
@export var jump_action: StringName = &"jump"
@export var crouch_action: StringName = &"crouch"

var crouched := false
var locomotion_state: StringName = &"idle"
var _collision_shape: CollisionShape3D
var _capsule: CapsuleShape3D
var _head: Node3D
var _camera: Camera3D
var _presentation: Node
var _was_on_floor := false
var _fall_speed := 0.0
var _landing_remaining := 0.0
var _airborne_since_last_floor := false


func _ready() -> void:
	_collision_shape = get_node_or_null(collision_shape_path) as CollisionShape3D
	_head = get_node_or_null(head_path) as Node3D
	_camera = get_node_or_null(camera_path) as Camera3D
	_presentation = get_node_or_null(presentation_path) if not presentation_path.is_empty() else null
	if _collision_shape != null and _collision_shape.shape is CapsuleShape3D:
		_capsule = _collision_shape.shape.duplicate() as CapsuleShape3D
		_collision_shape.shape = _capsule
		_apply_stance_geometry(standing_height, standing_camera_height, true)
	else:
		push_error("FPSPlayerMotor requires a CapsuleShape3D")
	if capture_mouse_on_ready:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# Camera look must observe captured relative motion before decorative HUD
# Controls can consume it. The captured-mode guard still keeps menu interaction
# from rotating the player when the pointer is released.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		rotate_y(-motion.relative.x * mouse_sensitivity)
		if _head != null:
			_head.rotate_x(-motion.relative.y * mouse_sensitivity)
			_head.rotation.x = clampf(_head.rotation.x, deg_to_rad(-88.0), deg_to_rad(88.0))
	if _event_action_pressed(event, crouch_action) and crouch_is_toggle:
		set_crouched(not crouched)
	if _event_action_pressed(event, jump_action):
		request_jump()


func _physics_process(delta: float) -> void:
	if not crouch_is_toggle:
		set_crouched(_action_pressed(crouch_action))
	var input := _movement_input()
	var wish_direction := (global_basis * Vector3(input.x, 0.0, input.y)).normalized()
	var wants_sprint := _action_pressed(sprint_action) and not crouched and input.y < -0.1
	var speed := crouch_speed if crouched else (sprint_speed if wants_sprint else walk_speed)
	var target_horizontal := wish_direction * speed
	var acceleration := ground_acceleration if is_on_floor() else air_acceleration
	velocity.x = move_toward(velocity.x, target_horizontal.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_horizontal.z, acceleration * delta)
	if not is_on_floor():
		velocity.y -= gravity * delta
		_fall_speed = minf(_fall_speed, velocity.y)
	elif velocity.y < 0.0:
		velocity.y = -0.1
	move_and_slide()
	if not is_on_floor():
		_airborne_since_last_floor = true
	var landed_now := is_on_floor() and not _was_on_floor and _airborne_since_last_floor
	if landed_now:
		landed.emit(absf(_fall_speed))
		_fall_speed = 0.0
		_landing_remaining = landing_state_seconds
		_airborne_since_last_floor = false
		_set_locomotion_state(&"land")
	elif _landing_remaining > 0.0:
		_landing_remaining = maxf(0.0, _landing_remaining - delta)
	_was_on_floor = is_on_floor()
	_update_stance_transition(delta)
	if _landing_remaining <= 0.0:
		_update_state(input, wants_sprint)


func request_jump() -> bool:
	if not is_on_floor() or crouched:
		return false
	_landing_remaining = 0.0
	_airborne_since_last_floor = true
	velocity.y = jump_velocity
	jumped.emit(jump_velocity)
	_set_locomotion_state(&"jump")
	return true


func set_crouched(enabled: bool, immediate := false) -> bool:
	if enabled == crouched:
		return true
	if not enabled and not _can_stand():
		return false
	crouched = enabled
	if immediate:
		_apply_stance_geometry(
			crouch_height if crouched else standing_height,
			crouch_camera_height if crouched else standing_camera_height,
			true,
		)
	stance_changed.emit(crouched, crouch_height if crouched else standing_height)
	return true


func snapshot() -> Dictionary:
	return {
		"state": String(locomotion_state),
		"crouched": crouched,
		"on_floor": is_on_floor(),
		"velocity": velocity,
		"collision_height": _capsule.height if _capsule != null else 0.0,
		"camera_height": _camera.position.y if _camera != null else 0.0,
	}


func _can_stand() -> bool:
	var extra_height := maxf(standing_height - crouch_height, 0.0)
	return not test_move(global_transform, Vector3.UP * extra_height)


func _update_stance_transition(delta: float) -> void:
	var target_height := crouch_height if crouched else standing_height
	var target_camera := crouch_camera_height if crouched else standing_camera_height
	_apply_stance_geometry(target_height, target_camera, false, delta)


func _apply_stance_geometry(height: float, camera_height: float, immediate: bool, delta := 0.0) -> void:
	if _capsule != null:
		_capsule.height = height if immediate else move_toward(_capsule.height, height, stance_transition_speed * delta)
		if _collision_shape != null:
			_collision_shape.position.y = _capsule.height * 0.5
	if _camera != null:
		_camera.position.y = camera_height if immediate else move_toward(_camera.position.y, camera_height, stance_transition_speed * delta)


func _update_state(input: Vector2, wants_sprint: bool) -> void:
	if not is_on_floor():
		_set_locomotion_state(&"jump" if velocity.y > 0.0 else &"fall")
	elif crouched:
		_set_locomotion_state(&"crouch_move" if input.length_squared() > 0.01 else &"crouch_idle")
	elif input.length_squared() <= 0.01:
		_set_locomotion_state(&"idle")
	elif wants_sprint:
		_set_locomotion_state(&"run")
	else:
		_set_locomotion_state(&"walk")


func _set_locomotion_state(next_state: StringName) -> void:
	if locomotion_state == next_state:
		return
	locomotion_state = next_state
	if _presentation != null:
		if _presentation.has_method("set_locomotion_state"):
			_presentation.call("set_locomotion_state", next_state)
		elif _presentation.has_method(next_state):
			_presentation.call(next_state)
	locomotion_state_changed.emit(next_state, snapshot())


func _movement_input() -> Vector2:
	var left := Input.get_action_strength(move_left_action) if InputMap.has_action(move_left_action) else 0.0
	var right := Input.get_action_strength(move_right_action) if InputMap.has_action(move_right_action) else 0.0
	var forward := Input.get_action_strength(move_forward_action) if InputMap.has_action(move_forward_action) else 0.0
	var back := Input.get_action_strength(move_back_action) if InputMap.has_action(move_back_action) else 0.0
	return Vector2(right - left, back - forward).limit_length()


func _action_pressed(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


func _event_action_pressed(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action)
