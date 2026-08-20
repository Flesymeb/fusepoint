class_name FPSHealth
extends Node

## Reusable, event-bound health receiver. A non-empty shot_id is applied at most
## once, which prevents retries or duplicate collision callbacks from dealing
## damage twice.

signal health_changed(previous: float, current: float, maximum: float, event: Dictionary)
signal damaged(event: Dictionary)
signal died(event: Dictionary)
signal revived(current: float, maximum: float)

@export_range(1.0, 10000.0, 1.0) var max_health := 100.0
@export var start_full := true
@export var team: StringName = &"neutral"
@export var friendly_fire := false
@export_node_path("Node") var presentation_path: NodePath

var current_health := 100.0
var is_dead := false
var _seen_shot_ids: Dictionary = {}
var _shot_id_order: Array[String] = []
var _presentation: Node

const MAX_REMEMBERED_SHOTS := 256


func _ready() -> void:
	current_health = max_health if start_full else clampf(current_health, 0.0, max_health)
	is_dead = current_health <= 0.0
	_presentation = get_node_or_null(presentation_path) if not presentation_path.is_empty() else null


func reset_health(value := -1.0) -> void:
	current_health = max_health if value < 0.0 else clampf(value, 0.0, max_health)
	is_dead = current_health <= 0.0
	_seen_shot_ids.clear()
	_shot_id_order.clear()
	if not is_dead:
		revived.emit(current_health, max_health)


func apply_damage(amount: float, event: Dictionary = {}) -> Dictionary:
	var normalized := event.duplicate(true)
	var shot_id := String(normalized.get("shot_id", ""))
	var source_team := StringName(normalized.get("source_team", &""))
	if amount <= 0.0:
		return _rejected_report("non_positive_damage", amount, normalized)
	if is_dead:
		return _rejected_report("already_dead", amount, normalized)
	if not shot_id.is_empty() and _seen_shot_ids.has(shot_id):
		return _rejected_report("duplicate_shot_id", amount, normalized)
	if not friendly_fire and source_team != &"" and source_team == team:
		return _rejected_report("friendly_fire_blocked", amount, normalized)

	if not shot_id.is_empty():
		_remember_shot_id(shot_id)
	var previous := current_health
	current_health = maxf(0.0, current_health - amount)
	is_dead = current_health <= 0.0
	normalized["amount"] = amount
	normalized["health_before"] = previous
	normalized["health_after"] = current_health
	normalized["max_health"] = max_health
	normalized["target_team"] = team
	normalized["killed"] = is_dead
	normalized["applied"] = true
	normalized["reason"] = "applied"
	health_changed.emit(previous, current_health, max_health, normalized)
	damaged.emit(normalized)
	if is_dead:
		_call_presentation(&"die")
		died.emit(normalized)
	else:
		_call_presentation(&"take_hit")
	return normalized


func heal(amount: float) -> float:
	if amount <= 0.0 or is_dead:
		return current_health
	var previous := current_health
	current_health = minf(max_health, current_health + amount)
	health_changed.emit(previous, current_health, max_health, {
		"applied": true,
		"reason": "healed",
		"amount": current_health - previous,
	})
	return current_health


func snapshot() -> Dictionary:
	return {
		"current": current_health,
		"maximum": max_health,
		"ratio": current_health / max_health if max_health > 0.0 else 0.0,
		"dead": is_dead,
		"team": String(team),
	}


## Compatibility with common Godot FPS templates. New integrations should use
## apply_damage() so the complete event provenance is retained.
func get_damage(amount: float, direction := Vector3.ZERO, is_enemy_damage := false) -> void:
	apply_damage(amount, {
		"direction": direction,
		"source_team": &"enemy" if is_enemy_damage else &"player",
	})


func damage(amount: float) -> void:
	apply_damage(amount)


func _rejected_report(reason: String, amount: float, event: Dictionary) -> Dictionary:
	var report := event.duplicate(true)
	report["amount"] = amount
	report["health_before"] = current_health
	report["health_after"] = current_health
	report["max_health"] = max_health
	report["applied"] = false
	report["killed"] = is_dead
	report["reason"] = reason
	return report


func _remember_shot_id(shot_id: String) -> void:
	_seen_shot_ids[shot_id] = true
	_shot_id_order.append(shot_id)
	while _shot_id_order.size() > MAX_REMEMBERED_SHOTS:
		_seen_shot_ids.erase(_shot_id_order.pop_front())


func _call_presentation(method: StringName) -> void:
	if _presentation != null and _presentation.has_method(method):
		_presentation.call(method)
