extends CharacterBody3D

@export var movement_speed := 5.0
@export var ground_acceleration := 24.0
@export var mouse_sensitivity := 0.0022
@export_range(30.0, 89.0, 1.0) var pitch_limit_degrees := 82.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _spawn_transform: Transform3D
var _spawn_head_rotation: Vector3
var _pitch := 0.0
var _mouse_captured := false


func _ready() -> void:
	_spawn_transform = global_transform
	_spawn_head_rotation = head.rotation
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

	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var desired_direction := transform.basis * Vector3(input_vector.x, 0.0, input_vector.y)
	desired_direction.y = 0.0
	desired_direction = desired_direction.normalized()

	velocity.x = move_toward(velocity.x, desired_direction.x * movement_speed, ground_acceleration * delta)
	velocity.z = move_toward(velocity.z, desired_direction.z * movement_speed, ground_acceleration * delta)
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= _gravity * delta

	move_and_slide()


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
	_capture_mouse()


func _mcp_state() -> Dictionary:
	return {
		"position": global_position,
		"velocity": velocity,
		"yaw_degrees": rotation_degrees.y,
		"pitch_degrees": head.rotation_degrees.x,
		"mouse_captured": _mouse_captured,
		"on_floor": is_on_floor(),
		"camera_current": camera.current,
		"spawn_position": _spawn_transform.origin,
		"pitch_limit_degrees": pitch_limit_degrees,
	}
