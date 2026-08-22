class_name FPSViewmodelSwitcher
extends Node3D

signal aiming_changed(enabled: bool)
signal clip_changed(alias: StringName)
signal weapon_switch_started(from_id: StringName, to_id: StringName)
signal weapon_changed(weapon_id: StringName, weapon_index: int)

@export_group("Weapons")
@export var weapon_profiles: Array[FPSViewmodelProfile] = []
@export var starting_weapon_index := 0

@export_group("Input")
@export var handle_right_mouse := true
@export var handle_mouse_wheel := true
@export var wheel_up_selects_previous := true
@export_node_path("CanvasItem") var hip_reticle_path: NodePath

@export_group("Switch transition")
@export_range(0.0, 0.5, 0.01) var switch_out_seconds := 0.12
@export_range(0.0, 0.5, 0.01) var switch_in_seconds := 0.16
@export_range(0.0, 0.5, 0.01) var switch_lower_distance := 0.16
@export_range(0.1, 1.0, 0.01) var switch_scale_factor := 0.88

@onready var source_axis_adapter: Node3D = $SourceAxisAdapter
@onready var model_mount: Node3D = $SourceAxisAdapter/ModelMount

var camera: Camera3D
var animation_player: AnimationPlayer
var model_root: Node3D
var reticle: CanvasItem
var current_clip := &"idle"
var current_weapon_index := -1
var aiming := false
var switching := false
var _hip_near := 0.01
var _aim_tween: Tween
var _switch_tween: Tween


func _ready() -> void:
	camera = get_parent() as Camera3D
	if camera == null:
		push_error("FPSViewmodelSwitcher must be instanced directly under a Camera3D")
		set_process_unhandled_input(false)
		return
	_hip_near = camera.near
	reticle = get_node_or_null(hip_reticle_path) as CanvasItem if not hip_reticle_path.is_empty() else null
	if weapon_profiles.is_empty():
		push_error("FPSViewmodelSwitcher requires at least one weapon profile")
		return
	equip_weapon(clampi(starting_weapon_index, 0, weapon_profiles.size() - 1), false, true)


func _unhandled_input(event: InputEvent) -> void:
	if event is not InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if handle_right_mouse and mouse_event.button_index == MOUSE_BUTTON_RIGHT:
		set_aiming(mouse_event.pressed)
		return
	if not handle_mouse_wheel or not mouse_event.pressed or switching or weapon_profiles.size() < 2:
		return
	if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
		cycle_weapon(-1 if wheel_up_selects_previous else 1)
	elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		cycle_weapon(1 if wheel_up_selects_previous else -1)


func current_profile() -> FPSViewmodelProfile:
	if current_weapon_index < 0 or current_weapon_index >= weapon_profiles.size():
		return null
	return weapon_profiles[current_weapon_index]


func current_weapon_id() -> StringName:
	var profile := current_profile()
	return profile.weapon_id if profile != null else &""


func weapon_count() -> int:
	return weapon_profiles.size()


func cycle_weapon(direction: int) -> bool:
	if switching or weapon_profiles.size() < 2 or direction == 0:
		return false
	var next_index := posmod(current_weapon_index + signi(direction), weapon_profiles.size())
	return equip_weapon(next_index)


func equip_weapon_id(weapon_id: StringName, immediate := false) -> bool:
	for index: int in weapon_profiles.size():
		if weapon_profiles[index] != null and weapon_profiles[index].weapon_id == weapon_id:
			return equip_weapon(index, true, immediate)
	return false


func equip_weapon(index: int, play_draw := true, immediate := false) -> bool:
	if switching or index < 0 or index >= weapon_profiles.size():
		return false
	var profile := weapon_profiles[index]
	if profile == null or profile.model_scene == null:
		return false
	if index == current_weapon_index and model_root != null:
		return true
	var from_id := current_weapon_id()
	weapon_switch_started.emit(from_id, profile.weapon_id)
	set_aiming(false, true)
	if immediate or model_root == null or switch_out_seconds <= 0.0:
		_replace_model(index, play_draw, immediate)
		return true
	switching = true
	_kill_switch_tween()
	var lowered_position := position + Vector3(0.0, -switch_lower_distance, 0.0)
	var lowered_scale := scale * switch_scale_factor
	_switch_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_switch_tween.tween_property(self, "position", lowered_position, switch_out_seconds)
	_switch_tween.tween_property(self, "scale", lowered_scale, switch_out_seconds)
	_switch_tween.chain().tween_callback(_replace_model.bind(index, play_draw, false))
	return true


func animation_for(alias: StringName) -> StringName:
	var profile := current_profile()
	return profile.animation_for(alias) if profile != null else &""


func play_clip(alias: StringName, restart := true) -> bool:
	if animation_player == null:
		return false
	var animation_name := animation_for(alias)
	if animation_name.is_empty() or not animation_player.has_animation(animation_name):
		return false
	current_clip = alias
	if restart:
		animation_player.stop()
	animation_player.play(animation_name)
	clip_changed.emit(alias)
	return true


func set_aiming(enabled: bool, immediate := false) -> void:
	if camera == null or switching and enabled:
		return
	var profile := current_profile()
	if profile == null:
		return
	aiming = enabled
	var target_position := profile.aim_position if enabled else profile.hip_position
	var target_scale := profile.aim_scale if enabled else profile.hip_scale
	var target_near := profile.aim_near if enabled else _hip_near
	var target_reticle_alpha := 0.0 if enabled else 1.0
	if _aim_tween != null and _aim_tween.is_valid():
		_aim_tween.kill()
	if immediate:
		position = target_position
		scale = target_scale
		camera.near = target_near
		if reticle != null:
			reticle.modulate.a = target_reticle_alpha
		aiming_changed.emit(enabled)
		return
	_aim_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_aim_tween.tween_property(self, "position", target_position, profile.aim_transition_seconds)
	_aim_tween.tween_property(self, "scale", target_scale, profile.aim_transition_seconds)
	_aim_tween.tween_property(camera, "near", target_near, profile.aim_transition_seconds)
	if reticle != null:
		_aim_tween.tween_property(reticle, "modulate:a", target_reticle_alpha, profile.aim_transition_seconds * 0.7)
	_aim_tween.chain().tween_callback(aiming_changed.emit.bind(enabled))


func _replace_model(index: int, play_draw: bool, immediate: bool) -> void:
	if model_root != null:
		model_mount.remove_child(model_root)
		model_root.queue_free()
		model_root = null
	var profile := weapon_profiles[index]
	current_weapon_index = index
	source_axis_adapter.rotation_degrees = profile.source_rotation_degrees
	model_root = profile.model_scene.instantiate() as Node3D
	if model_root == null:
		push_error("Weapon profile %s did not instantiate a Node3D" % profile.weapon_id)
		switching = false
		return
	model_root.name = "ActiveWeaponModel"
	model_mount.add_child(model_root)
	# Restore the intact coupled source at the wrapper boundary. Imported gun,
	# hands, skeleton, library, clips, and sockets remain unedited descendants.
	source_axis_adapter.visible = true
	model_mount.visible = true
	model_root.visible = true
	animation_player = _first_animation_player(model_root)
	if animation_player == null:
		push_error("Weapon profile %s has no AnimationPlayer" % profile.weapon_id)
		switching = false
		return
	for alias: StringName in [&"idle", &"walk", &"run"]:
		var animation_name := profile.animation_for(alias)
		if not animation_name.is_empty() and animation_player.has_animation(animation_name):
			animation_player.get_animation(animation_name).loop_mode = Animation.LOOP_LINEAR
	position = profile.hip_position + Vector3(0.0, -switch_lower_distance, 0.0)
	scale = profile.hip_scale * switch_scale_factor
	current_clip = &"idle"
	var draw_duration := 0.0
	if play_draw and play_clip(&"draw"):
		var draw_name := profile.animation_for(&"draw")
		draw_duration = animation_player.get_animation(draw_name).length
	elif play_draw:
		play_clip(&"idle")
	elif not play_draw:
		play_clip(&"idle")
	if immediate or switch_in_seconds <= 0.0:
		position = profile.hip_position
		scale = profile.hip_scale
		_finish_switch()
		return
	_kill_switch_tween()
	_switch_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_switch_tween.tween_property(self, "position", profile.hip_position, switch_in_seconds)
	_switch_tween.tween_property(self, "scale", profile.hip_scale, switch_in_seconds)
	if draw_duration > switch_in_seconds:
		_switch_tween.chain().tween_interval(draw_duration - switch_in_seconds)
	_switch_tween.chain().tween_callback(_finish_switch)


func _finish_switch() -> void:
	if current_clip == &"draw":
		play_clip(&"idle")
	switching = false
	weapon_changed.emit(current_weapon_id(), current_weapon_index)


func _kill_switch_tween() -> void:
	if _switch_tween != null and _switch_tween.is_valid():
		_switch_tween.kill()


func _first_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child: Node in root.get_children():
		var found := _first_animation_player(child)
		if found != null:
			return found
	return null


func _first_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for child: Node in root.get_children():
		var found := _first_skeleton(child)
		if found != null:
			return found
	return null


func _find_bone_index(skeleton: Skeleton3D, tokens: Array[String]) -> int:
	if skeleton == null:
		return -1
	for bone_index in skeleton.get_bone_count():
		var bone_name := String(skeleton.get_bone_name(bone_index)).to_lower()
		for token in tokens:
			if token in bone_name:
				return bone_index
	return -1


func _bone_receipt(skeleton: Skeleton3D, bone_index: int) -> Dictionary:
	if skeleton == null or bone_index < 0:
		return {"bound": false, "name": "", "index": -1, "skeleton_local_position": Vector3.ZERO}
	return {
		"bound": true,
		"name": String(skeleton.get_bone_name(bone_index)),
		"index": bone_index,
		"skeleton_local_position": skeleton.get_bone_global_pose(bone_index).origin,
	}


func _runtime_rig_audit() -> Dictionary:
	var meshes: Array[Dictionary] = []
	if model_root != null:
		for node: Node in model_root.find_children("*", "MeshInstance3D", true, false):
			var mesh := node as MeshInstance3D
			meshes.append({
				"path": String(mesh.get_path()),
				"visible": mesh.is_visible_in_tree(),
				"mesh_path": mesh.mesh.resource_path if mesh.mesh != null else "",
				"skinned": mesh.skin != null,
			})
	var skeleton := _first_skeleton(model_root) if model_root != null else null
	var bone_names: Array[String] = []
	if skeleton != null:
		for bone_index in skeleton.get_bone_count():
			bone_names.append(String(skeleton.get_bone_name(bone_index)).to_lower())
	var left_hand_bound := bone_names.any(func(name: String) -> bool:
		return "hand_l" in name or "left_hand" in name
	)
	var right_hand_bound := bone_names.any(func(name: String) -> bool:
		return "hand_r" in name or "right_hand" in name
	)
	var left_hand_index := _find_bone_index(skeleton, ["hand_l", "left_hand"])
	var right_hand_index := _find_bone_index(skeleton, ["hand_r", "right_hand"])
	var rifle_index := _find_bone_index(skeleton, ["rif_"])
	var trigger_index := _find_bone_index(skeleton, ["trigger"])
	var left_hand := _bone_receipt(skeleton, left_hand_index)
	var right_hand := _bone_receipt(skeleton, right_hand_index)
	var rifle_socket := _bone_receipt(skeleton, rifle_index)
	var trigger_socket := _bone_receipt(skeleton, trigger_index)
	var alias_bindings: Dictionary = {}
	var profile := current_profile()
	for alias: StringName in [&"idle", &"draw", &"walk", &"run", &"fire", &"reload", &"reload_variant", &"empty_reload", &"inspect"]:
		var resolved := profile.animation_for(alias) if profile != null else &""
		var exists := animation_player != null and not resolved.is_empty() and animation_player.has_animation(resolved)
		alias_bindings[alias] = {
			"resolved_clip": resolved,
			"exists": exists,
			"length_seconds": animation_player.get_animation(resolved).length if exists else 0.0,
		}
	var left_position: Vector3 = left_hand.get("skeleton_local_position", Vector3.ZERO)
	var right_position: Vector3 = right_hand.get("skeleton_local_position", Vector3.ZERO)
	var rifle_position: Vector3 = rifle_socket.get("skeleton_local_position", Vector3.ZERO)
	var trigger_position: Vector3 = trigger_socket.get("skeleton_local_position", Vector3.ZERO)
	return {
		"intact_root": model_root != null and model_root.is_inside_tree(),
		"root_visible": model_root != null and model_root.is_visible_in_tree(),
		"mesh_count": meshes.size(),
		"visible_mesh_count": meshes.filter(func(item: Dictionary) -> bool: return item.get("visible", false) == true).size(),
		"skinned_mesh_count": meshes.filter(func(item: Dictionary) -> bool: return item.get("skinned", false) == true).size(),
		"mesh_sources": meshes,
		"skeleton_path": String(skeleton.get_path()) if skeleton != null else "",
		"bone_count": skeleton.get_bone_count() if skeleton != null else 0,
		"left_hand_bound": left_hand_bound,
		"right_hand_bound": right_hand_bound,
		"both_hands_bound": left_hand_bound and right_hand_bound,
		"bone_bindings": {
			"left_hand": left_hand,
			"right_hand": right_hand,
			"rifle_socket": rifle_socket,
			"trigger_socket": trigger_socket,
		},
		"contact_measurements": {
			"left_hand_to_rifle_socket_m": left_position.distance_to(rifle_position) if left_hand_index >= 0 and rifle_index >= 0 else -1.0,
			"right_hand_to_trigger_socket_m": right_position.distance_to(trigger_position) if right_hand_index >= 0 and trigger_index >= 0 else -1.0,
			"measurement_space": &"source_skeleton_local",
			"visual_acceptance_required": true,
		},
		"animation_player_path": String(animation_player.get_path()) if animation_player != null else "",
		"animation_count": animation_player.get_animation_list().size() if animation_player != null else 0,
		"semantic_aliases": alias_bindings,
		"required_aliases_available": profile != null and profile.required_animations_available(animation_player),
	}


func _mcp_state() -> Dictionary:
	var profile := current_profile()
	return {
		"weapon_id": current_weapon_id(),
		"current_clip": current_clip,
		"animation_name": animation_player.current_animation if animation_player != null else &"",
		"resolved_current_clip": animation_for(current_clip),
		"animation_position_seconds": animation_player.current_animation_position if animation_player != null else 0.0,
		"aiming": aiming,
		"switching": switching,
		"hip_position": profile.hip_position if profile != null else Vector3.ZERO,
		"aim_position": profile.aim_position if profile != null else Vector3.ZERO,
		"wrapper_transform": transform,
		"source_axis_adapter_transform": source_axis_adapter.transform,
		"model_mount_transform": model_mount.transform,
		"camera_near": camera.near if camera != null else 0.0,
		"runtime_rig": _runtime_rig_audit(),
	}
