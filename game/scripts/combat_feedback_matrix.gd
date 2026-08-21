class_name FusepointCombatFeedbackMatrix
extends Node

## Bounded presentation receipt join. This observer never submits gameplay state.
signal feedback_receipt_updated(receipt: Dictionary)

const CACHE_LIMIT := 128
const JOINED_ENEMY_KINDS: Array[StringName] = [&"shot_resolved", &"player_hit", &"died", &"reload_started", &"reload_finished"]
const JOINED_MISSION_KINDS: Array[StringName] = [
	&"deployment_started", &"capture_started", &"capture_contested", &"capture_interrupted",
	&"capture_completed", &"key_committed", &"route_unlocked", &"checkpoint_restored",
	&"defusal_started", &"defusal_interrupted", &"defusal_completed", &"terminal_submitted",
	&"enemy_died",
]

@export var weapon_path: NodePath
@export var player_path: NodePath
@export var roster_path: NodePath
@export var mission_path: NodePath
@export var hud_path: NodePath
@export var damage_feedback_path: NodePath
@export var mission_feedback_path: NodePath

var _events: Dictionary = {}
var _event_order: Array[String] = []
var _latest_event_id := ""
var _duplicate_channel_count := 0
var _restore_epoch := 0
var _paused_last_frame := false

var _weapon: Node
var _player: Node
var _roster: Node
var _mission: Node
var _hud: Node
var _damage_feedback: Node
var _mission_feedback: Node
var _shot_feedback: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred(&"_bind_runtime")


func _process(_delta: float) -> void:
	if get_tree().paused and not _paused_last_frame:
		_restore_epoch += 1
		_clear_joined_receipts()
	_paused_last_frame = get_tree().paused


func _bind_runtime() -> void:
	_weapon = get_node_or_null(weapon_path)
	_player = get_node_or_null(player_path)
	_roster = get_node_or_null(roster_path)
	_mission = get_node_or_null(mission_path)
	_hud = get_node_or_null(hud_path)
	_damage_feedback = get_node_or_null(damage_feedback_path)
	_mission_feedback = get_node_or_null(mission_feedback_path)
	_shot_feedback = _weapon.get_node_or_null("ShotFeedback") if _weapon != null else null
	_connect_signal(_weapon, &"shot_resolved", _on_player_shot)
	_connect_signal(_shot_feedback, &"shot_presented", _on_shot_presented)
	_connect_signal(_player, &"authoritative_damage_received", _on_player_damage)
	_connect_signal(_player, &"player_died", _on_player_death)
	_connect_signal(_player, &"spawn_reset", _on_player_spawn_reset)
	_connect_signal(_roster, &"roster_event_committed", _on_roster_event)
	_connect_signal(_mission, &"mission_event_committed", _on_mission_event)
	_connect_signal(_hud, &"combat_row_presented", _on_hud_row)
	_connect_signal(_damage_feedback, &"damage_feedback_started", _on_damage_feedback)
	_connect_signal(_damage_feedback, &"death_feedback_started", _on_death_feedback)
	_connect_signal(_mission_feedback, &"mission_cue_presented", _on_mission_cue)


func _connect_signal(node: Node, signal_name: StringName, callable: Callable) -> void:
	if node != null and node.has_signal(signal_name) and not node.is_connected(signal_name, callable):
		node.connect(signal_name, callable)


func _on_player_shot(event: Dictionary) -> void:
	var event_id := String(event.get("shot_id", ""))
	if event_id.is_empty():
		return
	var row := _ensure_row(event_id, &"player_shot")
	row["source_actor"] = "player"
	row["source_weapon"] = String(event.get("weapon_id", ""))
	row["ammo_commit"] = int(event.get("ammo_commit", 0))
	row["ballistic_result"] = StringName(event.get("result", &"unknown"))
	row["surface"] = StringName(event.get("surface_kind", &"unknown"))
	row["damage_result"] = {"committed": event.get("damage_commit", false), "amount": event.get("damage", 0.0)}
	_set_channel(row, &"authority", event)
	if _shot_feedback != null and _shot_feedback.has_method(&"snapshot"):
		var feedback: Dictionary = _shot_feedback.call(&"snapshot")
		_set_channel(row, &"vfx", feedback.get("last_presentation", {}))
		_set_channel(row, &"audio", _audio_from_shot_snapshot(feedback))
	_publish(row)


func _on_shot_presented(event: Dictionary) -> void:
	var event_id := String(event.get("shot_id", ""))
	if event_id.is_empty():
		return
	var row := _ensure_row(event_id, &"shot_presentation")
	var feedback: Dictionary = _shot_feedback.call(&"snapshot") if _shot_feedback != null and _shot_feedback.has_method(&"snapshot") else {}
	_set_channel(row, &"vfx", feedback.get("last_presentation", event))
	_set_channel(row, &"audio", _audio_from_shot_snapshot(feedback))
	_publish(row)


func _on_player_damage(event: Dictionary) -> void:
	var event_id := _primary_event_id(event)
	if event_id.is_empty():
		return
	var row := _ensure_row(event_id, &"player_damage")
	row["source_actor"] = String(event.get("source_path", "enemy"))
	row["damage_result"] = {
		"amount": event.get("amount", 0.0),
		"severity": event.get("severity", &"light"),
		"health_before": event.get("health_before", 0.0),
		"health_after": event.get("health_after", 0.0),
		"killed": event.get("killed", false),
	}
	_set_channel(row, &"damage", event)
	_publish(row)


func _on_player_death(event: Dictionary) -> void:
	_restore_epoch += 1
	_clear_joined_receipts()
	var event_id := _primary_event_id(event)
	var row := _ensure_row(event_id, &"player_death")
	_set_channel(row, &"death", event)
	_publish(row)


func _on_damage_feedback(event: Dictionary) -> void:
	var event_id := _primary_event_id(event)
	var row := _ensure_row(event_id, &"player_damage")
	var feedback: Dictionary = _damage_feedback.call(&"snapshot") if _damage_feedback != null and _damage_feedback.has_method(&"snapshot") else {}
	_set_channel(row, &"camera_damage_mask", feedback)
	_publish(row)


func _on_death_feedback(event: Dictionary) -> void:
	var event_id := _primary_event_id(event)
	var row := _ensure_row(event_id, &"player_death")
	var feedback: Dictionary = _damage_feedback.call(&"snapshot") if _damage_feedback != null and _damage_feedback.has_method(&"snapshot") else {}
	_set_channel(row, &"camera_damage_mask", feedback)
	_publish(row)


func _on_roster_event(wrapper: Dictionary) -> void:
	var enemy_event: Dictionary = wrapper.get("payload", {})
	if StringName(wrapper.get("kind", &"")) != &"enemy_event" or enemy_event.is_empty():
		return
	var event_id := _primary_event_id(enemy_event)
	if event_id.is_empty():
		return
	var kind := StringName(enemy_event.get("kind", &"enemy_event"))
	if kind not in JOINED_ENEMY_KINDS:
		return
	var row := _ensure_row(event_id, &"enemy_death" if kind == &"died" else &"enemy_%s" % kind)
	row["source_actor"] = String(enemy_event.get("actor_id", ""))
	row["source_weapon"] = String((enemy_event.get("payload", {}) as Dictionary).get("weapon_id", "rift_carbine"))
	_set_channel(row, &"enemy_authority", enemy_event)
	var actor: Dictionary = _enemy_snapshot(StringName(enemy_event.get("actor_id", &"")))
	if not actor.is_empty():
		row["animation_state"] = actor.get("presentation", {})
		row["cleanup_observation"] = {"cleanup_hidden": actor.get("cleanup_hidden", false), "alive": actor.get("alive", true)}
		var shot_feedback: Dictionary = actor.get("shot_feedback", {})
		if not shot_feedback.is_empty():
			_set_channel(row, &"vfx", shot_feedback.get("last_presentation", {}))
			_set_channel(row, &"audio", _audio_from_shot_snapshot(shot_feedback))
	if kind == &"died":
		_set_channel(row, &"enemy_death", enemy_event)
	_publish(row)


func _on_mission_event(event: Dictionary) -> void:
	var kind := StringName(event.get("kind", &""))
	if kind in [&"checkpoint_restored", &"deployment_started", &"terminal_submitted"]:
		_restore_epoch += 1
		_clear_joined_receipts()
	if kind == &"timer_tick":
		var remaining := int(ceil(float(event.get("remaining_time", 0.0))))
		if remaining not in [30, 15, 10, 5]:
			return
	elif kind not in JOINED_MISSION_KINDS:
		return
	var event_id := _primary_event_id(event)
	if event_id.is_empty():
		return
	var row := _ensure_row(event_id, &"enemy_death" if kind == &"enemy_died" else &"mission")
	_set_channel(row, &"mission", event)
	if kind == &"enemy_died":
		var source: Dictionary = event.get("payload", {})
		row["score_observation"] = {"elimination_count": int(_mission.get("elimination_count")) if _mission != null else -1}
		row["source_actor"] = String(source.get("actor_id", ""))
	_publish(row)


func _on_player_spawn_reset() -> void:
	_restore_epoch += 1
	_clear_joined_receipts()


func _on_hud_row(receipt: Dictionary) -> void:
	var event_id := String(receipt.get("event_id", ""))
	if event_id.is_empty():
		return
	var row := _ensure_row(event_id, &"enemy_death" if StringName(receipt.get("kind", &"")) == &"enemy_died" else &"hud")
	_set_channel(row, &"hud", receipt)
	_publish(row)


func _on_mission_cue(receipt: Dictionary) -> void:
	var event_id := String(receipt.get("event_id", ""))
	if event_id.is_empty():
		return
	var row := _ensure_row(event_id, &"mission")
	_set_channel(row, &"mission_presentation", receipt)
	var audio_roles: Dictionary = _mission_feedback.call(&"snapshot").get("audio_roles", {}) if _mission_feedback != null and _mission_feedback.has_method(&"snapshot") else {}
	_set_channel(row, &"audio", audio_roles)
	_publish(row)


func _ensure_row(event_id: String, event_family: StringName) -> Dictionary:
	if not _events.has(event_id):
		_events[event_id] = {
			"event_id": event_id,
			"event_family": event_family,
			"channels": {},
			"created_usec": Time.get_ticks_usec(),
			"updated_usec": Time.get_ticks_usec(),
			"presentation_only": true,
			"authoritative_calls": [],
			"restore_epoch": _restore_epoch,
		}
		_event_order.append(event_id)
		while _event_order.size() > CACHE_LIMIT:
			_events.erase(_event_order.pop_front())
	var row: Dictionary = _events[event_id]
	if StringName(row.get("event_family", &"")) in [&"shot_presentation", &"hud"]:
		row["event_family"] = event_family
	return row


func _set_channel(row: Dictionary, channel: StringName, payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var channels: Dictionary = row["channels"]
	if channels.has(channel):
		_duplicate_channel_count += 1
	channels[channel] = payload.duplicate(true)
	row["channels"] = channels
	row["updated_usec"] = Time.get_ticks_usec()


func _publish(row: Dictionary) -> void:
	row["missing_channels"] = _missing_channels(row)
	_events[String(row["event_id"])] = row
	_latest_event_id = String(row["event_id"])
	feedback_receipt_updated.emit(row.duplicate(true))


func _missing_channels(row: Dictionary) -> Array[StringName]:
	var family := StringName(row.get("event_family", &""))
	var expected: Array[StringName] = []
	if family == &"player_shot":
		expected.assign([&"authority", &"vfx", &"audio"])
	elif family == &"player_damage":
		expected.assign([&"damage", &"camera_damage_mask"])
	elif family == &"enemy_death":
		expected.assign([&"enemy_authority", &"enemy_death", &"mission", &"hud"])
	elif family == &"mission":
		expected.assign([&"mission", &"mission_presentation", &"audio"])
	var channels: Dictionary = row.get("channels", {})
	var missing: Array[StringName] = []
	for channel: StringName in expected:
		if not channels.has(channel):
			missing.append(channel)
	return missing


func _primary_event_id(event: Dictionary) -> String:
	var shot_id := String(event.get("shot_id", event.get("damage_event_id", "")))
	if not shot_id.is_empty():
		return shot_id
	var payload: Variant = event.get("payload", null)
	if payload is Dictionary:
		var nested := _primary_event_id(payload as Dictionary)
		if not nested.is_empty():
			return nested
	return String(event.get("event_id", ""))


func _enemy_snapshot(actor_id: StringName) -> Dictionary:
	if _roster == null:
		return {}
	var enemies: Dictionary = _roster.get("enemies")
	var enemy := enemies.get(actor_id) as Node
	return enemy.call(&"authoritative_snapshot") if enemy != null and enemy.has_method(&"authoritative_snapshot") else {}


func _audio_from_shot_snapshot(snapshot: Dictionary) -> Dictionary:
	var presentation: Dictionary = snapshot.get("last_presentation", {})
	var roles: Array = presentation.get("roles", [])
	return {
		"bus": &"Combat",
		"roles": roles.filter(func(role: Variant) -> bool: return "audio" in String(role)),
		"active_effect_count": snapshot.get("active_effect_count", 0),
		"bounded_lifetime": true,
	}


func _clear_joined_receipts() -> void:
	_events.clear()
	_event_order.clear()
	_latest_event_id = ""


func snapshot() -> Dictionary:
	var rows: Array[Dictionary] = []
	var start := maxi(0, _event_order.size() - 32)
	for index in range(start, _event_order.size()):
		var row: Dictionary = (_events[_event_order[index]] as Dictionary).duplicate(true)
		if StringName(row.get("event_family", &"")) == &"enemy_death":
			var death_event: Dictionary = (row.get("channels", {}) as Dictionary).get("enemy_death", {})
			var actor := _enemy_snapshot(StringName(death_event.get("actor_id", &"")))
			if not actor.is_empty():
				row["cleanup_observation"] = {
					"alive": actor.get("alive", true),
					"cleanup_hidden": actor.get("cleanup_hidden", false),
					"avoidance_enabled": actor.get("avoidance_enabled", true),
				}
		rows.append(row)
	return {
		"family_id": &"joined_combat_feedback_matrix",
		"presentation_only": true,
		"authoritative_calls": [],
		"cached_event_count": _events.size(),
		"cache_limit": CACHE_LIMIT,
		"latest_event_id": _latest_event_id,
		"duplicate_channel_count": _duplicate_channel_count,
		"restore_epoch": _restore_epoch,
		"rows": rows,
		"latest": _events.get(_latest_event_id, {}),
	}


func _mcp_state() -> Dictionary:
	return snapshot()
