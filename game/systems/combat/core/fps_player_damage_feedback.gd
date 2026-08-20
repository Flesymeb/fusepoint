class_name FPSPlayerDamageFeedback
extends CanvasLayer

## Event-driven first-person damage feedback. The edge texture is intentionally
## transparent: it adds a brief red pain vignette without placing an opaque
## panel over the game. Death keeps the vignette and fades the world down.

signal damage_feedback_started(event: Dictionary)
signal death_feedback_started(event: Dictionary)

@export_node_path("FPSHealth") var health_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath
@export_range(0.05, 2.0, 0.01) var damage_flash_seconds := 0.38
@export_range(0.0, 1.0, 0.01) var damage_flash_min_alpha := 0.34
@export_range(0.0, 1.0, 0.01) var damage_flash_max_alpha := 0.68
@export_range(0.0, 1.0, 0.01) var low_health_max_alpha := 0.2
@export_range(0.0, 1.0, 0.01) var death_vignette_alpha := 0.78
@export_range(0.0, 1.0, 0.01) var death_wash_alpha := 0.72
@export_range(0.05, 3.0, 0.01) var death_fade_seconds := 0.48
@export_range(0.05, 3.0, 0.01) var death_camera_seconds := 0.78
@export_range(0.0, 2.0, 0.05) var death_camera_drop := 0.62
@export_range(0.0, 2.0, 0.05) var death_camera_pullback := 0.5
@export_range(-30.0, 30.0, 0.5) var death_camera_pitch_degrees := 8.0
@export_range(-30.0, 30.0, 0.5) var death_camera_roll_degrees := 4.0

@onready var pain_overlay: TextureRect = %PainOverlay
@onready var death_wash: ColorRect = %DeathWash
@onready var death_message: Label = %DeathMessage

var damage_event_count := 0
var death_active := false
var _health: FPSHealth
var _camera: Camera3D
var _camera_rest_position := Vector3.ZERO
var _camera_rest_rotation := Vector3.ZERO
var _damage_tween: Tween
var _death_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_camera = get_node_or_null(camera_path) as Camera3D if not camera_path.is_empty() else null
	if _camera != null:
		_camera_rest_position = _camera.position
		_camera_rest_rotation = _camera.rotation
	reset_feedback()
	if not health_path.is_empty():
		bind_health(get_node_or_null(health_path) as FPSHealth)


func bind_health(next_health: FPSHealth) -> void:
	if _health == next_health:
		return
	if _health != null:
		if _health.damaged.is_connected(show_damage):
			_health.damaged.disconnect(show_damage)
		if _health.died.is_connected(show_death):
			_health.died.disconnect(show_death)
		if _health.revived.is_connected(_on_revived):
			_health.revived.disconnect(_on_revived)
	_health = next_health
	if _health == null:
		return
	_health.damaged.connect(show_damage)
	_health.died.connect(show_death)
	_health.revived.connect(_on_revived)


func show_damage(event: Dictionary) -> void:
	if death_active:
		return
	damage_event_count += 1
	_kill_damage_tween()
	var maximum := maxf(float(event.get("max_health", 100.0)), 1.0)
	var amount_ratio := clampf(float(event.get("amount", 0.0)) / maximum, 0.0, 1.0)
	var health_ratio := clampf(float(event.get("health_after", maximum)) / maximum, 0.0, 1.0)
	var peak := clampf(
		damage_flash_min_alpha + amount_ratio * 1.8,
		damage_flash_min_alpha,
		damage_flash_max_alpha
	)
	var persistent := pow(1.0 - health_ratio, 1.6) * low_health_max_alpha
	pain_overlay.modulate = Color(1.0, 1.0, 1.0, peak)
	_damage_tween = create_tween()
	_damage_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_damage_tween.tween_property(
		pain_overlay,
		"modulate",
		Color(1.0, 1.0, 1.0, persistent),
		damage_flash_seconds
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	damage_feedback_started.emit(event.duplicate(true))


func show_death(event: Dictionary) -> void:
	death_active = true
	_kill_damage_tween()
	_kill_death_tween()
	pain_overlay.modulate = Color(1.0, 1.0, 1.0, death_vignette_alpha)
	death_wash.modulate = Color(1.0, 1.0, 1.0, 0.0)
	death_message.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_death_tween = create_tween().set_parallel(true)
	_death_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_death_tween.tween_property(
		death_wash,
		"modulate",
		Color(1.0, 1.0, 1.0, death_wash_alpha),
		death_fade_seconds
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_death_tween.tween_property(
		death_message,
		"modulate",
		Color.WHITE,
		death_fade_seconds * 0.8
	).set_delay(death_fade_seconds * 0.2)
	if _camera != null:
		_death_tween.tween_property(
			_camera,
			"position",
			_camera_rest_position + Vector3(0.0, -death_camera_drop, death_camera_pullback),
			death_camera_seconds
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
		_death_tween.tween_property(
			_camera,
			"rotation",
			_camera_rest_rotation + Vector3(
				deg_to_rad(death_camera_pitch_degrees),
				0.0,
				deg_to_rad(death_camera_roll_degrees)
			),
			death_camera_seconds
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	death_feedback_started.emit(event.duplicate(true))


func reset_feedback() -> void:
	death_active = false
	damage_event_count = 0
	_kill_damage_tween()
	_kill_death_tween()
	if pain_overlay != null:
		pain_overlay.modulate = Color(1.0, 1.0, 1.0, 0.0)
	if death_wash != null:
		death_wash.modulate = Color(1.0, 1.0, 1.0, 0.0)
	if death_message != null:
		death_message.modulate = Color(1.0, 1.0, 1.0, 0.0)
	if _camera != null:
		_camera.position = _camera_rest_position
		_camera.rotation = _camera_rest_rotation


func snapshot() -> Dictionary:
	return {
		"damage_event_count": damage_event_count,
		"death_active": death_active,
		"pain_alpha": pain_overlay.modulate.a if pain_overlay != null else 0.0,
		"death_wash_alpha": death_wash.modulate.a if death_wash != null else 0.0,
		"health_bound": _health != null,
		"camera_bound": _camera != null,
		"camera_drop": _camera_rest_position.y - _camera.position.y if _camera != null else 0.0,
		"camera_pullback": _camera.position.z - _camera_rest_position.z if _camera != null else 0.0,
	}


func _on_revived(_current: float, _maximum: float) -> void:
	reset_feedback()


func _kill_damage_tween() -> void:
	if _damage_tween != null and _damage_tween.is_valid():
		_damage_tween.kill()
	_damage_tween = null


func _kill_death_tween() -> void:
	if _death_tween != null and _death_tween.is_valid():
		_death_tween.kill()
	_death_tween = null
