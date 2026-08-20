class_name HumanoidBoneMapper
extends RefCounted


const REQUIRED_BONES := [
	"hips", "spine", "chest", "neck", "head",
	"left_upper_arm", "left_lower_arm", "left_hand",
	"right_upper_arm", "right_lower_arm", "right_hand",
	"left_upper_leg", "left_lower_leg", "left_foot",
	"right_upper_leg", "right_lower_leg", "right_foot",
]


static func build_map(skeleton: Skeleton3D) -> Dictionary:
	var result := {}
	for bone_index in skeleton.get_bone_count():
		var canonical := _canonical_name(String(skeleton.get_bone_name(bone_index)))
		if not canonical.is_empty() and not result.has(canonical):
			result[canonical] = bone_index
	return result


static func inspect(skeleton: Skeleton3D) -> Dictionary:
	var mapping := build_map(skeleton)
	var missing: Array[String] = []
	for canonical in REQUIRED_BONES:
		if not mapping.has(canonical):
			missing.append(canonical)
	return {
		"rig_family": detect_family(skeleton),
		"mapped_bones": mapping.size(),
		"required_bones": REQUIRED_BONES.size(),
		"coverage": float(REQUIRED_BONES.size() - missing.size()) / float(REQUIRED_BONES.size()),
		"missing": missing,
		"rest_pose": inspect_rest_pose(skeleton, mapping),
		"map": mapping,
	}


static func inspect_rest_pose(skeleton: Skeleton3D, mapping: Dictionary) -> Dictionary:
	var knee_bend_degrees := {}
	var neutral := true
	for side in ["left", "right"]:
		var upper_key := "%s_upper_leg" % side
		var lower_key := "%s_lower_leg" % side
		var foot_key := "%s_foot" % side
		if not mapping.has(upper_key) or not mapping.has(lower_key) or not mapping.has(foot_key):
			neutral = false
			knee_bend_degrees[side] = null
			continue
		var hip_position := skeleton.get_bone_global_rest(mapping[upper_key]).origin
		var knee_position := skeleton.get_bone_global_rest(mapping[lower_key]).origin
		var ankle_position := skeleton.get_bone_global_rest(mapping[foot_key]).origin
		var thigh := (knee_position - hip_position).normalized()
		var shin := (ankle_position - knee_position).normalized()
		var bend := rad_to_deg(thigh.angle_to(shin))
		knee_bend_degrees[side] = bend
		if bend > 35.0:
			neutral = false
	return {
		"neutral_leg_stance": neutral,
		"knee_bend_degrees": knee_bend_degrees,
		"maximum_allowed_knee_bend_degrees": 35.0,
	}


static func detect_family(skeleton: Skeleton3D) -> String:
	var names := ""
	for bone_index in skeleton.get_bone_count():
		names += String(skeleton.get_bone_name(bone_index)).to_lower() + " "
	if "mixamorig" in names:
		return "mixamo"
	if "quickrig" in names:
		return "quickrig"
	if "def-" in names:
		return "quaternius_ual1"
	if "spine_01" in names and "upperarm_l" in names:
		return "quaternius_ual2"
	return "generic_humanoid"


static func find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for child in root.get_children():
		var found := find_skeleton(child)
		if found != null:
			return found
	return null


static func find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := find_animation_player(child)
		if found != null:
			return found
	return null


static func _canonical_name(raw_name: String) -> String:
	var lower := raw_name.to_lower()
	var compact := lower.replace(":", "").replace("-", "").replace("_", "").replace(".", "")
	compact = _trim_trailing_digits(compact)
	var side := ""
	if "left" in compact or lower.ends_with(".l") or lower.ends_with("_l"):
		side = "left_"
	elif "right" in compact or lower.ends_with(".r") or lower.ends_with("_r"):
		side = "right_"

	if "hips" in compact or "pelvis" in compact:
		return "hips"
	if "neck" in compact:
		return "neck"
	if "head" in compact:
		return "head"
	if "shoulder" in compact or "clavicle" in compact:
		return side + "shoulder" if not side.is_empty() else ""
	if "upperarm" in compact or ("arm" in compact and "forearm" not in compact and "lowerarm" not in compact):
		return side + "upper_arm" if not side.is_empty() else ""
	if "forearm" in compact or "lowerarm" in compact:
		return side + "lower_arm" if not side.is_empty() else ""
	if "hand" in compact and "thumb" not in compact and "index" not in compact and "middle" not in compact and "ring" not in compact and "pinky" not in compact:
		return side + "hand" if not side.is_empty() else ""
	if "upleg" in compact or "thigh" in compact:
		return side + "upper_leg" if not side.is_empty() else ""
	if "leg" in compact or "shin" in compact or "calf" in compact:
		return side + "lower_leg" if not side.is_empty() else ""
	if "toe" in compact:
		return side + "toe" if not side.is_empty() else ""
	if "foot" in compact:
		return side + "foot" if not side.is_empty() else ""
	if "spine2" in lower or "spine.003" in lower or "spine_03" in lower:
		return "chest"
	if "spine1" in lower or "spine.002" in lower or "spine_02" in lower:
		return "spine_mid"
	if "spine" in compact:
		return "spine"
	return ""


static func _trim_trailing_digits(value: String) -> String:
	var end := value.length()
	while end > 0 and value[end - 1].is_valid_int():
		end -= 1
	return value.left(end)
