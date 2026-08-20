class_name FPSViewmodelProfile
extends Resource

@export_group("Identity")
@export var weapon_id: StringName = &"weapon"
@export var display_name := "Weapon"

@export_group("Model")
@export var model_scene: PackedScene
@export var source_rotation_degrees := Vector3(0.0, 180.0, 0.0)

@export_group("Framing")
@export var hip_position := Vector3(0.10, -0.23, 0.015)
@export var aim_position := Vector3(-0.035, -0.135, 0.03)
@export var hip_scale := Vector3(0.36, 0.36, 0.36)
@export var aim_scale := Vector3(0.36, 0.36, 0.36)
@export_range(0.01, 0.5, 0.01) var aim_near := 0.10
@export_range(0.01, 1.0, 0.01) var aim_transition_seconds := 0.16

@export_group("Reload framing")
@export var reload_mount_offset := Vector3.ZERO

@export_group("Animation mapping")
@export var idle_animation: StringName
@export var draw_animation: StringName
@export var hide_animation: StringName
@export var walk_animation: StringName
@export var run_animation: StringName
@export var fire_animation: StringName
@export var reload_animation: StringName
@export var reload_variant_animation: StringName
@export var empty_reload_animation: StringName
@export var inspect_animation: StringName


func animation_for(alias: StringName) -> StringName:
	match alias:
		&"idle": return idle_animation
		&"draw": return draw_animation
		&"hide": return hide_animation
		&"walk": return walk_animation
		&"run": return run_animation
		&"fire": return fire_animation
		&"reload": return reload_animation
		&"reload_variant": return reload_variant_animation
		&"empty_reload": return empty_reload_animation
		&"inspect": return inspect_animation
		_: return &""


func required_animations_available(player: AnimationPlayer) -> bool:
	if player == null:
		return false
	for alias: StringName in [&"idle", &"walk", &"run", &"fire", &"reload"]:
		var animation_name := animation_for(alias)
		if animation_name.is_empty() or not player.has_animation(animation_name):
			return false
	return true
