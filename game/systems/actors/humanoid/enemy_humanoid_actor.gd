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
	# UAL does not contain third-person rifle-named actions. AIM/FIRE/RELOAD use
	# one neutral two-hand rail base pose and product-owned rifle overlays below;
	# no pistol, spell, interaction, prone, hit, or death clip is relabeled.
	MotionState.IDLE: {"library": "ual1", "clip": "Idle", "loop": true},
	MotionState.WALK: {"library": "ual1", "clip": "Walk", "loop": true},
	MotionState.RUN: {"library": "ual1", "clip": "Jog_Fwd", "loop": true},
	MotionState.CROUCH_IDLE: {"library": "ual1", "clip": "Crouch_Idle", "loop": true},
	MotionState.CROUCH_MOVE: {"library": "ual1", "clip": "Crouch_Fwd", "loop": true},
	MotionState.JUMP_START: {"library": "ual1", "clip": "Jump_Start", "loop": false},
	MotionState.AIRBORNE: {"library": "ual1", "clip": "Jump", "loop": true},
	MotionState.LAND: {"library": "ual1", "clip": "Jump_Land", "loop": false},
	MotionState.AIM: {"library": "ual2", "clip": "Idle_Rail", "loop": true},
	MotionState.FIRE: {"library": "ual2", "clip": "Idle_Rail", "loop": true},
	MotionState.RELOAD: {"library": "ual2", "clip": "Idle_Rail", "loop": true},
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
	_apply_ground_contact()


func set_aim_pitch(pitch_degrees: float) -> void:
	var clamped_pitch := clampf(pitch_degrees, -50.0, 50.0)
	if not is_equal_approx(clamped_pitch, _aim_pitch_degrees):
		_aim_pitch_serial += 1
	_aim_pitch_degrees = clamped_pitch


func _apply_rifle_aim_overlay() -> void:
	if _target_skeleton == null or current_state not in [MotionState.AIM, MotionState.FIRE]:
		return
	var mapping := HumanoidBoneMapper.build_map(_target_skeleton)
	var pitch_radians := deg_to_rad(_aim_pitch_degrees)
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
		var pitch_rotation := Quaternion(Vector3.RIGHT, pitch_radians * float(overlay["weight"]))
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
	for canonical in _contact_bones(grounding_mode):
		if not mapping.has(canonical):
			continue
		var pose_origin := _target_skeleton.get_bone_global_pose(mapping[canonical]).origin
		minimum_y = minf(minimum_y, to_local(_target_skeleton.to_global(pose_origin)).y)
	return {
		"mode": grounding_mode,
		"applicable": is_finite(minimum_y),
		"minimum_contact_y": minimum_y,
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
	return {
		"skin_id": current_skin_id,
		"state": state_name(),
		"animation_library": _active_library,
		"mode": "clip_browser" if _custom_preview else "semantic_state",
		"animation": _custom_clip if _custom_preview else String(STATE_CLIPS[current_state]["clip"]),
		"animation_semantic": (
			&"rifle_fire_overlay" if current_state == MotionState.FIRE
			else &"rifle_reload_overlay" if current_state == MotionState.RELOAD
			else &"rifle_two_hand_aim" if current_state == MotionState.AIM
			else StringName(state_name())
		),
		"rifle_semantic_procedural": current_state in [MotionState.AIM, MotionState.FIRE, MotionState.RELOAD],
		"rifle_action_progress": clampf(_rifle_action_elapsed / maxf(_rifle_action_duration, 0.001), 0.0, 1.0) if _rifle_action_duration > 0.0 else 0.0,
		"animation_position_seconds": animation_position,
		"animation_length_seconds": animation_length,
		"animation_normalized_time": clampf(animation_position / animation_length, 0.0, 1.0) if animation_length > 0.0 else 0.0,
		"animation_playing": player != null and player.is_playing(),
		"weapon_family": WEAPON_FAMILY,
		"weapon_family_compatible": "pistol" not in String(STATE_CLIPS[current_state]["clip"]).to_lower(),
		"aim_pitch_degrees": _aim_pitch_degrees,
		"aim_pitch_serial": _aim_pitch_serial,
		"socket_bound": _weapon_attachment != null,
		"socket_bone": String(_weapon_attachment.bone_name) if _weapon_attachment != null else "",
		"weapon_attached": _weapon_attachment != null and _weapon_attachment.get_node_or_null("PrimaryRifle") != null,
		"locomotion_playback_scale": _locomotion_playback_scale,
		"state_change_count": _state_change_count,
		"binding": binding_report,
	}


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
	source.position = Vector3(0.0, -4.8, 5.0)
	weapon.add_child(source)
	var muzzle := Marker3D.new()
	muzzle.name = "Muzzle"
	# The imported rifle points down local +Z; the suppressor tip ends at 13.8.
	muzzle.position = Vector3(0.0, 5.4, 13.85)
	source.add_child(muzzle)
	# Both accepted character sources use centimetre-scale skeleton space. The
	# M4's 23.795-unit authored length therefore needs a 4.0 socket scale to read
	# as a grounded ~0.95 m rifle in world space.
	weapon.scale = Vector3.ONE * 4.0
	weapon.position = Vector3(0.02, 0.02, -0.02)
	weapon.rotation_degrees = Vector3(-90.0, 90.0, 0.0)
	# Preserve muzzle-forward alignment while putting the optic above and the
	# magazine below the barrel; the imported source roll is inverted relative
	# to the retargeted right-hand socket.
	weapon.rotate_object_local(Vector3.FORWARD, PI)
	attachment.add_child(weapon)
