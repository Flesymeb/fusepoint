class_name FusepointControlledTarget
extends StaticBody3D

@export var max_health := 140.0

var health := 140.0
var _committed_shot_ids: Dictionary = {}
var _last_damage: Dictionary = {}


func _ready() -> void:
	health = max_health


func apply_weapon_damage(amount: float, shot_id: String, origin: Vector3) -> bool:
	if _committed_shot_ids.has(shot_id) or health <= 0.0:
		return false
	_committed_shot_ids[shot_id] = true
	health = maxf(0.0, health - amount)
	_last_damage = {
		"shot_id": shot_id,
		"amount": amount,
		"origin": origin,
		"remaining_health": health,
		"commit_count": _committed_shot_ids.size(),
	}
	return true


func reset_target() -> void:
	health = max_health
	_committed_shot_ids.clear()
	_last_damage.clear()


func _mcp_state() -> Dictionary:
	return {
		"target_id": "ballistics_calibration_plate",
		"health": health,
		"max_health": max_health,
		"damage_commit_count": _committed_shot_ids.size(),
		"last_damage": _last_damage,
		"alive": health > 0.0,
	}
