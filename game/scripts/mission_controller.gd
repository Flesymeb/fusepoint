class_name FusepointMissionController
extends Node

signal mission_event_committed(event: Dictionary)
signal mission_state_changed(state: Dictionary)

const POINT_IDS: Array[StringName] = [&"alpha", &"bravo"]
const BOMB_STAGE_IDS: Array[StringName] = [&"diagnosis", &"power_isolation", &"detonator_removal"]
const HISTORY_LIMIT := 512
const LEADERBOARD_PATH := "user://fusepoint_results.cfg"

@export_range(30.0, 900.0, 1.0) var mission_duration_seconds := 300.0
@export_range(1.0, 30.0, 0.5) var capture_duration_seconds := 12.0
@export var bomb_stage_seconds := Vector3(6.0, 6.0, 6.0)
@export var player_path: NodePath
@export var weapon_controller_path: NodePath
@export var alpha_path: NodePath
@export var bravo_path: NodePath
@export var charlie_path: NodePath
@export var enemy_roster_path: NodePath
@export var hud_timer_path: NodePath
@export var hud_objective_path: NodePath
@export var hud_keys_path: NodePath
@export var hud_progress_path: NodePath
@export var hud_prompt_path: NodePath
@export var hud_event_path: NodePath

var mission_state := &"predeployment"
var remaining_time := 300.0
var capture_points: Dictionary = {}
var route_locks := {&"spawn_to_a": false, &"a_to_b": true, &"b_to_c": true}
var committed_keys: Array[StringName] = []
var overlaps := {&"alpha": false, &"bravo": false, &"charlie": false}
var bomb_state := &"armed"
var bomb_stage_index := 0
var bomb_stage_progress := 0.0
var bomb_completed: Array[bool] = [false, false, false]
var checkpoint_version := 0
var deployment_snapshot: Dictionary = {}
var checkpoint_snapshot: Dictionary = {}
var checkpoint_commit_count := 0
var checkpoint_restore_count := 0
var terminal_commit_count := 0
var terminal_event_id := ""
var elimination_count := 0
var player_death_count := 0
var last_result_snapshot: Dictionary = {}
var event_sequence := 0
var event_history: Array[Dictionary] = []
var last_event: Dictionary = {}
var deployment_commit_count := 0
var enemy_restore_epoch := 0
var checkpoint_restore_in_progress := false
var last_enemy_restore_receipt: Dictionary = {}
var last_checkpoint_restore_receipt: Dictionary = {}

var _active_capture := &""
var _active_bomb_stage := false
var _capture_progress_buckets := {&"alpha": -1, &"bravo": -1}
var _bomb_progress_bucket := -1
var _timer_tick_bucket := -1
var _hud_event_until := 0.0
var _last_announced_event: Dictionary = {}
var _eliminated_actor_ids: Dictionary = {}
var _player_death_event_ids: Dictionary = {}
var _terminal_damage_in_progress := false

@onready var player: CharacterBody3D = get_node(player_path) as CharacterBody3D
@onready var weapon_controller: Node = get_node(weapon_controller_path)
@onready var hud_timer: Label = get_node_or_null(hud_timer_path) as Label
@onready var hud_objective: Label = get_node_or_null(hud_objective_path) as Label
@onready var hud_keys: Label = get_node_or_null(hud_keys_path) as Label
@onready var hud_progress: Label = get_node_or_null(hud_progress_path) as Label
@onready var hud_prompt: Label = get_node_or_null(hud_prompt_path) as Label
@onready var hud_event: Label = get_node_or_null(hud_event_path) as Label
@onready var enemy_roster: Node = get_node_or_null(enemy_roster_path)


func _ready() -> void:
	_initialize_mission_state()
	if player.has_signal(&"authoritative_damage_received"):
		player.connect(&"authoritative_damage_received", _on_player_damaged)
	_sync_presentation()


func _initialize_mission_state() -> void:
	mission_state = &"predeployment"
	remaining_time = mission_duration_seconds
	capture_points = {
		&"alpha": _fresh_point(&"alpha", &"topology_key"),
		&"bravo": _fresh_point(&"bravo", &"isolation_key"),
	}
	route_locks = {&"spawn_to_a": false, &"a_to_b": true, &"b_to_c": true}
	committed_keys.clear()
	overlaps = {&"alpha": false, &"bravo": false, &"charlie": false}
	bomb_state = &"armed"
	bomb_stage_index = 0
	bomb_stage_progress = 0.0
	bomb_completed = [false, false, false]
	checkpoint_version = 0
	deployment_snapshot.clear()
	checkpoint_snapshot.clear()
	checkpoint_commit_count = 0
	checkpoint_restore_count = 0
	enemy_restore_epoch = 0
	checkpoint_restore_in_progress = false
	last_enemy_restore_receipt.clear()
	last_checkpoint_restore_receipt.clear()
	terminal_commit_count = 0
	terminal_event_id = ""
	elimination_count = 0
	player_death_count = 0
	last_result_snapshot.clear()
	_eliminated_actor_ids.clear()
	_player_death_event_ids.clear()
	_terminal_damage_in_progress = false
	_active_capture = &""
	_active_bomb_stage = false
	_timer_tick_bucket = -1


func begin_deployment() -> bool:
	if mission_state != &"predeployment" or deployment_commit_count > 0:
		return false
	deployment_commit_count = 1
	mission_state = &"active_gameplay"
	deployment_snapshot = _build_snapshot()
	_record_event(&"deployment_started", {"remaining_time": remaining_time})
	return true


func reset_for_replay() -> void:
	deployment_commit_count = 0
	event_sequence = 0
	event_history.clear()
	last_event.clear()
	_initialize_mission_state()
	player.call(&"prepare_new_mission")
	_sync_presentation()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interact"):
		_try_begin_bomb_stage()


func _physics_process(delta: float) -> void:
	if mission_state != &"active_gameplay":
		_sync_presentation()
		return
	_commit_timer(delta)
	if mission_state != &"active_gameplay":
		_sync_presentation()
		return
	_tick_capture(delta)
	_tick_bomb(delta)
	_sync_presentation()


func _commit_timer(delta: float) -> void:
	remaining_time = maxf(0.0, remaining_time - delta)
	var bucket := int(floor(remaining_time))
	if bucket != _timer_tick_bucket:
		_timer_tick_bucket = bucket
		_record_event(&"timer_tick", {"remaining_time": remaining_time}, false)
	if remaining_time <= 0.0:
		_submit_terminal(&"bomb_detonated", &"countdown_elapsed")


func report_objective_overlap(objective_id: StringName, inside: bool, body: Node3D) -> void:
	if not overlaps.has(objective_id) or body != player or not body.is_in_group(&"player"):
		return
	if (overlaps[objective_id] == true) == inside:
		return
	overlaps[objective_id] = inside
	_record_event(&"objective_enter" if inside else &"objective_leave", {
		"objective_id": objective_id,
		"player_position": player.global_position,
	})
	if not inside:
		if objective_id == _active_capture:
			_interrupt_capture(objective_id, &"left_radius")
		if objective_id == &"charlie" and _active_bomb_stage:
			_interrupt_bomb(&"left_radius")


func _tick_capture(delta: float) -> void:
	for point_id in POINT_IDS:
		if overlaps[point_id] != true or StringName(capture_points[point_id]["state"]) == &"secured_aegis":
			continue
		if not _point_is_legal(point_id):
			continue
		var point: Dictionary = capture_points[point_id]
		var contesting := _enemy_occupancy(point_id)
		if contesting > 0:
			if StringName(point["state"]) != &"contested_rift":
				point["state"] = &"contested_rift"
				_record_event(&"capture_contested", {"objective_id": point_id, "enemy_count": contesting})
			_active_capture = point_id
			point["progress"] = maxf(0.0, float(point["progress"]) - delta / capture_duration_seconds * 0.5)
			point["contest_enemy_count"] = contesting
			capture_points[point_id] = point
			continue
		if StringName(point["state"]) != &"capturing_aegis":
			point["state"] = &"capturing_aegis"
			point["contest_enemy_count"] = 0
			_active_capture = point_id
			_record_event(&"capture_started", {"objective_id": point_id, "progress": point["progress"]})
		point["progress"] = minf(1.0, float(point["progress"]) + delta / capture_duration_seconds)
		capture_points[point_id] = point
		var bucket := int(floor(float(point["progress"]) * 12.0))
		if bucket != int(_capture_progress_buckets[point_id]):
			_capture_progress_buckets[point_id] = bucket
			_record_event(&"capture_progress", {"objective_id": point_id, "progress": point["progress"]}, false)
		if float(point["progress"]) >= 1.0:
			_complete_capture(point_id)


func _point_is_legal(point_id: StringName) -> bool:
	return point_id == &"alpha" or route_locks[&"a_to_b"] != true


func _interrupt_capture(point_id: StringName, reason: StringName) -> void:
	var point: Dictionary = capture_points[point_id]
	if StringName(point["state"]) not in [&"capturing_aegis", &"contested_rift"]:
		return
	point["state"] = &"held_rift"
	capture_points[point_id] = point
	_active_capture = &""
	_record_event(&"capture_interrupted", {
		"objective_id": point_id, "reason": reason, "progress": point["progress"],
	})


func _enemy_occupancy(point_id: StringName) -> int:
	if enemy_roster == null or not enemy_roster.has_method(&"contest_count"):
		return 0
	var objective := get_node(alpha_path if point_id == &"alpha" else bravo_path) as Node3D
	return int(enemy_roster.call(&"contest_count", point_id, objective.global_position, 4.5))


func report_enemy_event(event: Dictionary) -> void:
	var kind := StringName(event.get("kind", &"enemy_event"))
	if kind == &"died":
		var actor_id := String(event.get("actor_id", ""))
		if not actor_id.is_empty() and not _eliminated_actor_ids.has(actor_id):
			_eliminated_actor_ids[actor_id] = true
			elimination_count += 1
	_record_event(StringName("enemy_%s" % kind), event, false)


func _complete_capture(point_id: StringName) -> void:
	var point: Dictionary = capture_points[point_id]
	if StringName(point["state"]) == &"secured_aegis":
		return
	point["state"] = &"secured_aegis"
	point["owner"] = &"aegis"
	point["progress"] = 1.0
	point["completion_commit_count"] = int(point["completion_commit_count"]) + 1
	capture_points[point_id] = point
	_active_capture = &""
	_record_event(&"capture_completed", {"objective_id": point_id, "commit_count": point["completion_commit_count"]})
	var key_id := StringName(point["key_id"])
	if key_id not in committed_keys:
		committed_keys.append(key_id)
		_record_event(&"key_committed", {"objective_id": point_id, "key_id": key_id, "key_count": committed_keys.size()})
	var route_id := &"a_to_b" if point_id == &"alpha" else &"b_to_c"
	if route_locks[route_id] == true:
		route_locks[route_id] = false
		_record_event(&"route_unlocked", {"route_id": route_id, "objective_id": point_id})
	if point_id == &"bravo":
		bomb_state = &"accessible"
	_commit_checkpoint(point_id)


func _try_begin_bomb_stage() -> void:
	if mission_state != &"active_gameplay" or overlaps[&"charlie"] != true:
		return
	if route_locks[&"b_to_c"] == true:
		_record_event(&"defusal_locked", {"reason": &"keys_required", "key_count": committed_keys.size()})
		return
	if _active_bomb_stage or bomb_stage_index >= BOMB_STAGE_IDS.size():
		return
	_active_bomb_stage = true
	bomb_stage_progress = 0.0
	_bomb_progress_bucket = -1
	bomb_state = [&"diagnosing", &"isolating_power", &"removing_detonator"][bomb_stage_index]
	_record_event(&"defusal_started", {"stage_id": BOMB_STAGE_IDS[bomb_stage_index], "stage_index": bomb_stage_index})


func _tick_bomb(delta: float) -> void:
	if not _active_bomb_stage:
		return
	if overlaps[&"charlie"] != true:
		_interrupt_bomb(&"left_radius")
		return
	if not Input.is_action_pressed(&"interact"):
		_interrupt_bomb(&"input_released")
		return
	var duration := _bomb_stage_duration(bomb_stage_index)
	bomb_stage_progress = minf(1.0, bomb_stage_progress + delta / duration)
	var bucket := int(floor(bomb_stage_progress * 12.0))
	if bucket != _bomb_progress_bucket:
		_bomb_progress_bucket = bucket
		_record_event(&"defusal_progress", {
			"stage_id": BOMB_STAGE_IDS[bomb_stage_index], "progress": bomb_stage_progress,
		}, false)
	if bomb_stage_progress >= 1.0:
		_complete_bomb_stage()


func _bomb_stage_duration(index: int) -> float:
	return [bomb_stage_seconds.x, bomb_stage_seconds.y, bomb_stage_seconds.z][index]


func _interrupt_bomb(reason: StringName) -> void:
	if not _active_bomb_stage:
		return
	_record_event(&"defusal_interrupted", {
		"stage_id": BOMB_STAGE_IDS[bomb_stage_index], "reason": reason, "progress": bomb_stage_progress,
	})
	_active_bomb_stage = false
	bomb_stage_progress = 0.0
	bomb_state = &"accessible"


func _complete_bomb_stage() -> void:
	var stage_id := BOMB_STAGE_IDS[bomb_stage_index]
	if bomb_completed[bomb_stage_index]:
		return
	bomb_completed[bomb_stage_index] = true
	_record_event(&"defusal_completed", {"stage_id": stage_id, "stage_index": bomb_stage_index})
	_active_bomb_stage = false
	bomb_stage_progress = 0.0
	bomb_stage_index += 1
	if bomb_stage_index >= BOMB_STAGE_IDS.size():
		_submit_terminal(&"bomb_defused", &"detonator_removed")
	else:
		bomb_state = &"accessible"


func _on_player_damaged(event: Dictionary) -> void:
	if _active_bomb_stage:
		_interrupt_bomb(&"authoritative_damage")
	var damage_event_id := String(event.get("event_id", ""))
	if float(event.get("health_after", player.get("health"))) <= 0.0 and not _player_death_event_ids.has(damage_event_id):
		_player_death_event_ids[damage_event_id] = true
		player_death_count += 1
	if _terminal_damage_in_progress and damage_event_id == terminal_event_id:
		return
	_record_event(&"player_damaged", {
		"damage_event_id": damage_event_id,
		"shot_id": String(event.get("shot_id", "")),
		"health": event.get("health_after", player.get("health")),
	})


func _submit_terminal(result: StringName, reason: StringName) -> void:
	if terminal_commit_count > 0 or mission_state != &"active_gameplay":
		return
	if result == &"bomb_defused" and remaining_time <= 0.0:
		result = &"bomb_detonated"
		reason = &"countdown_priority"
	terminal_commit_count = 1
	mission_state = result
	bomb_state = &"defused" if result == &"bomb_defused" else &"detonated"
	_active_capture = &""
	_active_bomb_stage = false
	terminal_event_id = "mission-%06d" % (event_sequence + 1)
	player.call(&"enter_terminal_lock", terminal_event_id)
	weapon_controller.call(&"set_gameplay_input_enabled", false)
	if enemy_roster != null:
		enemy_roster.process_mode = Node.PROCESS_MODE_DISABLED
	var bomb_origin := (get_node_or_null(charlie_path) as Node3D).global_position if get_node_or_null(charlie_path) is Node3D else player.global_position
	if result == &"bomb_detonated":
		_terminal_damage_in_progress = true
		player.call(&"apply_authoritative_damage", float(player.get("health")) + float(player.get("max_health")), terminal_event_id, {
			"event_id": terminal_event_id,
			"shot_id": terminal_event_id,
			"source_path": String(get_node_or_null(charlie_path).get_path()) if get_node_or_null(charlie_path) != null else "",
			"source_position": bomb_origin,
			"damage_class": &"bomb_terminal_explosion",
		})
		_terminal_damage_in_progress = false
	_commit_result_record(result)
	_record_event(&"terminal_submitted", {
		"result": result,
		"reason": reason,
		"remaining_time": remaining_time,
		"terminal_event_id": terminal_event_id,
		"world_origin": bomb_origin,
		"result_snapshot": last_result_snapshot,
	})


func result_snapshot() -> Dictionary:
	return last_result_snapshot.duplicate(true)


func _commit_result_record(result: StringName) -> void:
	var success := result == &"bomb_defused"
	var alpha_captured := StringName(capture_points[&"alpha"]["state"]) == &"secured_aegis"
	var bravo_captured := StringName(capture_points[&"bravo"]["state"]) == &"secured_aegis"
	var remaining_seconds := maxi(0, int(floor(remaining_time)))
	var components := {
		"time": remaining_seconds * 10,
		"alpha": 500 if alpha_captured else 0,
		"bravo": 500 if bravo_captured else 0,
		"eliminations": elimination_count * 100,
		"diagnosis": 250 if bomb_completed[0] else 0,
		"power_isolation": 250 if bomb_completed[1] else 0,
		"detonator_removal": 1000 if bomb_completed[2] else 0,
		"deaths": player_death_count * -500,
		"checkpoint_restarts": checkpoint_restore_count * -250,
	}
	var total_score := 0
	for value: int in components.values():
		total_score += value
	var record := {
		"terminal_event_id": terminal_event_id,
		"result": result,
		"success": success,
		"completion_seconds": mission_duration_seconds - remaining_time,
		"remaining_seconds": remaining_seconds,
		"score": total_score,
		"score_components": components,
		"alpha_captured": alpha_captured,
		"bravo_captured": bravo_captured,
		"eliminations": elimination_count,
		"deaths": player_death_count,
		"restart_count": checkpoint_restore_count,
		"selected_loadout": String((weapon_controller.call(&"snapshot_weapon_state") as Dictionary).get("equipped_id", &"ak74m")),
		"timestamp_unix": Time.get_unix_time_from_system(),
		"leaderboard_rank": 0,
		"fastest_success_delta": 0.0,
	}
	var config := ConfigFile.new()
	config.load(LEADERBOARD_PATH)
	var fastest: Dictionary = config.get_value("leaderboard", "fastest_success", {})
	if success:
		if fastest.is_empty():
			record["leaderboard_rank"] = 1
			config.set_value("leaderboard", "fastest_success", record.duplicate(true))
		else:
			var previous_seconds := float(fastest.get("completion_seconds", INF))
			record["fastest_success_delta"] = float(record["completion_seconds"]) - previous_seconds
			if float(record["completion_seconds"]) < previous_seconds:
				record["leaderboard_rank"] = 1
				config.set_value("leaderboard", "fastest_success", record.duplicate(true))
			else:
				record["leaderboard_rank"] = 2
	var recent: Array = config.get_value("history", "recent", [])
	recent.push_front(record.duplicate(true))
	while recent.size() > 10:
		recent.pop_back()
	config.set_value("history", "recent", recent)
	config.save(LEADERBOARD_PATH)
	last_result_snapshot = record


func _commit_checkpoint(point_id: StringName) -> void:
	var next_version := 1 if point_id == &"alpha" else 2
	if checkpoint_version >= next_version:
		return
	checkpoint_version = next_version
	checkpoint_commit_count += 1
	checkpoint_snapshot = _build_snapshot()
	_record_event(&"checkpoint_committed", {
		"objective_id": point_id, "version": checkpoint_version, "commit_count": checkpoint_commit_count,
	})


func request_checkpoint_restore() -> bool:
	if mission_state != &"active_gameplay" or checkpoint_version <= 0 or checkpoint_snapshot.is_empty():
		return false
	var time_before := remaining_time
	var snapshot := checkpoint_snapshot.duplicate(true)
	if not _valid_checkpoint_snapshot(snapshot):
		return false
	if enemy_roster == null or not enemy_roster.has_method(&"begin_restore_epoch"):
		return false
	var rollback_snapshot := _build_snapshot()
	var player_input_before: bool = player.get("gameplay_input_enabled") == true
	var weapon_input_before: bool = weapon_controller.get("gameplay_input_enabled") == true
	player.call(&"set_gameplay_input_enabled", false)
	weapon_controller.call(&"set_gameplay_input_enabled", false)
	enemy_restore_epoch = int(enemy_roster.call(&"begin_restore_epoch"))
	if enemy_restore_epoch < 0:
		player.call(&"set_gameplay_input_enabled", player_input_before)
		weapon_controller.call(&"set_gameplay_input_enabled", weapon_input_before)
		return false
	checkpoint_restore_in_progress = true
	last_checkpoint_restore_receipt = {
		"checkpoint_version": checkpoint_version,
		"restore_epoch": enemy_restore_epoch,
		"committed": false,
		"transient_reset_complete": false,
		"quiescent": true,
	}
	_apply_checkpoint_snapshot(snapshot, minf(time_before, float(snapshot["remaining_time"])))
	player.call(&"restore_checkpoint_state", snapshot["player_transform"], float(snapshot["player_health"]), enemy_restore_epoch)
	weapon_controller.call(&"restore_weapon_state", snapshot["weapon_state"], enemy_restore_epoch)
	if enemy_roster.call(&"apply_restore_snapshot", snapshot.get("enemy_roster", {}), enemy_restore_epoch) != true:
		push_error("Enemy checkpoint restore epoch %d could not apply every actor snapshot" % enemy_restore_epoch)
		return _fail_checkpoint_restore(&"enemy_snapshot_apply_failed", rollback_snapshot, enemy_restore_epoch)
	last_enemy_restore_receipt = enemy_roster.call(&"commit_restore_epoch", enemy_restore_epoch)
	if last_enemy_restore_receipt.is_empty():
		push_error("Enemy checkpoint restore epoch %d could not commit atomically" % enemy_restore_epoch)
		return _fail_checkpoint_restore(&"enemy_commit_failed", rollback_snapshot, enemy_restore_epoch)
	_reset_transient_presentation(enemy_restore_epoch)
	checkpoint_restore_in_progress = false
	checkpoint_restore_count += 1
	last_checkpoint_restore_receipt = {
		"checkpoint_version": int(snapshot.get("version", checkpoint_version)),
		"restore_epoch": enemy_restore_epoch,
		"restore_count": checkpoint_restore_count,
		"restored_actor_count": int(last_enemy_restore_receipt.get("actor_count", 0)),
		"transient_reset_complete": true,
		"committed": true,
		"quiescent": false,
	}
	player.call(&"set_gameplay_input_enabled", player_input_before)
	weapon_controller.call(&"set_gameplay_input_enabled", weapon_input_before)
	_record_event(&"checkpoint_restored", last_checkpoint_restore_receipt.duplicate(true))
	return true


func _valid_checkpoint_snapshot(snapshot: Dictionary) -> bool:
	var required := ["capture_points", "committed_keys", "route_locks", "bomb_state", "bomb_stage_index", "bomb_completed", "remaining_time", "player_transform", "player_health", "weapon_state", "enemy_roster"]
	for key: String in required:
		if not snapshot.has(key):
			return false
	return (snapshot["enemy_roster"] as Dictionary).size() == 18


func _apply_checkpoint_snapshot(snapshot: Dictionary, restored_remaining_time: float) -> void:
	capture_points = snapshot["capture_points"].duplicate(true)
	committed_keys.assign(snapshot["committed_keys"])
	route_locks = snapshot["route_locks"].duplicate(true)
	bomb_state = StringName(snapshot["bomb_state"])
	bomb_stage_index = int(snapshot["bomb_stage_index"])
	bomb_stage_progress = 0.0
	bomb_completed.assign(snapshot["bomb_completed"])
	remaining_time = restored_remaining_time
	_active_capture = &""
	_active_bomb_stage = false
	overlaps = {&"alpha": false, &"bravo": false, &"charlie": false}


func _reset_transient_presentation(epoch: int) -> void:
	_last_announced_event.clear()
	_hud_event_until = 0.0
	if hud_event != null:
		hud_event.text = ""
	var damage_feedback := get_node_or_null("../PlayerDamageFeedback")
	if damage_feedback != null and damage_feedback.has_method(&"reset_for_restore"):
		damage_feedback.call(&"reset_for_restore", epoch)
	var tactical_hud := get_node_or_null("../TacticalHUD")
	if tactical_hud != null and tactical_hud.has_method(&"reset_transient_feedback_for_restore"):
		tactical_hud.call(&"reset_transient_feedback_for_restore", epoch)
	var terminal := get_node_or_null("../TerminalPresentation")
	if terminal != null and terminal.has_method(&"reset_for_restore"):
		terminal.call(&"reset_for_restore", epoch)


func _fail_checkpoint_restore(reason: StringName, rollback_snapshot: Dictionary, epoch: int) -> bool:
	if enemy_roster != null and enemy_roster.has_method(&"abort_restore_epoch"):
		last_enemy_restore_receipt = enemy_roster.call(&"abort_restore_epoch", epoch, rollback_snapshot.get("enemy_roster", {}), reason)
	_apply_checkpoint_snapshot(rollback_snapshot, float(rollback_snapshot.get("remaining_time", remaining_time)))
	player.call(&"restore_checkpoint_state", rollback_snapshot["player_transform"], float(rollback_snapshot["player_health"]), epoch)
	weapon_controller.call(&"restore_weapon_state", rollback_snapshot["weapon_state"], epoch)
	_reset_transient_presentation(epoch)
	checkpoint_restore_in_progress = false
	last_checkpoint_restore_receipt = {
		"checkpoint_version": checkpoint_version,
		"restore_epoch": epoch,
		"restored_actor_count": int(last_enemy_restore_receipt.get("rollback_actor_count", 0)),
		"transient_reset_complete": true,
		"committed": false,
		"quiescent": true,
		"failure_reason": reason,
	}
	return false


func _build_snapshot() -> Dictionary:
	return {
		"schema_version": 2,
		"version": checkpoint_version,
		"remaining_time": remaining_time,
		"mission_state": mission_state,
		"capture_points": capture_points.duplicate(true),
		"committed_keys": committed_keys.duplicate(),
		"route_locks": route_locks.duplicate(true),
		"bomb_state": bomb_state,
		"bomb_stage_index": bomb_stage_index,
		"bomb_completed": bomb_completed.duplicate(),
		"player_transform": player.global_transform,
		"player_health": float(player.get("health")),
		"weapon_state": weapon_controller.call(&"snapshot_weapon_state"),
		"enemy_roster": enemy_roster.call(&"snapshot_all") if enemy_roster != null and enemy_roster.has_method(&"snapshot_all") else {},
	}


func _fresh_point(point_id: StringName, key_id: StringName) -> Dictionary:
	return {
		"point_id": point_id,
		"state": &"held_rift",
		"owner": &"rift",
		"progress": 0.0,
		"key_id": key_id,
		"completion_commit_count": 0,
		"contest_enemy_count": 0,
	}


func objective_state_for(objective_id: StringName) -> Dictionary:
	if objective_id in POINT_IDS:
		var point: Dictionary = capture_points.get(objective_id, {})
		return {
			"objective_id": objective_id,
			"state": point.get("state", &"held_rift"),
			"progress": point.get("progress", 0.0),
			"legal": _point_is_legal(objective_id),
			"overlap": overlaps.get(objective_id, false),
			"contest_enemy_count": point.get("contest_enemy_count", 0),
		}
	return {
		"objective_id": &"charlie",
		"state": bomb_state,
		"stage_id": BOMB_STAGE_IDS[bomb_stage_index] if bomb_stage_index < BOMB_STAGE_IDS.size() else &"complete",
		"progress": bomb_stage_progress,
		"legal": route_locks[&"b_to_c"] != true,
		"overlap": overlaps[&"charlie"],
	}


func _record_event(kind: StringName, payload: Dictionary, announce := true) -> void:
	event_sequence += 1
	last_event = {
		"event_id": "mission-%06d" % event_sequence,
		"sequence": event_sequence,
		"kind": kind,
		"remaining_time": remaining_time,
		"payload": payload.duplicate(true),
	}
	event_history.append(last_event.duplicate(true))
	while event_history.size() > HISTORY_LIMIT:
		event_history.pop_front()
	if announce:
		_hud_event_until = Time.get_ticks_msec() / 1000.0 + 2.2
		_last_announced_event = last_event.duplicate(true)
	mission_event_committed.emit(last_event.duplicate(true))
	mission_state_changed.emit(_mcp_state())


func _sync_presentation() -> void:
	if hud_timer != null:
		var seconds := int(ceil(remaining_time))
		hud_timer.text = "%02d:%02d" % [seconds / 60, seconds % 60]
		hud_timer.modulate = Color(1.0, 0.35, 0.25) if remaining_time <= 30.0 else Color(0.82, 0.94, 1.0)
	if hud_keys != null:
		hud_keys.text = "KEYS  %d / 2" % committed_keys.size()
	if hud_objective != null:
		hud_objective.text = _current_objective_text()
	if hud_progress != null:
		hud_progress.text = _current_progress_text()
	if hud_prompt != null:
		hud_prompt.text = _current_prompt_text()
	if hud_event != null:
		hud_event.text = _event_text(_last_announced_event) if Time.get_ticks_msec() / 1000.0 < _hud_event_until else ""


func _current_objective_text() -> String:
	if mission_state == &"bomb_defused":
		return "MISSION COMPLETE  //  BOMB DEFUSED"
	if mission_state == &"bomb_detonated":
		return "MISSION FAILED  //  DETONATION"
	if StringName(capture_points[&"alpha"]["state"]) != &"secured_aegis":
		return "A  //  RETAKE FOUNDRY GATE"
	if StringName(capture_points[&"bravo"]["state"]) != &"secured_aegis":
		return "B  //  SECURE CRANE YARD"
	return "C  //  DEFUSE ROCKET BAY"


func _current_progress_text() -> String:
	if not _active_capture.is_empty():
		return "CAPTURING  %3d%%" % int(float(capture_points[_active_capture]["progress"]) * 100.0)
	if _active_bomb_stage:
		return "%s  %3d%%" % [String(BOMB_STAGE_IDS[bomb_stage_index]).replace("_", " ").to_upper(), int(bomb_stage_progress * 100.0)]
	return "A %s   B %s   C %s" % [
		_state_chip(StringName(capture_points[&"alpha"]["state"])),
		_state_chip(StringName(capture_points[&"bravo"]["state"])),
		String(bomb_state).to_upper(),
	]


func _current_prompt_text() -> String:
	if overlaps[&"bravo"] == true and route_locks[&"a_to_b"] == true:
		return "BRAVO LOCKED  //  SECURE ALPHA FIRST"
	if overlaps[&"charlie"] == true:
		if route_locks[&"b_to_c"] == true:
			return "CHARLIE LOCKED  //  TWO KEYS REQUIRED"
		if _active_bomb_stage:
			return "HOLD [E]  //  RELEASE OR DAMAGE INTERRUPTS"
		if bomb_stage_index < BOMB_STAGE_IDS.size():
			return "HOLD [E]  //  %s" % String(BOMB_STAGE_IDS[bomb_stage_index]).replace("_", " ").to_upper()
	return ""


func _state_chip(state: StringName) -> String:
	return "SECURED" if state == &"secured_aegis" else "ACTIVE" if state == &"capturing_aegis" else "HOSTILE"


func _event_text(event: Dictionary) -> String:
	if event.is_empty():
		return ""
	var kind := String(event.get("kind", "")).replace("_", " ").to_upper()
	return "AEGIS  //  %s" % kind


func _mcp_state() -> Dictionary:
	return {
		"mission_state": mission_state,
		"remaining_time": remaining_time,
		"timer_owner": get_path(),
		"capture_points": capture_points,
		"committed_keys": committed_keys,
		"route_locks": route_locks,
		"overlaps": overlaps,
		"bomb_state": bomb_state,
		"bomb_stage_index": bomb_stage_index,
		"bomb_stage_progress": bomb_stage_progress,
		"bomb_completed": bomb_completed,
		"checkpoint_version": checkpoint_version,
		"deployment_snapshot_ready": not deployment_snapshot.is_empty(),
		"checkpoint_commit_count": checkpoint_commit_count,
		"checkpoint_restore_count": checkpoint_restore_count,
		"enemy_restore_epoch": enemy_restore_epoch,
		"checkpoint_restore_in_progress": checkpoint_restore_in_progress,
		"last_enemy_restore_receipt": last_enemy_restore_receipt,
		"last_checkpoint_restore_receipt": last_checkpoint_restore_receipt,
		"terminal_commit_count": terminal_commit_count,
		"terminal_event_id": terminal_event_id,
		"elimination_count": elimination_count,
		"player_death_count": player_death_count,
		"last_result_snapshot": last_result_snapshot,
		"active_capture": _active_capture,
		"active_bomb_stage": _active_bomb_stage,
		"event_sequence": event_sequence,
		"last_event": last_event,
		"event_history": event_history,
		"enemy_roster_ready": enemy_roster != null and enemy_roster.get("roster_initialized") == true,
		"enemy_roster_count": (enemy_roster.get("enemies") as Dictionary).size() if enemy_roster != null else 0,
		"enemy_progression_receipts": (enemy_roster.get("progression_receipts") as Array).duplicate(true) if enemy_roster != null else [],
		"history_limit": HISTORY_LIMIT,
		"deployment_commit_count": deployment_commit_count,
	}
