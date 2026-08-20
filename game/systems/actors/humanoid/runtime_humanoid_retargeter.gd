class_name RuntimeHumanoidRetargeter
extends RefCounted


var source_skeleton: Skeleton3D
var target_skeleton: Skeleton3D
var source_map: Dictionary = {}
var target_map: Dictionary = {}
var shared_bones: Array[String] = []
var position_scale := 1.0


func configure(source: Skeleton3D, target: Skeleton3D) -> Dictionary:
	source_skeleton = source
	target_skeleton = target
	source_map = HumanoidBoneMapper.build_map(source)
	target_map = HumanoidBoneMapper.build_map(target)
	shared_bones.clear()
	for canonical in source_map:
		if target_map.has(canonical):
			shared_bones.append(canonical)
	shared_bones.sort_custom(_sort_by_target_index)
	position_scale = _reference_height(target_skeleton, target_map) / maxf(_reference_height(source_skeleton, source_map), 0.001)
	return {
		"source": HumanoidBoneMapper.inspect(source),
		"target": HumanoidBoneMapper.inspect(target),
		"shared_bones": shared_bones.size(),
		"position_scale": position_scale,
	}


func apply_pose(hips_translation_mode := "none") -> void:
	if source_skeleton == null or target_skeleton == null:
		return
	for canonical in shared_bones:
		var source_index: int = source_map[canonical]
		var target_index: int = target_map[canonical]
		var source_rest_global := source_skeleton.get_bone_global_rest(source_index)
		var source_pose_global := source_skeleton.get_bone_global_pose(source_index)
		var target_rest_global := target_skeleton.get_bone_global_rest(target_index)

		var rotation_delta := source_pose_global.basis * source_rest_global.basis.inverse()
		var desired_global := target_rest_global
		desired_global.basis = rotation_delta * target_rest_global.basis
		if canonical == "hips" and hips_translation_mode != "none":
			var translation_delta := (source_pose_global.origin - source_rest_global.origin) * position_scale
			if hips_translation_mode == "vertical":
				translation_delta.x = 0.0
				translation_delta.z = 0.0
			desired_global.origin += translation_delta
		var parent_index := target_skeleton.get_bone_parent(target_index)
		var desired_local := desired_global
		if parent_index >= 0:
			var parent_global := target_skeleton.get_bone_global_pose(parent_index)
			desired_local = parent_global.affine_inverse() * desired_global
		target_skeleton.set_bone_pose_rotation(target_index, desired_local.basis.get_rotation_quaternion())
		var target_position := desired_local.origin if canonical == "hips" else target_skeleton.get_bone_rest(target_index).origin
		target_skeleton.set_bone_pose_position(target_index, target_position)


func reset_target() -> void:
	if target_skeleton != null:
		target_skeleton.reset_bone_poses()


func _sort_by_target_index(a: String, b: String) -> bool:
	return int(target_map[a]) < int(target_map[b])


func _reference_height(skeleton: Skeleton3D, mapping: Dictionary) -> float:
	if not mapping.has("hips") or not mapping.has("head"):
		return 1.0
	var hips_position := skeleton.get_bone_global_rest(mapping["hips"]).origin
	var head_position := skeleton.get_bone_global_rest(mapping["head"]).origin
	return hips_position.distance_to(head_position)
