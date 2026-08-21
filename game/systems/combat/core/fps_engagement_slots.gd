class_name FPSEngagementSlots
extends RefCounted

## Process-local target-relative firing-slot reservations. The positions move
## with the target, while ownership remains stable until an enemy explicitly
## changes flank or releases its target. This prevents a squad from treating
## the player's exact origin as one shared movement destination.

static var _reservations: Dictionary = {}


static func _record_actor(record: Variant) -> Node3D:
	var occupant_ref: WeakRef
	if record is WeakRef:
		occupant_ref = record as WeakRef
	elif record is Dictionary:
		occupant_ref = (record as Dictionary).get("actor") as WeakRef
	return occupant_ref.get_ref() as Node3D if occupant_ref != null else null


static func _record_position(record: Variant) -> Variant:
	if record is Dictionary:
		return (record as Dictionary).get("projected_position", null)
	return null


static func available_indices(actor: Node3D, target: Node3D, slot_count: int) -> Array[int]:
	var result: Array[int] = []
	if actor == null or target == null or slot_count <= 0:
		return result
	var target_id := target.get_instance_id()
	_cleanup_target(target_id)
	var slots: Dictionary = _reservations.get(target_id, {})
	for slot_index in slot_count:
		var occupant := _record_actor(slots.get(slot_index))
		if occupant == null or occupant == actor:
			result.append(slot_index)
	return result


static func projected_position_available(
	actor: Node3D,
	target: Node3D,
	projected_position: Vector3,
	minimum_separation: float,
) -> bool:
	if actor == null or target == null or not projected_position.is_finite():
		return false
	var target_id := target.get_instance_id()
	_cleanup_target(target_id)
	var slots: Dictionary = _reservations.get(target_id, {})
	for record: Variant in slots.values():
		var occupant := _record_actor(record)
		var reserved_position: Variant = _record_position(record)
		if occupant == null or occupant == actor or not reserved_position is Vector3:
			continue
		if projected_position.distance_to(reserved_position as Vector3) < minimum_separation:
			return false
	return true


static func reserve(
	actor: Node3D,
	target: Node3D,
	slot_index: int,
	projected_position := Vector3.ZERO,
	minimum_separation := 0.0,
) -> bool:
	if actor == null or target == null or slot_index < 0:
		return false
	var target_id := target.get_instance_id()
	_cleanup_target(target_id)
	var slots: Dictionary = _reservations.get(target_id, {})
	var occupant := _record_actor(slots.get(slot_index))
	if occupant != null and occupant != actor:
		return false
	if minimum_separation > 0.0 and not projected_position_available(actor, target, projected_position, minimum_separation):
		return false
	_release_actor_from_slots(slots, actor)
	slots[slot_index] = {
		"actor": weakref(actor),
		"projected_position": projected_position,
	}
	_reservations[target_id] = slots
	return true


static func update_projected_position(
	actor: Node3D,
	target: Node3D,
	projected_position: Vector3,
	minimum_separation: float,
) -> bool:
	if not projected_position_available(actor, target, projected_position, minimum_separation):
		return false
	var target_id := target.get_instance_id()
	var slots: Dictionary = _reservations.get(target_id, {})
	for slot_index: Variant in slots.keys():
		if _record_actor(slots[slot_index]) == actor:
			slots[slot_index]["projected_position"] = projected_position
			_reservations[target_id] = slots
			return true
	return false


static func release(actor: Node3D, target: Node3D) -> void:
	if actor == null or target == null:
		return
	var target_id := target.get_instance_id()
	_cleanup_target(target_id)
	var slots: Dictionary = _reservations.get(target_id, {})
	_release_actor_from_slots(slots, actor)
	if slots.is_empty():
		_reservations.erase(target_id)
	else:
		_reservations[target_id] = slots


static func position_for(target: Node3D, slot_index: int, slot_count: int, radius: float) -> Vector3:
	if target == null or slot_index < 0 or slot_count <= 0:
		return Vector3.ZERO
	var target_forward := -target.global_basis.z
	target_forward.y = 0.0
	if target_forward.length_squared() <= 0.0001:
		target_forward = Vector3.FORWARD
	target_forward = target_forward.normalized()
	var base_angle := atan2(target_forward.x, target_forward.z)
	var angle := base_angle + (TAU * float(slot_index) / float(slot_count))
	return target.global_position + Vector3(sin(angle), 0.0, cos(angle)) * radius


static func reservation_count(target: Node3D) -> int:
	if target == null:
		return 0
	var target_id := target.get_instance_id()
	_cleanup_target(target_id)
	return (_reservations.get(target_id, {}) as Dictionary).size()


static func _cleanup_target(target_id: int) -> void:
	var slots: Dictionary = _reservations.get(target_id, {})
	for slot_index: Variant in slots.keys():
		if _record_actor(slots.get(slot_index)) == null:
			slots.erase(slot_index)
	if slots.is_empty():
		_reservations.erase(target_id)
	else:
		_reservations[target_id] = slots


static func _release_actor_from_slots(slots: Dictionary, actor: Node3D) -> void:
	for slot_index: Variant in slots.keys():
		if _record_actor(slots.get(slot_index)) == actor:
			slots.erase(slot_index)
