class_name VictorySequence
extends CanvasLayer


signal sequence_started
signal camera_reveal_complete

const FONT := preload("res://systems/actors/humanoid/fonts/BarlowCondensed-SemiBold.ttf")

@export var pullback_seconds := 1.15
@export var orbit_seconds := 1.65
@export var rear_distance := 3.4
@export var reveal_distance := 2.85

var _camera: Camera3D
var _avatar: EnemyHumanoidActor
var _start_transform: Transform3D
var _rear_position: Vector3
var _reveal_center: Vector3
var _headline: Label
var _summary: Label
var _accent: ColorRect
var _sequence_tween: Tween


func _ready() -> void:
	_build_overlay()


func begin(camera: Camera3D, avatar: EnemyHumanoidActor, summary := "MISSION COMPLETE") -> bool:
	if camera == null or avatar == null:
		push_error("VictorySequence requires a Camera3D and player avatar")
		return false
	_camera = camera
	_avatar = avatar
	_avatar.visible = true
	_avatar.set_weapon_visible(false)
	if not _avatar.play_animation_clip("ual1", "Dance", true):
		return false
	_summary.text = summary
	_start_transform = _camera.global_transform
	_reveal_center = _avatar.global_position + Vector3(0.0, 1.05, 0.0)
	_rear_position = _avatar.global_position + _avatar.global_basis * Vector3(0.0, 1.45, -rear_distance)
	sequence_started.emit()
	_sequence_tween = create_tween()
	_sequence_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_sequence_tween.tween_method(_pull_camera_back, 0.0, 1.0, pullback_seconds)
	_sequence_tween.tween_method(_orbit_camera, 0.0, 1.0, orbit_seconds)
	_sequence_tween.parallel().tween_method(_reveal_overlay, 0.0, 1.0, orbit_seconds)
	_sequence_tween.tween_callback(camera_reveal_complete.emit)
	return true


func reset_sequence(restore_camera := true) -> void:
	if _sequence_tween != null and _sequence_tween.is_valid():
		_sequence_tween.kill()
	_sequence_tween = null
	if restore_camera and _camera != null:
		_camera.global_transform = _start_transform
	if _avatar != null:
		_avatar.visible = false
	_headline.modulate.a = 0.0
	_summary.modulate.a = 0.0
	_accent.color.a = 0.0
	_camera = null
	_avatar = null


func _pull_camera_back(weight: float) -> void:
	var position := _safe_camera_position(_start_transform.origin.lerp(_rear_position, weight))
	_camera.global_transform = _look_transform(position)


func _orbit_camera(weight: float) -> void:
	var rear_angle := -PI * 0.5
	var front_angle := PI * 0.42
	var angle := lerpf(rear_angle, front_angle, weight)
	var radius := lerpf(rear_distance, reveal_distance, weight)
	var position := _safe_camera_position(_avatar.global_position + Vector3(cos(angle) * radius, 1.32, sin(angle) * radius))
	_camera.global_transform = _look_transform(position)


func _safe_camera_position(desired: Vector3) -> Vector3:
	if _camera == null or _avatar == null:
		return desired
	var excluded: Array[RID] = []
	var player := get_tree().get_first_node_in_group(&"player")
	if player is CollisionObject3D:
		excluded.append((player as CollisionObject3D).get_rid())
	var query := PhysicsRayQueryParameters3D.create(_reveal_center, desired, 0xFFFFFFFF, excluded)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := _camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return desired
	var hit_position: Vector3 = hit.get("position", desired)
	return hit_position.move_toward(_reveal_center, 0.38)


func _look_transform(position: Vector3) -> Transform3D:
	return Transform3D(Basis.IDENTITY, position).looking_at(_reveal_center, Vector3.UP)


func _reveal_overlay(weight: float) -> void:
	_headline.modulate.a = weight
	_summary.modulate.a = weight
	_accent.color.a = weight * 0.9


func _build_overlay() -> void:
	_headline = Label.new()
	_headline.text = "VICTORY"
	_headline.position = Vector2(0, 30)
	_headline.size = Vector2(1280, 72)
	_headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_headline.add_theme_font_override("font", FONT)
	_headline.add_theme_font_size_override("font_size", 54)
	_headline.add_theme_color_override("font_color", Color("eefaff"))
	_headline.modulate.a = 0.0
	add_child(_headline)
	_summary = Label.new()
	_summary.position = Vector2(0, 91)
	_summary.size = Vector2(1280, 34)
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary.add_theme_font_override("font", FONT)
	_summary.add_theme_font_size_override("font_size", 20)
	_summary.add_theme_color_override("font_color", Color("58d8ff"))
	_summary.modulate.a = 0.0
	add_child(_summary)
	_accent = ColorRect.new()
	_accent.position = Vector2(540, 130)
	_accent.size = Vector2(200, 2)
	_accent.color = Color(0.22, 0.78, 1.0, 0.0)
	add_child(_accent)
