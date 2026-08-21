class_name FPSPlayerDamageFeedback
extends CanvasLayer

## Presentation-only observer for immutable PrototypePlayer damage payloads.
## It never owns health, damage, mission state, or event sequencing.

signal damage_feedback_started(event: Dictionary)
signal death_feedback_started(event: Dictionary)
signal restore_feedback_completed(epoch: int)

@export_node_path("Node3D") var player_path: NodePath
@export_node_path("Camera3D") var camera_path: NodePath
@export var settings_store_path: NodePath
@export_range(0.05, 2.0, 0.01) var damage_flash_seconds := 0.48
@export_range(0.0, 1.0, 0.01) var damage_flash_min_alpha := 0.10
@export_range(0.0, 1.0, 0.01) var damage_flash_max_alpha := 0.28
@export_range(0.0, 1.0, 0.01) var low_health_max_alpha := 0.08
@export_range(0.0, 1.0, 0.01) var death_vignette_alpha := 0.34
@export_range(0.0, 1.0, 0.01) var death_wash_alpha := 0.24
@export_range(0.05, 3.0, 0.01) var death_fade_seconds := 0.48
@export_range(0.05, 3.0, 0.01) var death_camera_seconds := 0.78
@export_range(0.0, 2.0, 0.05) var death_camera_drop := 0.36
@export_range(0.0, 2.0, 0.05) var death_camera_pullback := 0.18
@export_range(-30.0, 30.0, 0.5) var death_camera_pitch_degrees := 12.0
@export_range(-30.0, 30.0, 0.5) var death_camera_roll_degrees := 5.0
@export_range(0.6, 1.0, 0.05) var restore_color_seconds := 0.8

@onready var death_grade: ColorRect = %DeathGrade
@onready var pain_overlay: TextureRect = %PainOverlay
@onready var damage_arc: Line2D = %DamageArc
@onready var death_wash: ColorRect = %DeathWash
@onready var death_message: Label = %DeathMessage

var damage_event_count := 0
var death_active := false
var observed_event_id := ""
var observed_direction := &"none"
var observed_direction_radians := 0.0
var observed_severity := &"none"
var observed_severity_ratio := 0.0
var feedback_lifetime_remaining := 0.0
var camera_response_active := false
var death_kind := &"none"
var restore_transition_active := false
var recovery_saturation := 1.0

var _player: Node
var _camera: Camera3D
var _settings_store: Node
var _camera_rest_position := Vector3.ZERO
var _camera_rest_rotation := Vector3.ZERO
var _observed_events: Dictionary = {}
var _last_death_event_id := ""
var _damage_tween: Tween
var _death_tween: Tween
var _restore_tween: Tween
var _applied_reduced_motion := false
var _applied_screen_shake := true
var _restore_epoch := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_camera = get_node_or_null(camera_path) as Camera3D if not camera_path.is_empty() else null
	_settings_store = get_node_or_null(settings_store_path) if not settings_store_path.is_empty() else null
	if _camera != null:
		_camera_rest_position = _camera.position
		_camera_rest_rotation = _camera.rotation
	reset_feedback(true)
	if not player_path.is_empty():
		bind_player(get_node_or_null(player_path))


func _process(delta: float) -> void:
	feedback_lifetime_remaining = maxf(0.0, feedback_lifetime_remaining - delta)
	if feedback_lifetime_remaining <= 0.0:
		camera_response_active = false


func bind_player(next_player: Node) -> void:
	if _player == next_player:
		return
	if _player != null:
		if _player.is_connected(&"authoritative_damage_received", show_damage):
			_player.disconnect(&"authoritative_damage_received", show_damage)
		if _player.is_connected(&"player_died", show_death):
			_player.disconnect(&"player_died", show_death)
		if _player.is_connected(&"checkpoint_restored", _on_checkpoint_restored):
			_player.disconnect(&"checkpoint_restored", _on_checkpoint_restored)
		if _player.is_connected(&"spawn_reset", _on_spawn_reset):
			_player.disconnect(&"spawn_reset", _on_spawn_reset)
	_player = next_player
	if _player == null:
		return
	_player.connect(&"authoritative_damage_received", show_damage)
	_player.connect(&"player_died", show_death)
	_player.connect(&"checkpoint_restored", _on_checkpoint_restored)
	_player.connect(&"spawn_reset", _on_spawn_reset)


func show_damage(event: Dictionary) -> void:
	var event_id := String(event.get("event_id", ""))
	if event_id.is_empty() or _observed_events.has(event_id) or death_active:
		return
	_observed_events[event_id] = true
	damage_event_count += 1
	observed_event_id = event_id
	observed_severity = StringName(event.get("severity", &"light"))
	observed_severity_ratio = clampf(float(event.get("severity_ratio", 0.0)), 0.0, 1.0)
	feedback_lifetime_remaining = damage_flash_seconds
	_kill_damage_tween()

	var maximum := maxf(float(event.get("max_health", 100.0)), 1.0)
	var amount_ratio := clampf(float(event.get("amount", 0.0)) / maximum, 0.0, 1.0)
	var health_ratio := clampf(float(event.get("health_after", maximum)) / maximum, 0.0, 1.0)
	var peak := clampf(damage_flash_min_alpha + amount_ratio * 0.7, damage_flash_min_alpha, damage_flash_max_alpha)
	var persistent := pow(1.0 - health_ratio, 1.7) * low_health_max_alpha
	observed_direction_radians = _direction_to_source(event.get("source_position", null))
	observed_direction = _direction_name(observed_direction_radians)
	_configure_direction_arc(observed_direction_radians, peak)
	pain_overlay.modulate = Color(1.0, 1.0, 1.0, peak)
	damage_arc.modulate = Color.WHITE
	_apply_camera_impulse(observed_direction_radians, amount_ratio)

	_damage_tween = create_tween().set_parallel(true)
	_damage_tween.set_pause_mode(Tween.TWEEN_PAUSE_BOUND)
	_damage_tween.tween_property(pain_overlay, "modulate", Color(1.0, 1.0, 1.0, persistent), damage_flash_seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_damage_tween.tween_property(damage_arc, "modulate", Color(1.0, 1.0, 1.0, 0.0), damage_flash_seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if _camera != null and camera_response_active:
		_damage_tween.tween_property(_camera, "position", _camera_rest_position, damage_flash_seconds * 0.72).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_damage_tween.tween_property(_camera, "rotation", _camera_rest_rotation, damage_flash_seconds * 0.72).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	damage_feedback_started.emit(event.duplicate(true))


func show_death(event: Dictionary) -> void:
	var event_id := String(event.get("event_id", ""))
	if death_active or (not event_id.is_empty() and event_id == _last_death_event_id):
		return
	_last_death_event_id = event_id
	death_kind = &"bomb_terminal" if StringName(event.get("damage_class", &"")) == &"bomb_terminal_explosion" else &"combat"
	death_active = true
	feedback_lifetime_remaining = 0.0
	camera_response_active = false
	_kill_damage_tween()
	_kill_death_tween()
	if _restore_tween != null and _restore_tween.is_valid():
		_restore_tween.kill()
	_restore_tween = null
	pain_overlay.modulate = Color(1.0, 1.0, 1.0, death_vignette_alpha if death_kind == &"bomb_terminal" else minf(0.56, death_vignette_alpha + 0.16))
	damage_arc.modulate = Color(1.0, 1.0, 1.0, 0.0)
	death_wash.modulate = Color(1.0, 1.0, 1.0, 0.0)
	death_message.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_set_recovery_saturation(1.0 if death_kind == &"bomb_terminal" else 0.05)
	_death_tween = create_tween().set_parallel(true)
	_death_tween.set_pause_mode(Tween.TWEEN_PAUSE_BOUND)
	_death_tween.tween_property(death_wash, "modulate", Color(1.0, 1.0, 1.0, death_wash_alpha), death_fade_seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if death_kind != &"bomb_terminal":
		_death_tween.tween_property(death_message, "modulate", Color.WHITE, death_fade_seconds * 0.8).set_delay(death_fade_seconds * 0.2)
	if _camera != null and death_kind == &"bomb_terminal":
		var motion_scale := _camera_motion_scale()
		_death_tween.tween_property(_camera, "position", _camera_rest_position + Vector3(0.0, -death_camera_drop * motion_scale, death_camera_pullback * motion_scale), death_camera_seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
		_death_tween.tween_property(_camera, "rotation", _camera_rest_rotation + Vector3(deg_to_rad(death_camera_pitch_degrees) * motion_scale, 0.0, deg_to_rad(death_camera_roll_degrees) * motion_scale), death_camera_seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	death_feedback_started.emit(event.duplicate(true))


func reset_feedback(clear_event_history := false) -> void:
	death_active = false
	restore_transition_active = false
	feedback_lifetime_remaining = 0.0
	camera_response_active = false
	_kill_damage_tween()
	_kill_death_tween()
	if _restore_tween != null and _restore_tween.is_valid():
		_restore_tween.kill()
	_restore_tween = null
	if clear_event_history:
		damage_event_count = 0
		_observed_events.clear()
		_last_death_event_id = ""
		death_kind = &"none"
		observed_event_id = ""
		observed_direction = &"none"
		observed_severity = &"none"
		observed_severity_ratio = 0.0
	if pain_overlay != null:
		pain_overlay.modulate = Color(1.0, 1.0, 1.0, 0.0)
	if damage_arc != null:
		damage_arc.modulate = Color(1.0, 1.0, 1.0, 0.0)
	if death_wash != null:
		death_wash.modulate = Color(1.0, 1.0, 1.0, 0.0)
	if death_message != null:
		death_message.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_set_recovery_saturation(1.0)
	_restore_camera_rest()


func reset_for_restore(epoch: int) -> void:
	if epoch <= 0 or (restore_transition_active and epoch == _restore_epoch):
		return
	_restore_epoch = maxi(_restore_epoch, epoch)
	death_active = false
	feedback_lifetime_remaining = 0.0
	camera_response_active = false
	_kill_damage_tween()
	_kill_death_tween()
	if _restore_tween != null and _restore_tween.is_valid():
		_restore_tween.kill()
	_restore_camera_rest()
	restore_transition_active = true
	_set_recovery_saturation(0.05)
	_restore_tween = create_tween().set_parallel(true)
	_restore_tween.set_pause_mode(Tween.TWEEN_PAUSE_BOUND)
	_restore_tween.tween_method(_set_recovery_saturation, 0.05, 1.0, restore_color_seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_restore_tween.tween_property(pain_overlay, "modulate", Color(1.0, 1.0, 1.0, 0.0), restore_color_seconds * 0.75)
	_restore_tween.tween_property(death_wash, "modulate", Color(1.0, 1.0, 1.0, 0.0), restore_color_seconds * 0.75)
	_restore_tween.tween_property(death_message, "modulate", Color(1.0, 1.0, 1.0, 0.0), restore_color_seconds * 0.45)
	_restore_tween.finished.connect(_finish_restore_transition.bind(epoch))


func apply_accessibility_settings(values: Dictionary) -> void:
	_applied_reduced_motion = values.get("reduced_camera_motion", false) == true
	_applied_screen_shake = values.get("screen_shake", true) == true


func snapshot() -> Dictionary:
	return {
		"damage_event_count": damage_event_count,
		"death_active": death_active,
		"observed_event_id": observed_event_id,
		"observed_direction": observed_direction,
		"observed_direction_radians": observed_direction_radians,
		"observed_severity": observed_severity,
		"observed_severity_ratio": observed_severity_ratio,
		"feedback_alpha": maxf(pain_overlay.modulate.a, damage_arc.modulate.a * damage_arc.default_color.a) if pain_overlay != null and damage_arc != null else 0.0,
		"feedback_lifetime_remaining": feedback_lifetime_remaining,
		"camera_response_active": camera_response_active,
		"death_kind": death_kind,
		"restore_transition_active": restore_transition_active,
		"recovery_saturation": recovery_saturation,
		"restore_color_seconds": restore_color_seconds,
		"health_bound": _player != null,
		"camera_bound": _camera != null,
		"camera_offset": _camera.position - _camera_rest_position if _camera != null else Vector3.ZERO,
		"restore_epoch": _restore_epoch,
		"reduced_camera_motion": _applied_reduced_motion,
		"screen_shake_enabled": _applied_screen_shake,
	}


func _direction_to_source(source_position: Variant) -> float:
	if _camera == null or not source_position is Vector3:
		return 0.0
	var to_source := (source_position as Vector3) - _camera.global_position
	if to_source.length_squared() <= 0.0001:
		return 0.0
	var local_direction := _camera.global_transform.basis.inverse() * to_source.normalized()
	return atan2(local_direction.x, -local_direction.z)


func _direction_name(angle: float) -> StringName:
	var x := sin(angle)
	var forward := cos(angle)
	if absf(x) > absf(forward):
		return &"right" if x > 0.0 else &"left"
	return &"front" if forward >= 0.0 else &"rear"


func _configure_direction_arc(angle: float, alpha: float) -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var center := viewport_size * 0.5
	var radius := minf(viewport_size.x, viewport_size.y) * 0.38
	var screen_angle := angle - PI * 0.5
	var points := PackedVector2Array()
	for index in 17:
		var offset := lerpf(-0.38, 0.38, float(index) / 16.0)
		points.append(center + Vector2(cos(screen_angle + offset), sin(screen_angle + offset)) * radius)
	damage_arc.points = points
	damage_arc.default_color = Color(1.0, 0.055, 0.025, clampf(alpha * 1.55, 0.45, 0.92))
	damage_arc.width = lerpf(7.0, 14.0, observed_severity_ratio)


func _apply_camera_impulse(angle: float, amount_ratio: float) -> void:
	if _camera == null:
		return
	var motion_scale := _camera_motion_scale()
	if motion_scale <= 0.0:
		return
	var severity := clampf(amount_ratio * 4.0, 0.2, 1.0) * motion_scale
	_camera.position = _camera_rest_position + Vector3(-sin(angle) * 0.026 * severity, 0.008 * severity, 0.012 * severity)
	_camera.rotation = _camera_rest_rotation + Vector3(0.006 * severity, 0.0, -sin(angle) * 0.018 * severity)
	camera_response_active = true


func _camera_motion_scale() -> float:
	if not _applied_screen_shake:
		return 0.0
	return 0.35 if _applied_reduced_motion else 1.0


func _on_checkpoint_restored(event: Dictionary) -> void:
	reset_for_restore(int(event.get("restore_epoch", _restore_epoch + 1)))


func _on_spawn_reset() -> void:
	reset_feedback(true)


func _restore_camera_rest() -> void:
	if _camera != null:
		_camera.position = _camera_rest_position
		_camera.rotation = _camera_rest_rotation


func _set_recovery_saturation(value: float) -> void:
	recovery_saturation = clampf(value, 0.0, 1.0)
	if death_grade != null and death_grade.material is ShaderMaterial:
		(death_grade.material as ShaderMaterial).set_shader_parameter(&"saturation", recovery_saturation)


func _finish_restore_transition(epoch: int) -> void:
	if epoch != _restore_epoch:
		return
	restore_transition_active = false
	_set_recovery_saturation(1.0)
	restore_feedback_completed.emit(epoch)


func _kill_damage_tween() -> void:
	if _damage_tween != null and _damage_tween.is_valid():
		_damage_tween.kill()
	_damage_tween = null
	_restore_camera_rest()


func _kill_death_tween() -> void:
	if _death_tween != null and _death_tween.is_valid():
		_death_tween.kill()
	_death_tween = null


func _mcp_state() -> Dictionary:
	return snapshot()
