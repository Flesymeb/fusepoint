class_name FusepointCombatFeedbackMatrix
extends Node

## Bounded presentation receipt join. This observer never submits gameplay state.
signal feedback_receipt_updated(receipt: Dictionary)

const CACHE_LIMIT := 128
const PREVIOUS_RECEIPT_LIMIT := 64
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
var _previous_receipts: Array[Dictionary] = []
var _clear_history: Array[Dictionary] = []

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
		_archive_and_clear(&"pause")
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
	var source_payload: Dictionary = enemy_event.get("payload", {})
	row["source_actor"] = String(enemy_event.get("actor_id", ""))
	row["source_weapon"] = String(source_payload.get("weapon_id", "rift_carbine"))
	if kind == &"shot_resolved":
		row["ballistic_result"] = StringName(source_payload.get("result", &"unknown"))
		row["surface"] = StringName(source_payload.get("surface_kind", &"unknown"))
		row["target_path"] = String(source_payload.get("target_path", ""))
		row["ammo_commit"] = int(source_payload.get("ammo_commit", 0))
		row["damage_result"] = {
			"committed": source_payload.get("applied", false) == true,
			"amount": source_payload.get("damage", 0.0),
			"health_before": source_payload.get("health_before", -1.0),
			"health_after": source_payload.get("health_after", -1.0),
		}
		row["occlusion_result"] = StringName(source_payload.get("result", &"unknown"))
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
		_archive_and_clear(kind)
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
	_archive_and_clear(&"player_spawn_reset")


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
	var identity := _identity_for_event_id(event_id)
	if not _events.has(identity):
		_events[identity] = {
			"event_id": event_id,
			"immutable_identity": identity,
			"run_epoch": _current_run_epoch(),
			"event_family": event_family,
			"channels": {},
			"channel_receipts": {},
			"created_usec": Time.get_ticks_usec(),
			"created_frame": Engine.get_process_frames(),
			"updated_usec": Time.get_ticks_usec(),
			"presentation_only": true,
			"authoritative_calls": [],
			"restore_epoch": _restore_epoch,
		}
		_event_order.append(identity)
		while _event_order.size() > CACHE_LIMIT:
			_events.erase(_event_order.pop_front())
	var row: Dictionary = _events[identity]
	if StringName(row.get("event_family", &"")) in [&"shot_presentation", &"hud"]:
		row["event_family"] = event_family
	return row


func _set_channel(row: Dictionary, channel: StringName, payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var channels: Dictionary = row["channels"]
	if channels.has(channel) and channels[channel] == payload:
		return
	channels[channel] = payload.duplicate(true)
	row["channels"] = channels
	var observed_usec := Time.get_ticks_usec()
	var observed_frame := Engine.get_process_frames()
	var authority_frame := _authority_frame(row, payload, observed_frame)
	var authority_usec := _authority_usec(row, payload, observed_usec)
	var receipts: Dictionary = row.get("channel_receipts", {})
	receipts[channel] = {
		"observed_usec": observed_usec,
		"observed_frame": observed_frame,
		"authority_usec": authority_usec,
		"authority_frame": authority_frame,
		"latency_usec": maxi(observed_usec - authority_usec, 0),
		"latency_frames": maxi(observed_frame - authority_frame, 0),
		"within_two_rendered_frames": observed_frame - authority_frame <= 2,
	}
	row["channel_receipts"] = receipts
	row["updated_usec"] = observed_usec
	row["updated_frame"] = observed_frame


func _publish(row: Dictionary) -> void:
	_refresh_context_channels(row)
	row["missing_channels"] = _missing_channels(row)
	row["late_channels"] = _late_channels(row)
	var identity := String(row["immutable_identity"])
	_events[identity] = row
	_latest_event_id = identity
	feedback_receipt_updated.emit(row.duplicate(true))


func _missing_channels(row: Dictionary) -> Array[StringName]:
	var family := StringName(row.get("event_family", &""))
	var expected: Array[StringName] = []
	if family == &"player_shot":
		expected.assign([&"authority", &"vfx", &"audio", &"animation", &"hud", &"health_score"])
	elif family == &"player_damage":
		expected.assign([&"damage", &"camera_damage_mask", &"hud", &"health_score"])
	elif family == &"enemy_death":
		expected.assign([&"enemy_authority", &"enemy_death", &"mission", &"hud", &"animation", &"cleanup"])
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
		"voice_receipts": snapshot.get("audio_receipts", []),
		"active_voice_count": snapshot.get("active_audio_voice_count", 0),
		"decoded_voice_count": snapshot.get("decoded_audio_voice_count", 0),
		"cleanup_count": snapshot.get("audio_cleanup_count", 0),
		"active_effect_count": snapshot.get("active_effect_count", 0),
		"bounded_lifetime": true,
	}


func _clear_joined_receipts() -> void:
	_events.clear()
	_event_order.clear()
	_latest_event_id = ""


func _archive_and_clear(reason: StringName) -> void:
	if not _event_order.is_empty():
		for identity: String in _event_order:
			var archived: Dictionary = (_events[identity] as Dictionary).duplicate(true)
			archived["archived_reason"] = reason
			archived["archived_usec"] = Time.get_ticks_usec()
			_previous_receipts.append(archived)
		while _previous_receipts.size() > PREVIOUS_RECEIPT_LIMIT:
			_previous_receipts.pop_front()
	_clear_history.append({
		"reason": reason,
		"run_epoch": _current_run_epoch(),
		"restore_epoch": _restore_epoch,
		"archived_count": _event_order.size(),
		"at_usec": Time.get_ticks_usec(),
	})
	while _clear_history.size() > 16:
		_clear_history.pop_front()
	_clear_joined_receipts()


func _identity_for_event_id(event_id: String) -> String:
	if event_id.begins_with("run-"):
		return event_id
	return "run-%06d:%s" % [_current_run_epoch(), event_id]


func _current_run_epoch() -> int:
	return int(_mission.get("run_epoch")) if _mission != null else 0


func _authority_frame(row: Dictionary, payload: Dictionary, fallback: int) -> int:
	var value := int(payload.get("committed_frame", -1))
	if value >= 0:
		return value
	var receipts: Dictionary = row.get("channel_receipts", {})
	for authority_channel in [&"authority", &"enemy_authority", &"damage", &"mission"]:
		if receipts.has(authority_channel):
			return int((receipts[authority_channel] as Dictionary).get("authority_frame", fallback))
	return fallback


func _authority_usec(row: Dictionary, payload: Dictionary, fallback: int) -> int:
	var value := int(payload.get("committed_at_usec", payload.get("timestamp_usec", -1)))
	if value >= 0:
		return value
	var receipts: Dictionary = row.get("channel_receipts", {})
	for authority_channel in [&"authority", &"enemy_authority", &"damage", &"mission"]:
		if receipts.has(authority_channel):
			return int((receipts[authority_channel] as Dictionary).get("authority_usec", fallback))
	return fallback


func _refresh_context_channels(row: Dictionary) -> void:
	var weapon_state: Dictionary = _weapon.call(&"_mcp_state") if _weapon != null and _weapon.has_method(&"_mcp_state") else {}
	var player_state: Dictionary = _player.call(&"_mcp_state") if _player != null and _player.has_method(&"_mcp_state") else {}
	var mission_state: Dictionary = _mission.call(&"_mcp_state") if _mission != null and _mission.has_method(&"_mcp_state") else {}
	_set_channel(row, &"animation", {
		"weapon_state": weapon_state.get("active_state", &"unknown"),
		"viewmodel_aim": weapon_state.get("viewmodel_settled_aim", false),
		"recoil_peak_serial": weapon_state.get("recoil_peak_serial", 0),
		"observed_frame": Engine.get_process_frames(),
	})
	_set_channel(row, &"hud", {
		"reticle_state": weapon_state.get("reticle_state", {}),
		"magazine": weapon_state.get("magazine", -1),
		"reserve": weapon_state.get("reserve", -1),
		"hud_enabled": _hud.get("_hud_enabled") if _hud != null else false,
		"event_rows": _hud.get("_event_row_receipts") if _hud != null else [],
	})
	_set_channel(row, &"health_score", {
		"health": player_state.get("health", -1),
		"max_health": player_state.get("max_health", -1),
		"eliminations": mission_state.get("elimination_count", -1),
		"deaths": mission_state.get("player_death_count", -1),
		"result": mission_state.get("last_result_snapshot", {}),
	})
	if StringName(row.get("event_family", &"")) == &"enemy_death":
		_set_channel(row, &"cleanup", row.get("cleanup_observation", {"observed": false}))


func _late_channels(row: Dictionary) -> Array[StringName]:
	var late: Array[StringName] = []
	for channel: StringName in (row.get("channel_receipts", {}) as Dictionary):
		if (row["channel_receipts"][channel] as Dictionary).get("within_two_rendered_frames", true) != true:
			late.append(channel)
	return late


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
		"previous_receipts": _previous_receipts.duplicate(true),
		"previous_receipt_count": _previous_receipts.size(),
		"previous_receipt_limit": PREVIOUS_RECEIPT_LIMIT,
		"clear_history": _clear_history.duplicate(true),
	}


func _mcp_state() -> Dictionary:
	var full := snapshot()
	var active: Dictionary = full.get("latest", {})
	var previous_tail: Array[Dictionary] = []
	var start := maxi(0, _previous_receipts.size() - 3)
	for index in range(start, _previous_receipts.size()):
		previous_tail.append(_receipt_summary(_previous_receipts[index]))
	var archived_latest: Dictionary = {}
	if not _previous_receipts.is_empty():
		var archived: Dictionary = _previous_receipts.back()
		archived_latest = {
			"event_id": archived.get("event_id", ""),
			"immutable_identity": archived.get("immutable_identity", ""),
			"event_family": archived.get("event_family", &"unknown"),
			"channel_names": (archived.get("channels", {}) as Dictionary).keys(),
			"missing_channels": archived.get("missing_channels", []),
			"late_channels": archived.get("late_channels", []),
			"ballistic_result": archived.get("ballistic_result", &"unknown"),
			"ammo_commit": archived.get("ammo_commit", -1),
			"archived_reason": archived.get("archived_reason", &""),
		}
	return {
		"family_id": &"joined_combat_feedback_matrix",
		"presentation_only": true,
		"authoritative_calls": [],
		"active_latest": {
			"event_id": active.get("event_id", ""),
			"immutable_identity": active.get("immutable_identity", ""),
			"event_family": active.get("event_family", &"unknown"),
			"channel_names": (active.get("channels", {}) as Dictionary).keys(),
			"missing_channels": active.get("missing_channels", []),
			"late_channels": active.get("late_channels", []),
			"ballistic_result": active.get("ballistic_result", &"unknown"),
			"ammo_commit": active.get("ammo_commit", -1),
		},
		"archived_latest": archived_latest,
		"run_epoch": _current_run_epoch(),
		"cached_event_count": _events.size(),
		"cache_limit": CACHE_LIMIT,
		"latest_event_id": _latest_event_id,
		"latest_receipt": _receipt_summary(full.get("latest", {})),
		"current_event_ids": _event_order.duplicate(),
		"previous_receipt_count": _previous_receipts.size(),
		"previous_receipt_limit": PREVIOUS_RECEIPT_LIMIT,
		"previous_receipt_tail": previous_tail,
		"duplicate_channel_count": _duplicate_channel_count,
		"restore_epoch": _restore_epoch,
		"clear_history": _clear_history.duplicate(true),
	}


func _receipt_summary(row: Dictionary) -> Dictionary:
	if row.is_empty():
		return {}
	var channels: Dictionary = row.get("channels", {})
	return {
		"event_id": row.get("event_id", ""),
		"immutable_identity": row.get("immutable_identity", ""),
		"run_epoch": row.get("run_epoch", 0),
		"event_family": row.get("event_family", &"unknown"),
		"channel_names": channels.keys(),
		"channel_receipts": row.get("channel_receipts", {}),
		"missing_channels": row.get("missing_channels", []),
		"late_channels": row.get("late_channels", []),
		"ballistic_result": row.get("ballistic_result", &"unknown"),
		"surface": row.get("surface", &"unknown"),
		"ammo_commit": row.get("ammo_commit", -1),
		"damage_result": row.get("damage_result", {}),
		"health_score": channels.get(&"health_score", {}),
		"animation": channels.get(&"animation", {}),
		"audio": channels.get(&"audio", {}),
		"cleanup": channels.get(&"cleanup", row.get("cleanup_observation", {})),
		"archived_reason": row.get("archived_reason", &""),
	}
