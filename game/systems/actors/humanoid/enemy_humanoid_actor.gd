class_name EnemyHumanoidActor
extends Node3D


signal state_changed(state_name: String)
signal skin_changed(skin_id: String, binding_report: Dictionary)

enum MotionState {
	IDLE,
	WALK,
	RUN,
	CROUCH_IDLE,
	CROUCH_MOVE,
	JUMP_START,
	AIRBORNE,
	LAND,
	AIM,
	FIRE,
	RELOAD,
	HIT,
	DEATH,
}

const UAL1_SCENE := preload("res://systems/actors/humanoid/assets/animations/ual1_standard.glb")
const UAL2_SCENE := preload("res://systems/actors/humanoid/assets/animations/ual2_standard.glb")
const PRIMARY_RIFLE_SCENE := preload("res://systems/actors/humanoid/assets/weapons/primary_rifle/m4_rifle.glb")
const WEAPON_FAMILY := &"rifle"
const RIFLE_FIRE_SECONDS := 0.18
const RIFLE_RELOAD_SECONDS := 1.65
const RIFLE_SOURCE_GRIP_OFFSET := Vector3(0.0, 2.0, 5.0)
const RIFLE_MUZZLE_LOCAL := Vector3(0.0, 5.4, 13.85)
const RIFLE_SUPPORT_HAND_FORWARD_RATIO := 0.42
const RIFLE_SOCKET_POSITION := Vector3(0.02, 0.04, -0.02)
const RIFLE_SOCKET_LOW_READY_ROTATION := Vector3(-8.0, 90.0, 0.0)
const RIFLE_SOCKET_SHOULDER_ROTATION := Vector3(-10.0, 90.0, 0.0)
const RIFLE_SOCKET_RELOAD_ROTATION := Vector3(-10.0, 90.0, 0.0)
const AUTHORED_RIFLE_SOURCE_CLIPS_AVAILABLE := false
const SKINS := {
	"soldier_a": {
		"label": "Mixamo Soldier A (68 bones)",
		"scene": preload("res://systems/actors/humanoid/assets/skins/soldier_a.glb"),
		"scale": 0.01,
		"attach_weapon": true,
	},
	"soldier_b": {
		"label": "Mixamo Soldier B (58 bones)",
		"scene": preload("res://systems/actors/humanoid/assets/skins/soldier_b.glb"),
		"scale": 1.0,
		"attach_weapon": true,
	},
}
const STATE_CLIPS := {
	# Restored from the accepted component baseline: the UAL pack names these
	# combat poses as pistol states, but the component ships them with the M4
	# right-hand socket. Telemetry reports the missing authored rifle set instead
	# of relabeling these source clips as genuine rifle animations.
	MotionState.IDLE: {"library": "ual1", "clip": "Pistol_Idle", "loop": true},
	MotionState.WALK: {"library": "ual1", "clip": "Walk", "loop": true},
	MotionState.RUN: {"library": "ual1", "clip": "Jog_Fwd", "loop": true},
	MotionState.CROUCH_IDLE: {"library": "ual1", "clip": "Crouch_Idle", "loop": true},
	MotionState.CROUCH_MOVE: {"library": "ual1", "clip": "Crouch_Fwd", "loop": true},
	MotionState.JUMP_START: {"library": "ual1", "clip": "Jump_Start", "loop": false},
	MotionState.AIRBORNE: {"library": "ual1", "clip": "Jump", "loop": true},
	MotionState.LAND: {"library": "ual1", "clip": "Jump_Land", "loop": false},
	MotionState.AIM: {"library": "ual1", "clip": "Pistol_Aim_Neutral", "loop": true},
	MotionState.FIRE: {"library": "ual1", "clip": "Pistol_Shoot", "loop": false},
	MotionState.RELOAD: {"library": "ual1", "clip": "Pistol_Reload", "loop": false},
	# A regular bullet hit should read as a short flinch, not a full-body
	# knockback. Hit_Head gives the requested small head snap while preserving
	# the actor's planted combat stance.
	MotionState.HIT: {"library": "ual1", "clip": "Hit_Head", "loop": false},
	MotionState.DEATH: {"library": "ual1", "clip": "Death01", "loop": false},
}

@export_enum("soldier_a", "soldier_b") var initial_skin := "soldier_a"
@export var initial_state := MotionState.IDLE
@export var playback_speed := 1.0
@export_range(0.0, 0.5, 0.01) var transition_blend_seconds := 0.12
@export_range(0.1, 10.0, 0.1) var walk_reference_speed_mps := 1.7
@export_range(0.1, 15.0, 0.1) var run_reference_speed_mps := 3.5
@export_range(0.1, 8.0, 0.1) var crouch_reference_speed_mps := 1.1
@export var equip_weapon := true
@export var ground_contact_height := 0.075

var current_skin_id := ""
var current_state := MotionState.IDLE
var binding_report: Dictionary = {}

var _model_holder: Node3D
var _source_holder: Node3D
var _skin_instance: Node3D
var _target_skeleton: Skeleton3D
var _source_instances: Dictionary = {}
var _source_skeletons: Dictionary = {}
var _source_players: Dictionary = {}
var _retargeter := RuntimeHumanoidRetargeter.new()
var _active_library := "ual1"
var _one_shot_return_state := MotionState.IDLE
var _custom_preview := false
var _custom_clip := ""
var _custom_loop := false
var _weapon_attachment: BoneAttachment3D
var _weapon_root: Node3D
var _weapon_source: Node3D
var _muzzle_marker: Marker3D
var _locomotion_playback_scale := 1.0
var _state_change_count := 0
var _aim_pitch_degrees := 0.0
var _aim_pitch_serial := 0
var _rifle_action_elapsed := 0.0
var _rifle_action_duration := 0.0


func _ready() -> void:
	_build_holders()
	_build_animation_sources()
	set_skin(initial_skin)
	set_motion_state(initial_state, true)
	set_process(true)


func _process(delta: float) -> void:
	var player: AnimationPlayer = _source_players.get(_active_library)
	if player == null:
		return
	player.advance(delta * playback_speed * _locomotion_playback_scale)
	if current_state in [MotionState.FIRE, MotionState.RELOAD]:
		_rifle_action_elapsed += delta
		if _rifle_action_elapsed >= _rifle_action_duration:
			set_motion_state(_one_shot_return_state, true)
			return
	_apply_pose_and_ground()
	if _custom_preview:
		if _custom_loop and not player.is_playing():
			player.play(StringName(_custom_clip))
			player.advance(0.0)
		return
	if STATE_CLIPS[current_state]["loop"] == true and not player.is_playing():
		player.play(StringName(STATE_CLIPS[current_state]["clip"]))
		player.advance(0.0)
	elif STATE_CLIPS[current_state]["loop"] != true and not player.is_playing():
		if current_state == MotionState.DEATH:
			player.seek(player.current_animation_length, true)
			_apply_pose_and_ground()
		else:
			set_motion_state(_one_shot_return_state, true)


func set_skin(skin_id: String) -> bool:
	if not SKINS.has(skin_id):
		push_warning("Unknown enemy skin: %s" % skin_id)
		return false
	if _model_holder == null:
		_build_holders()
	if _skin_instance != null:
		_skin_instance.queue_free()
		_skin_instance = null
	var skin_data: Dictionary = SKINS[skin_id]
	_skin_instance = (skin_data["scene"] as PackedScene).instantiate() as Node3D
	_skin_instance.name = "ActiveSkin"
	_skin_instance.scale = Vector3.ONE * float(skin_data["scale"])
	_model_holder.add_child(_skin_instance)
	_target_skeleton = HumanoidBoneMapper.find_skeleton(_skin_instance)
	if _target_skeleton == null:
		push_error("Skin %s has no Skeleton3D and cannot be retargeted" % skin_id)
		return false
	current_skin_id = skin_id
	_refresh_binding_report(_source_skeletons[_active_library])
	if not binding_report["accepted"]:
		push_error("Skin %s lacks required humanoid bones: %s" % [skin_id, binding_report["target"]["missing"]])
		return false
	if equip_weapon and skin_data.get("attach_weapon", true) == true:
		_attach_weapon()
	skin_changed.emit(skin_id, binding_report)
	return true


func set_custom_skin(scene: PackedScene, skin_id := "custom", model_scale := 1.0, allow_experimental_rig := false) -> bool:
	if scene == null:
		return false
	if _skin_instance != null:
		_skin_instance.queue_free()
	_skin_instance = scene.instantiate() as Node3D
	_skin_instance.name = "ActiveSkin"
	_skin_instance.scale = Vector3.ONE * model_scale
	_model_holder.add_child(_skin_instance)
	_target_skeleton = HumanoidBoneMapper.find_skeleton(_skin_instance)
	if _target_skeleton == null:
		push_error("Custom skin has no Skeleton3D")
		return false
	current_skin_id = skin_id
	_refresh_binding_report(_source_skeletons[_active_library], allow_experimental_rig)
	if binding_report["accepted"] and equip_weapon:
		_attach_weapon()
	skin_changed.emit(skin_id, binding_report)
	return binding_report["accepted"]


func _binding_is_accepted(report: Dictionary, allow_experimental_rig := false) -> bool:
	var target: Dictionary = report["target"]
	var family := String(target["rig_family"])
	var family_supported := family in ["mixamo", "quaternius_ual1", "quaternius_ual2"]
	return (
		float(target["coverage"]) >= 0.82
		and target["rest_pose"]["neutral_leg_stance"] == true
		and (family_supported or allow_experimental_rig)
	)


func _refresh_binding_report(source_skeleton: Skeleton3D, allow_experimental_rig := false) -> void:
	binding_report = _retargeter.configure(source_skeleton, _target_skeleton)
	binding_report["skin_id"] = current_skin_id
	binding_report["accepted"] = _binding_is_accepted(binding_report, allow_experimental_rig)


func set_motion_state(next_state: MotionState, immediate := false, restart := false) -> void:
	if not STATE_CLIPS.has(next_state):
		return
	if current_state == MotionState.DEATH and next_state != MotionState.DEATH and not immediate:
		return
	# Locomotion controllers legitimately submit the same semantic state every
	# physics frame. Replaying the clip here would pin Walk/Jog/Crouch to frame 0
	# and make a moving actor look frozen or slide across the floor.
	if next_state == current_state and not immediate and not restart and not _custom_preview:
		return
	if next_state == MotionState.JUMP_START:
		_one_shot_return_state = MotionState.AIRBORNE
	elif next_state == MotionState.LAND:
		_one_shot_return_state = MotionState.IDLE
	elif next_state == MotionState.FIRE or next_state == MotionState.RELOAD or next_state == MotionState.HIT:
		_one_shot_return_state = MotionState.AIM if current_state == MotionState.AIM else MotionState.IDLE
	var previous_library := _active_library
	current_state = next_state
	_rifle_action_elapsed = 0.0
	_rifle_action_duration = (
		RIFLE_FIRE_SECONDS if next_state == MotionState.FIRE
		else RIFLE_RELOAD_SECONDS if next_state == MotionState.RELOAD
		else 0.0
	)
	_custom_preview = false
	_custom_clip = ""
	_locomotion_playback_scale = 1.0
	var clip_data: Dictionary = STATE_CLIPS[next_state]
	_active_library = String(clip_data["library"])
	var source_skeleton: Skeleton3D = _source_skeletons[_active_library]
	_refresh_binding_report(source_skeleton)
	var player: AnimationPlayer = _source_players[_active_library]
	if previous_library != _active_library:
		var previous_player: AnimationPlayer = _source_players.get(previous_library)
		if previous_player != null:
			previous_player.stop()
	var blend_seconds := 0.0 if immediate or previous_library != _active_library else transition_blend_seconds
	player.play(StringName(clip_data["clip"]), blend_seconds)
	player.advance(0.0)
	_apply_pose_and_ground()
	_state_change_count += 1
	state_changed.emit(state_name())


func idle() -> void:
	set_motion_state(MotionState.IDLE)


func walk() -> void:
	set_motion_state(MotionState.WALK)


func run() -> void:
	set_motion_state(MotionState.RUN)


func crouch_idle() -> void:
	set_motion_state(MotionState.CROUCH_IDLE)


func crouch_move() -> void:
	set_motion_state(MotionState.CROUCH_MOVE)


func jump() -> void:
	set_motion_state(MotionState.JUMP_START)


func fall() -> void:
	set_motion_state(MotionState.AIRBORNE)


func land() -> void:
	set_motion_state(MotionState.LAND)


func aim() -> void:
	set_motion_state(MotionState.AIM)


func fire() -> void:
	set_motion_state(MotionState.FIRE)


func reload() -> void:
	set_motion_state(MotionState.RELOAD)


func reload_for(authoritative_seconds: float) -> void:
	# Magazine authority owns the presentation lifetime. Imported pose/clip data
	# remains untouched; the product adapter keeps the reload semantic active
	# until the combat controller's bounded reload window completes.
	set_motion_state(MotionState.RELOAD, false, true)
	_rifle_action_duration = maxf(authoritative_seconds, 0.05)


func set_locomotion_state(state: StringName) -> void:
	match state:
		&"idle": idle()
		&"walk": walk()
		&"run": run()
		&"crouch_idle": crouch_idle()
		&"crouch_move": crouch_move()
		&"jump": jump()
		&"fall": fall()
		&"land": land()


func set_locomotion_speed(horizontal_speed_mps: float) -> void:
	var reference_speed := 0.0
	match current_state:
		MotionState.WALK: reference_speed = walk_reference_speed_mps
		MotionState.RUN: reference_speed = run_reference_speed_mps
		MotionState.CROUCH_MOVE: reference_speed = crouch_reference_speed_mps
		_: _locomotion_playback_scale = 1.0
	if reference_speed > 0.0:
		_locomotion_playback_scale = clampf(horizontal_speed_mps / reference_speed, 0.65, 1.5)


func take_hit() -> void:
	if current_state != MotionState.DEATH:
		set_motion_state(MotionState.HIT, false, true)


func die() -> void:
	set_motion_state(MotionState.DEATH)


func reset_enemy() -> void:
	set_aim_pitch(0.0)
	set_motion_state(MotionState.IDLE, true)


func play_animation_clip(library_id: String, clip_name: String, force_loop := false) -> bool:
	if not _source_players.has(library_id):
		push_warning("Unknown animation library: %s" % library_id)
		return false
	var player: AnimationPlayer = _source_players[library_id]
	if not player.has_animation(StringName(clip_name)):
		push_warning("Animation %s/%s is unavailable" % [library_id, clip_name])
		return false
	_active_library = library_id
	_custom_preview = true
	_custom_clip = clip_name
	_custom_loop = force_loop
	_refresh_binding_report(_source_skeletons[_active_library])
	player.stop()
	player.play(StringName(clip_name))
	player.advance(0.0)
	_apply_pose_and_ground()
	state_changed.emit("preview:%s/%s" % [library_id, clip_name])
	return true


func animation_catalog() -> Array[Dictionary]:
	var catalog: Array[Dictionary] = []
	for library_id in ["ual1", "ual2"]:
		var player: AnimationPlayer = _source_players.get(library_id)
		if player == null:
			continue
		for clip_name in player.get_animation_list():
			var animation := player.get_animation(clip_name)
			catalog.append({
				"library": library_id,
				"clip": String(clip_name),
				"length_seconds": animation.length,
				"loop_mode": _loop_mode_name(animation.loop_mode),
			})
	return catalog


func _loop_mode_name(loop_mode: int) -> String:
	match loop_mode:
		Animation.LOOP_LINEAR:
			return "linear"
		Animation.LOOP_PINGPONG:
			return "pingpong"
		_:
			return "none"


func set_weapon_visible(is_visible: bool) -> void:
	if _weapon_attachment != null:
		_weapon_attachment.visible = is_visible


func state_name() -> String:
	return MotionState.keys()[current_state].to_lower()


func _hips_translation_mode() -> String:
	if _custom_preview:
		return "full"
	if current_state in [MotionState.WALK, MotionState.RUN, MotionState.CROUCH_IDLE, MotionState.CROUCH_MOVE]:
		return "vertical"
	if current_state in [MotionState.JUMP_START, MotionState.AIRBORNE, MotionState.LAND, MotionState.HIT, MotionState.DEATH]:
		return "full"
	return "none"


func _apply_pose_and_ground() -> void:
	_retargeter.apply_pose(_hips_translation_mode())
	_apply_rifle_aim_overlay()
	_apply_rifle_action_overlay()
	_apply_weapon_pose_for_state()
	_sync_weapon_attachment()
	_apply_rifle_contact_overlay()
	_sync_weapon_attachment()
	_apply_ground_contact()


func set_aim_pitch(pitch_degrees: float) -> void:
	var clamped_pitch := clampf(pitch_degrees, -50.0, 50.0)
	if not is_equal_approx(clamped_pitch, _aim_pitch_degrees):
		_aim_pitch_serial += 1
	_aim_pitch_degrees = clamped_pitch


func _apply_rifle_aim_overlay() -> void:
	if _target_skeleton == null or current_state not in [MotionState.IDLE, MotionState.AIM, MotionState.FIRE, MotionState.RELOAD, MotionState.WALK, MotionState.RUN]:
		return
	var mapping := HumanoidBoneMapper.build_map(_target_skeleton)
	var pitch_radians := deg_to_rad(_aim_pitch_degrees)
	var ready_weight := 0.62 if current_state in [MotionState.IDLE, MotionState.WALK, MotionState.RUN] else 1.0
	for overlay in [
		{"bone": "spine_mid", "weight": 0.18},
		{"bone": "chest", "weight": 0.34},
		{"bone": "right_shoulder", "weight": 0.20},
		{"bone": "left_shoulder", "weight": 0.20},
	]:
		var canonical := String(overlay["bone"])
		if not mapping.has(canonical):
			continue
		var bone_index: int = mapping[canonical]
		var base_rotation := _target_skeleton.get_bone_pose_rotation(bone_index)
		var pitch_rotation := Quaternion(Vector3.RIGHT, pitch_radians * float(overlay["weight"]) * ready_weight)
		_target_skeleton.set_bone_pose_rotation(bone_index, base_rotation * pitch_rotation)


func _apply_rifle_action_overlay() -> void:
	if _target_skeleton == null or current_state not in [MotionState.FIRE, MotionState.RELOAD]:
		return
	var duration := maxf(_rifle_action_duration, 0.001)
	var progress := clampf(_rifle_action_elapsed / duration, 0.0, 1.0)
	var pulse := sin(progress * PI)
	var mapping := HumanoidBoneMapper.build_map(_target_skeleton)
	if current_state == MotionState.FIRE:
		_rotate_overlay_bone(mapping, "chest", Vector3.RIGHT, deg_to_rad(-3.5 * pulse))
		_rotate_overlay_bone(mapping, "right_shoulder", Vector3.UP, deg_to_rad(-2.0 * pulse))
		_rotate_overlay_bone(mapping, "left_shoulder", Vector3.UP, deg_to_rad(-1.25 * pulse))
		return
	# Break the support-hand contact toward the magazine well, then reseat it.
	# The rifle remains attached to the firing hand, so the root and muzzle stay
	# stable while the left arm performs the only reload displacement.
	var reach := sin(progress * PI)
	_rotate_overlay_bone(mapping, "left_shoulder", Vector3.FORWARD, deg_to_rad(-24.0 * reach))
	_rotate_overlay_bone(mapping, "left_upper_arm", Vector3.RIGHT, deg_to_rad(18.0 * reach))
	_rotate_overlay_bone(mapping, "left_lower_arm", Vector3.UP, deg_to_rad(32.0 * reach))
	_rotate_overlay_bone(mapping, "left_hand", Vector3.FORWARD, deg_to_rad(-38.0 * reach))
	_rotate_overlay_bone(mapping, "chest", Vector3.UP, deg_to_rad(3.5 * reach))


func _rotate_overlay_bone(mapping: Dictionary, canonical: String, axis: Vector3, angle: float) -> void:
	if not mapping.has(canonical) or is_zero_approx(angle):
		return
	var bone_index: int = mapping[canonical]
	var base_rotation := _target_skeleton.get_bone_pose_rotation(bone_index)
	_target_skeleton.set_bone_pose_rotation(bone_index, base_rotation * Quaternion(axis, angle))


func _apply_weapon_pose_for_state() -> void:
	if _weapon_root == null:
		return
	_weapon_root.position = RIFLE_SOCKET_POSITION
	match current_state:
		MotionState.AIM, MotionState.FIRE:
			_weapon_root.rotation_degrees = RIFLE_SOCKET_SHOULDER_ROTATION
		MotionState.RELOAD:
			_weapon_root.rotation_degrees = RIFLE_SOCKET_RELOAD_ROTATION
		_:
			_weapon_root.rotation_degrees = RIFLE_SOCKET_LOW_READY_ROTATION


func _apply_rifle_contact_overlay() -> void:
	if _target_skeleton == null or _muzzle_marker == null or current_state not in [MotionState.IDLE, MotionState.WALK, MotionState.RUN, MotionState.AIM, MotionState.FIRE, MotionState.RELOAD, MotionState.HIT]:
		return
	var mapping := HumanoidBoneMapper.build_map(_target_skeleton)
	if not mapping.has("left_hand") or not mapping.has("right_hand"):
		return
	_target_skeleton.force_update_all_bone_transforms()
	_apply_rifle_stock_height_overlay(mapping)
	var right_hand_world: Vector3 = _bone_world_origin("right_hand")
	var muzzle_world := _muzzle_marker.global_position
	var hand_to_muzzle := muzzle_world - right_hand_world
	if hand_to_muzzle.length() <= 0.1:
		return
	var support_target := right_hand_world.lerp(muzzle_world, RIFLE_SUPPORT_HAND_FORWARD_RATIO)
	if current_state == MotionState.RELOAD:
		var reload_reach := sin(clampf(_rifle_action_elapsed / maxf(_rifle_action_duration, 0.001), 0.0, 1.0) * PI)
		support_target = support_target.lerp(right_hand_world.lerp(muzzle_world, 0.28) + global_transform.basis.y * 0.18, reload_reach)
	var left_hand_index: int = mapping["left_hand"]
	var left_pose := _target_skeleton.get_bone_global_pose(left_hand_index)
	left_pose.origin = _target_skeleton.to_local(support_target)
	_target_skeleton.set_bone_global_pose(left_hand_index, left_pose)
	_target_skeleton.force_update_all_bone_transforms()
	_sync_weapon_attachment()


func _apply_rifle_stock_height_overlay(mapping: Dictionary) -> void:
	if current_state not in [MotionState.WALK, MotionState.RUN, MotionState.RELOAD]:
		return
	if not mapping.has("right_hand"):
		return
	_sync_weapon_attachment()
	var muzzle_height := _muzzle_marker.global_position.y - global_position.y
	var target_muzzle_height := 1.55 if current_state == MotionState.RELOAD else 1.45
	var lift := target_muzzle_height - muzzle_height
	if lift <= 0.0:
		return
	var right_hand_index: int = mapping["right_hand"]
	var right_pose := _target_skeleton.get_bone_global_pose(right_hand_index)
	var current_world: Vector3 = _target_skeleton.to_global(right_pose.origin)
	right_pose.origin = _target_skeleton.to_local(current_world + global_transform.basis.y * minf(lift, 0.95))
	_target_skeleton.set_bone_global_pose(right_hand_index, right_pose)
	_target_skeleton.force_update_all_bone_transforms()
	_sync_weapon_attachment()


func _apply_ground_contact() -> void:
	if _model_holder == null or _target_skeleton == null:
		return
	var grounding_mode := _grounding_mode()
	if grounding_mode == "none":
		_model_holder.position.y = 0.0
		return
	_model_holder.position.y = 0.0
	var mapping := HumanoidBoneMapper.build_map(_target_skeleton)
	var contact_bones := _contact_bones(grounding_mode)
	var minimum_y := INF
	for canonical in contact_bones:
		if not mapping.has(canonical):
			continue
		var pose_origin := _target_skeleton.get_bone_global_pose(mapping[canonical]).origin
		var actor_local := to_local(_target_skeleton.to_global(pose_origin))
		minimum_y = minf(minimum_y, actor_local.y)
	if is_finite(minimum_y):
		var correction := ground_contact_height - minimum_y
		if absf(correction) <= 2.5:
			_model_holder.position.y = correction


func ground_contact_report() -> Dictionary:
	var grounding_mode := _grounding_mode()
	if grounding_mode == "none" or _target_skeleton == null:
		return {"mode": grounding_mode, "applicable": false}
	var mapping := HumanoidBoneMapper.build_map(_target_skeleton)
	var minimum_y := INF
	var world_minimum_y := INF
	for canonical in _contact_bones(grounding_mode):
		if not mapping.has(canonical):
			continue
		var pose_origin := _target_skeleton.get_bone_global_pose(mapping[canonical]).origin
		var world_origin := _target_skeleton.to_global(pose_origin)
		minimum_y = minf(minimum_y, to_local(world_origin).y)
		world_minimum_y = minf(world_minimum_y, world_origin.y)
	return {
		"mode": grounding_mode,
		"applicable": is_finite(minimum_y),
		"minimum_contact_y": minimum_y,
		"world_minimum_contact_y": world_minimum_y,
		"target_contact_y": ground_contact_height,
		"absolute_error": absf(minimum_y - ground_contact_height),
	}


func _contact_bones(grounding_mode: String) -> Array[String]:
	if grounding_mode == "body":
		return [
			"hips", "spine", "spine_mid", "chest", "neck", "head",
			"left_shoulder", "left_upper_arm", "left_lower_arm", "left_hand",
			"right_shoulder", "right_upper_arm", "right_lower_arm", "right_hand",
			"left_upper_leg", "left_lower_leg", "left_foot", "left_toe",
			"right_upper_leg", "right_lower_leg", "right_foot", "right_toe",
		]
	return ["left_foot", "right_foot", "left_toe", "right_toe"]


func _grounding_mode() -> String:
	if not _custom_preview:
		if current_state == MotionState.JUMP_START or current_state == MotionState.AIRBORNE:
			return "none"
		if current_state == MotionState.HIT or current_state == MotionState.DEATH:
			return "body"
		return "feet"
	var clip_lower := _custom_clip.to_lower()
	if "jump" in clip_lower or "climb" in clip_lower or "parkour" in clip_lower:
		return "none"
	if (
		"death" in clip_lower
		or "hit" in clip_lower
		or "roll" in clip_lower
		or "slide" in clip_lower
		or "lay" in clip_lower
		or "sitting" in clip_lower
	):
		return "body"
	return "feet"


func available_skins() -> Array[String]:
	var ids: Array[String] = []
	for skin_id in SKINS:
		ids.append(skin_id)
	return ids


func skin_catalog() -> Array[Dictionary]:
	var catalog: Array[Dictionary] = []
	for skin_id in SKINS:
		var skin_data: Dictionary = SKINS[skin_id]
		catalog.append({
			"id": skin_id,
			"label": String(skin_data.get("label", skin_id)),
		})
	return catalog


func get_component_state() -> Dictionary:
	var player: AnimationPlayer = _source_players.get(_active_library)
	var animation_position := player.current_animation_position if player != null else 0.0
	var animation_length := player.current_animation_length if player != null else 0.0
	var clip_name := _custom_clip if _custom_preview else String(STATE_CLIPS[current_state]["clip"])
	var component_socket_interim := _uses_component_m4_socket_interim(clip_name)
	var pistol_source_clip := "pistol" in clip_name.to_lower()
	var incompatible_fallback := _is_incompatible_rifle_fallback(current_state, clip_name)
	var contact_report := rifle_contact_report()
	var visible_rifle_ready: bool = contact_report.get("accepted", false) == true
	var authored_rifle_clip := AUTHORED_RIFLE_SOURCE_CLIPS_AVAILABLE and not pistol_source_clip
	var family_compatible := visible_rifle_ready and authored_rifle_clip and not incompatible_fallback
	var locomotion_source_requires_overlay := current_state in [MotionState.WALK, MotionState.RUN] and clip_name in ["Walk", "Jog_Fwd"]
	var socket_contact_status := &"accepted" if contact_report.get("accepted", false) == true else StringName(contact_report.get("failure_reason", &"socket_contact_unaccepted"))
	var compatibility_disposition := _compatibility_disposition(pistol_source_clip, component_socket_interim, incompatible_fallback, family_compatible, visible_rifle_ready, locomotion_source_requires_overlay)
	return {
		"skin_id": current_skin_id,
		"state": state_name(),
		"animation_library": _active_library,
		"mode": "clip_browser" if _custom_preview else "semantic_state",
		"animation": clip_name,
		"source_animation_semantic": StringName("source_%s" % clip_name.to_snake_case()),
		"animation_semantic": _resolved_animation_semantic(),
		"rifle_semantic_procedural": false,
		"rifle_action_progress": clampf(_rifle_action_elapsed / maxf(_rifle_action_duration, 0.001), 0.0, 1.0) if _rifle_action_duration > 0.0 else 0.0,
		"rifle_action_duration_seconds": _rifle_action_duration,
		"rifle_action_elapsed_seconds": _rifle_action_elapsed,
		"reload_lifetime_authority": &"combat_magazine_window",
		"animation_position_seconds": animation_position,
		"animation_length_seconds": animation_length,
		"animation_normalized_time": clampf(animation_position / animation_length, 0.0, 1.0) if animation_length > 0.0 else 0.0,
		"animation_playing": player != null and player.is_playing(),
		"weapon_family": WEAPON_FAMILY,
		"weapon_family_compatible": family_compatible,
		"compatibility_disposition": compatibility_disposition,
		"raw_source_clip_weapon_label": &"pistol_named_component_clip" if pistol_source_clip else &"unlabeled_locomotion_or_reaction_clip",
		"genuine_authored_rifle_clip": authored_rifle_clip,
		"weapon_socket_contact_status": socket_contact_status,
		"binding_strategy": {
			"selected_strategy": &"product_wrapper_boneattachment_sync_with_component_m4_socket_stock_height_baseline",
			"rifle_ready_authored_clips_available": AUTHORED_RIFLE_SOURCE_CLIPS_AVAILABLE,
			"authored_rifle_clip_binding_status": &"missing_required_asset",
			"visible_rifle_ready_binding": visible_rifle_ready,
			"source_clip_truthful": true,
			"locomotion_source_clip_requires_overlay_proof": locomotion_source_requires_overlay,
			"interim_issue_open": not AUTHORED_RIFLE_SOURCE_CLIPS_AVAILABLE,
			"root_transform_tuning_primary_fix": false,
			"bone_attachment_pose_synced_before_contact_receipts": true,
			"live_stock_height_overlay_before_foregrip_receipts": true,
			"actor_root_dynamic_axes": ["yaw"],
			"model_axis_adapter_fixed": true,
			"pistol_source_clip_rejected": pistol_source_clip and not component_socket_interim,
			"pistol_source_clip_truthfully_reported": pistol_source_clip,
			"incompatible_source_clip_rejected": incompatible_fallback,
			"adapter_mapping": &"component_api_idle_walk_run_aim_fire_reload_hit_death",
		},
		"rifle_contact": contact_report,
		"aim_pitch_degrees": _aim_pitch_degrees,
		"aim_pitch_serial": _aim_pitch_serial,
		"presentation_adapter_rotation_degrees": rotation_degrees,
		"presentation_adapter_upright": absf(rotation.x) <= 0.001 and absf(rotation.z) <= 0.001,
		"transform_authority": {
			"navigation_root_dynamic_axes": ["yaw"],
			"source_axis_adapter_fixed": true,
			"vertical_aim_layer": &"presentation_upper_body",
		},
		"socket_bound": _weapon_attachment != null,
		"weapon_socket_bound": _weapon_attachment != null,
		"socket_bone": String(_weapon_attachment.bone_name) if _weapon_attachment != null else "",
		"weapon_attached": _weapon_attachment != null and _weapon_attachment.get_node_or_null("PrimaryRifle") != null,
		"locomotion_playback_scale": _locomotion_playback_scale,
		"state_change_count": _state_change_count,
		"binding": binding_report,
	}


func _uses_component_m4_socket_interim(clip_name: String) -> bool:
	if AUTHORED_RIFLE_SOURCE_CLIPS_AVAILABLE:
		return false
	if current_state not in [MotionState.IDLE, MotionState.AIM, MotionState.FIRE, MotionState.RELOAD]:
		return false
	return clip_name in ["Pistol_Idle", "Pistol_Aim_Neutral", "Pistol_Shoot", "Pistol_Reload"]


func _compatibility_disposition(
	pistol_source_clip: bool,
	component_socket_interim: bool,
	incompatible_fallback: bool,
	family_compatible: bool,
	visible_rifle_ready: bool,
	locomotion_source_requires_overlay: bool
) -> StringName:
	if pistol_source_clip and not component_socket_interim:
		return &"pistol_source_clip_rejected"
	if incompatible_fallback:
		return &"incompatible_source_clip_rejected"
	if visible_rifle_ready and component_socket_interim:
		return &"component_m4_socket_interim_missing_authored_rifle_clips"
	if family_compatible and locomotion_source_requires_overlay:
		return &"visible_two_hand_rifle_ready_locomotion_component_baseline"
	if family_compatible:
		return &"visible_two_hand_rifle_ready"
	return &"socket_contact_unaccepted"


func _is_incompatible_rifle_fallback(state: MotionState, clip_name: String) -> bool:
	var lower := clip_name.to_lower()
	if _uses_component_m4_socket_interim(clip_name):
		return false
	return (
		"pistol" in lower
		or lower in ["idle_rail", "spell_simple_shoot", "interact"]
		or ("death" in lower and state != MotionState.DEATH)
		or ("prone" in lower and state != MotionState.DEATH)
	)


func _resolved_animation_semantic() -> StringName:
	if _custom_preview:
		return StringName("source_%s" % _custom_clip.to_snake_case())
	match current_state:
		MotionState.IDLE:
			return &"component_m4_socket_idle_interim"
		MotionState.WALK:
			return &"rifle_walk_ready_component_baseline_overlay"
		MotionState.RUN:
			return &"rifle_run_reposition_ready_component_baseline_overlay"
		MotionState.AIM:
			return &"component_m4_socket_aim_interim"
		MotionState.FIRE:
			return &"component_m4_socket_fire_interim"
		MotionState.RELOAD:
			return &"component_m4_socket_reload_interim"
		_:
			return StringName("source_%s" % String(STATE_CLIPS[current_state]["clip"]).to_snake_case())


func _build_holders() -> void:
	if _model_holder != null:
		return
	_model_holder = Node3D.new()
	_model_holder.name = "Model"
	add_child(_model_holder)
	_source_holder = Node3D.new()
	_source_holder.name = "RetargetSources"
	_source_holder.visible = false
	add_child(_source_holder)


func _build_animation_sources() -> void:
	for library_id in ["ual1", "ual2"]:
		var packed: PackedScene = UAL1_SCENE if library_id == "ual1" else UAL2_SCENE
		var instance := packed.instantiate() as Node3D
		instance.name = library_id.to_upper()
		_source_holder.add_child(instance)
		var skeleton := HumanoidBoneMapper.find_skeleton(instance)
		var player := HumanoidBoneMapper.find_animation_player(instance)
		player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		_source_instances[library_id] = instance
		_source_skeletons[library_id] = skeleton
		_source_players[library_id] = player


func _attach_weapon() -> void:
	var right_hand_index: int = HumanoidBoneMapper.build_map(_target_skeleton).get("right_hand", -1)
	if right_hand_index < 0:
		return
	var previous := _target_skeleton.get_node_or_null("WeaponSocket")
	if previous != null:
		previous.queue_free()
	_weapon_root = null
	_weapon_source = null
	_muzzle_marker = null
	var attachment := BoneAttachment3D.new()
	attachment.name = "WeaponSocket"
	attachment.bone_name = _target_skeleton.get_bone_name(right_hand_index)
	_target_skeleton.add_child(attachment)
	_weapon_attachment = attachment
	var weapon := Node3D.new()
	weapon.name = "PrimaryRifle"
	var source := PRIMARY_RIFLE_SCENE.instantiate() as Node3D
	source.name = "M4RifleSource"
	# The authored origin sits below the receiver and behind the pistol grip.
	# Rebase the intact rifle so the right-hand socket lands on the grip rather
	# than on the model origin. The source has exactly one attached magazine.
	source.position = RIFLE_SOURCE_GRIP_OFFSET
	weapon.add_child(source)
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	# The imported rifle points down local +Z; the suppressor tip ends at 13.8.
	muzzle.position = RIFLE_MUZZLE_LOCAL
	source.add_child(muzzle)
	# Both accepted character sources use centimetre-scale skeleton space. The
	# M4's 23.795-unit authored length therefore needs a 4.0 socket scale to read
	# as a grounded ~0.95 m rifle in world space.
	weapon.scale = Vector3.ONE * 4.0
	weapon.position = RIFLE_SOCKET_POSITION
	weapon.rotation_degrees = RIFLE_SOCKET_LOW_READY_ROTATION
	attachment.add_child(weapon)
	_weapon_root = weapon
	_weapon_source = source
	_muzzle_marker = muzzle
	_apply_weapon_pose_for_state()


func rifle_contact_report() -> Dictionary:
	if _target_skeleton == null:
		return {"accepted": false, "failure_reason": &"missing_skeleton"}
	if _weapon_attachment == null or _weapon_root == null or _muzzle_marker == null:
		return {"accepted": false, "failure_reason": &"missing_weapon_socket"}
	_sync_weapon_attachment()
	var right_hand := _bone_world_origin("right_hand")
	var left_hand := _bone_world_origin("left_hand")
	if right_hand == null or left_hand == null:
		return {"accepted": false, "failure_reason": &"missing_hand_bones"}
	var right_hand_position: Vector3 = right_hand
	var left_hand_position: Vector3 = left_hand
	var muzzle_world: Vector3 = _muzzle_marker.global_position
	var actor_forward: Vector3 = global_transform.basis.z.normalized()
	var hand_to_muzzle: Vector3 = muzzle_world - right_hand_position
	var muzzle_forward: Vector3 = hand_to_muzzle.normalized() if hand_to_muzzle.length() > 0.001 else actor_forward
	var support_distance: float = left_hand_position.distance_to(right_hand_position)
	var muzzle_height: float = muzzle_world.y - global_position.y
	var right_muzzle_distance: float = right_hand_position.distance_to(muzzle_world)
	var forward_dot: float = muzzle_forward.dot(actor_forward)
	var forward_alignment: float = absf(forward_dot)
	var upright: bool = absf(rotation.x) <= 0.001 and absf(rotation.z) <= 0.001
	var weapon_visible := _weapon_attachment.visible and _weapon_root.visible
	var right_hand_contact := right_muzzle_distance >= 0.28 and right_muzzle_distance <= 1.65
	var left_foregrip_contact := support_distance >= 0.08 and support_distance <= 0.98
	var stock_shoulder_estimated := muzzle_height >= 0.75 and muzzle_height <= 2.25 and right_muzzle_distance >= 0.28
	var muzzle_direction_coherent := forward_dot >= 0.20
	var visible_pose_evidence := {
		"right_hand_contact_estimated": right_hand_contact,
		"left_foregrip_contact_estimated": left_foregrip_contact,
		"stock_shoulder_estimated": stock_shoulder_estimated,
		"muzzle_direction_coherent": muzzle_direction_coherent,
		"grounded_root": ground_contact_report().get("applicable", false),
		"upright_torso": upright,
	}
	var accepted: bool = (
		upright
		and weapon_visible
		and right_hand_contact
		and left_foregrip_contact
		and stock_shoulder_estimated
		and muzzle_direction_coherent
	)
	return {
		"accepted": accepted,
		"failure_reason": &"" if accepted else &"rifle_contact_threshold_missed",
		"state": state_name(),
		"weapon_visible": weapon_visible,
		"socket_bone": String(_weapon_attachment.bone_name),
		"socket_rotation_degrees": _weapon_root.rotation_degrees,
		"right_hand_world": right_hand_position,
		"left_hand_world": left_hand_position,
		"muzzle_world": muzzle_world,
		"left_to_right_hand_distance": support_distance,
		"right_hand_to_muzzle_distance": right_muzzle_distance,
		"muzzle_height_above_actor": muzzle_height,
		"muzzle_forward_dot_actor_forward": forward_dot,
		"muzzle_forward_alignment_actor_axis": forward_alignment,
		"muzzle_direction_coherent": muzzle_direction_coherent,
		"right_hand_contact_estimated": right_hand_contact,
		"left_foregrip_contact_estimated": left_foregrip_contact,
		"stock_shoulder_estimated": stock_shoulder_estimated,
		"two_hand_contact_estimated": left_foregrip_contact,
		"grounded_upright": upright,
		"visible_pose_evidence": visible_pose_evidence,
		"forward_reference": &"component_actor_forward_axis",
	}


func _sync_weapon_attachment() -> void:
	if _target_skeleton == null or _weapon_attachment == null:
		return
	_target_skeleton.force_update_all_bone_transforms()
	_weapon_attachment.on_skeleton_update()


func _bone_world_origin(canonical_bone: String) -> Variant:
	var mapping := HumanoidBoneMapper.build_map(_target_skeleton)
	if not mapping.has(canonical_bone):
		return null
	return _target_skeleton.to_global(_target_skeleton.get_bone_global_pose(mapping[canonical_bone]).origin)
