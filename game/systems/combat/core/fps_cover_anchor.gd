class_name FPSCoverAnchor
extends Marker3D

## A product-owned tactical destination. Level authors place these behind real
## collision geometry; the enemy verifies occlusion from the current threat
## before selecting one. Reservations keep several agents from stacking on the
## same marker.

@export var cover_group: StringName = &"fps_enemy_cover"
@export var crouch_offset := Vector3.ZERO
@export var peek_offset := Vector3(0.65, 0.0, 0.0)

var _occupant: Node3D


func _ready() -> void:
	if not is_in_group(cover_group):
		add_to_group(cover_group)


func is_available_for(actor: Node3D) -> bool:
	return _occupant == null or not is_instance_valid(_occupant) or _occupant == actor


func try_reserve(actor: Node3D) -> bool:
	if actor == null or not is_available_for(actor):
		return false
	_occupant = actor
	return true


func release(actor: Node3D) -> void:
	if _occupant == actor or _occupant == null or not is_instance_valid(_occupant):
		_occupant = null


func crouch_position() -> Vector3:
	return global_transform * crouch_offset


func peek_position() -> Vector3:
	return global_transform * peek_offset


func snapshot() -> Dictionary:
	return {
		"path": String(get_path()) if is_inside_tree() else "",
		"reserved": _occupant != null and is_instance_valid(_occupant),
		"occupant": String(_occupant.get_path()) if _occupant != null and is_instance_valid(_occupant) and _occupant.is_inside_tree() else "",
		"crouch_position": crouch_position(),
		"peek_position": peek_position(),
	}
