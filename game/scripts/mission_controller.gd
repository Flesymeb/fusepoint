class_name FusepointMissionController
extends Node

signal mission_event_committed(event: Dictionary)
signal mission_state_changed(state: Dictionary)

const POINT_IDS: Array[StringName] = [&"alpha", &"bravo"]
const BOMB_STAGE_IDS: Array[StringName] = [&"diagnosis", &"power_isolation", &"detonator_removal"]
const HISTORY_LIMIT := 512
const TESTER_RECEIPT_LIMIT := 8
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
var terminal_duplicate_submit_count := 0
var terminal_event_id := ""
var tester_countdown_zero_request_count := 0
var elimination_count := 0
var player_death_count := 0
var last_result_snapshot: Dictionary = {}
var event_sequence := 0
var event_history: Array[Dictionary] = []
var last_event: Dictionary = {}
var deployment_commit_count := 0
var enemy_restore_epoch := 0
var checkpoint_restore_in_progress := false
var recovery_input_locked := false
var last_enemy_restore_receipt: Dictionary = {}
var last_checkpoint_restore_receipt: Dictionary = {}
var last_player_restore_receipt: Dictionary = {}
var last_weapon_restore_receipt: Dictionary = {}
var last_recovery_rejection: Dictionary = {}
var last_replay_reset_receipt: Dictionary = {}
var run_epoch := 0
var last_run_epoch_receipt: Dictionary = {}
var tester_alpha_checkpoint_request_count := 0
var last_tester_alpha_checkpoint_receipt: Dictionary = {}
var tester_encounter_request_count := 0
var last_tester_encounter_receipt: Dictionary = {}
var tester_prepared_region := &""
var tester_prepared_region_generation := 0
var tester_terminal_setup_generation := 0
var tester_prepared_terminal_branch := &""
var last_tester_terminal_receipt: Dictionary = {}
var tester_terminal_history: Array[Dictionary] = []
var tester_defusal_setup_generation := 0
var tester_prepared_defusal_stage := -1
var last_tester_defusal_receipt: Dictionary = {}

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
var _recovery_command_serial := 0

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
	_issue_run_epoch(&"initial_boot")
	call_deferred(&"_propagate_run_epoch", true)
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
	recovery_input_locked = false
	last_enemy_restore_receipt.clear()
	last_checkpoint_restore_receipt.clear()
	last_player_restore_receipt.clear()
	last_weapon_restore_receipt.clear()
	last_recovery_rejection.clear()
	last_replay_reset_receipt.clear()
	terminal_commit_count = 0
	terminal_duplicate_submit_count = 0
	terminal_event_id = ""
	tester_countdown_zero_request_count = 0
	tester_prepared_region = &""
	tester_prepared_region_generation = 0
	tester_prepared_terminal_branch = &""
	last_tester_terminal_receipt.clear()
	tester_terminal_history.clear()
	tester_defusal_setup_generation = 0
	tester_prepared_defusal_stage = -1
	last_tester_defusal_receipt.clear()
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
	var candidate_snapshot := _build_snapshot()
	if not _valid_checkpoint_snapshot(candidate_snapshot):
		return false
	var hostile_positions := _enemy_positions_from_snapshot(candidate_snapshot.get("enemy_roster", {}))
	var player_validation: Dictionary = player.call(&"validate_recovery_destination", candidate_snapshot["player_transform"], hostile_positions)
	if player_validation.get("accepted", false) != true:
		return false
	deployment_commit_count = 1
	_propagate_run_epoch(false)
	mission_state = &"active_gameplay"
	deployment_snapshot = candidate_snapshot
	_record_event(&"deployment_started", {
		"remaining_time": remaining_time,
		"snapshot_version": 0,
		"actor_count": (deployment_snapshot["enemy_roster"] as Dictionary).size(),
		"player_occupancy": player_validation,
	})
	return true


func reset_for_replay() -> bool:
	var roster_snapshot: Dictionary = (deployment_snapshot.get("enemy_roster", {}) as Dictionary).duplicate(true) if not deployment_snapshot.is_empty() else {}
	deployment_commit_count = 0
	event_sequence = 0
	event_history.clear()
	last_event.clear()
	_initialize_mission_state()
	_issue_run_epoch(&"new_deployment_lineage")
	_propagate_run_epoch(true)
	player.call(&"prepare_new_mission")
	if not roster_snapshot.is_empty():
		enemy_restore_epoch = int(enemy_roster.call(&"begin_restore_epoch")) if enemy_roster != null and enemy_roster.has_method(&"begin_restore_epoch") else -1
		if enemy_restore_epoch < 0 or enemy_roster.call(&"apply_restore_snapshot", roster_snapshot, enemy_restore_epoch) != true:
			last_replay_reset_receipt = {"accepted": false, "failure_reason": &"roster_snapshot_apply_failed", "restore_epoch": enemy_restore_epoch}
			return false
		last_enemy_restore_receipt = enemy_roster.call(&"commit_restore_epoch", enemy_restore_epoch)
		if last_enemy_restore_receipt.is_empty() or int(last_enemy_restore_receipt.get("actor_count", 0)) != 18:
			last_replay_reset_receipt = {"accepted": false, "failure_reason": &"roster_commit_failed", "restore_epoch": enemy_restore_epoch}
			return false
	last_replay_reset_receipt = {
		"accepted": true,
		"command_type": &"replay_reset",
		"run_epoch": run_epoch,
		"restore_epoch": enemy_restore_epoch,
		"actor_count": int(last_enemy_restore_receipt.get("actor_count", 18 if roster_snapshot.is_empty() else 0)),
		"mission_checkpoint_transaction_requested": false,
		"mission_state": mission_state,
		"checkpoint_version": checkpoint_version,
	}
	_reset_transient_presentation(enemy_restore_epoch)
	_sync_presentation()
	return true


func _issue_run_epoch(reason: StringName) -> int:
	run_epoch += 1
	last_run_epoch_receipt = {
		"run_epoch": run_epoch,
		"reason": reason,
		"issued_at_usec": Time.get_ticks_usec(),
		"monotonic": run_epoch > 0,
	}
	return run_epoch


func _propagate_run_epoch(reset_transients: bool) -> void:
	if weapon_controller != null and weapon_controller.has_method(&"set_run_epoch"):
		weapon_controller.call(&"set_run_epoch", run_epoch, reset_transients)
	if enemy_roster != null and enemy_roster.has_method(&"set_run_epoch"):
		enemy_roster.call(&"set_run_epoch", run_epoch, reset_transients)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"tester_countdown_zero"):
		tester_request_countdown_zero()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"interact"):
		_try_begin_bomb_stage()


func _physics_process(delta: float) -> void:
	if mission_state != &"active_gameplay":
		_sync_presentation()
		return
	if OS.is_debug_build() and (not tester_prepared_terminal_branch.is_empty() or tester_prepared_defusal_stage >= 0):
		# Terminal preparation is intentionally stable: ordinary mission time and
		# capture/defusal progression resume only through the matching advance action.
		_sync_presentation()
		return
	_commit_timer(delta)
	if mission_state != &"active_gameplay":
		_sync_presentation()
		return
	_tick_capture(delta)
	_tick_bomb(delta)
	_sync_presentation()


func tester_request_countdown_zero() -> Dictionary:
	## Bounded no-key diagnostic seam for Runtime/Tester. It only advances the
	## ordinary authoritative countdown path and cannot submit a second event.
	if mission_state != &"active_gameplay" or terminal_commit_count > 0:
		return {
			"accepted": false,
			"reason": &"not_active_or_already_committed",
			"mission_state": mission_state,
			"terminal_commit_count": terminal_commit_count,
		}
	tester_countdown_zero_request_count += 1
	remaining_time = 0.0
	_commit_timer(0.0)
	return {
		"accepted": true,
		"request_count": tester_countdown_zero_request_count,
		"remaining_time": remaining_time,
		"run_epoch": run_epoch,
		"next_path": &"authoritative_timer_committed",
		"terminal_commit_count": terminal_commit_count,
		"terminal_event_id": terminal_event_id,
	}


func tester_prepare_terminal_branch(requested_branch: StringName) -> Dictionary:
	tester_terminal_setup_generation += 1
	var generation := tester_terminal_setup_generation
	var receipt := {
		"setup_id": "tester-terminal-%s-%06d" % [String(requested_branch), generation],
		"branch_id": StringName("terminal:%s" % String(requested_branch)),
		"setup_generation": generation,
		"kind": &"terminal_prepare",
		"requested_branch": requested_branch,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
		"route_acceptance_claimed": false,
		"run_epoch": run_epoch,
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return _store_terminal_tester_receipt(receipt)
	if requested_branch not in [&"success", &"failure"]:
		receipt["failure_reason"] = &"unknown_terminal_branch"
		return _store_terminal_tester_receipt(receipt)
	if mission_state != &"active_gameplay" or terminal_commit_count > 0 or checkpoint_restore_in_progress or recovery_input_locked or not tester_prepared_terminal_branch.is_empty():
		receipt["failure_reason"] = &"authoritative_state_unavailable"
		return _store_terminal_tester_receipt(receipt)
	var run_epoch_before := run_epoch
	var terminal_count_before := terminal_commit_count
	var timer_before := remaining_time
	var frontier_before := _fixture_progression_frontier()
	var preparation_calls: Array[Dictionary] = []
	tester_prepared_terminal_branch = requested_branch
	if requested_branch == &"success":
		if remaining_time <= 0.0:
			tester_prepared_terminal_branch = &""
			receipt["failure_reason"] = &"success_requires_positive_countdown"
			return _store_terminal_tester_receipt(receipt)
		for point_id: StringName in POINT_IDS:
			var was_secured := StringName((capture_points[point_id] as Dictionary).get("state", &"")) == &"secured_aegis"
			var committed := _complete_capture(point_id)
			preparation_calls.append({"api": &"complete_capture", "point_id": point_id, "already_secured": was_secured, "accepted": committed})
			if not committed:
				tester_prepared_terminal_branch = &""
				receipt["preparation_calls"] = preparation_calls
				receipt["failure_reason"] = &"authoritative_capture_preparation_failed"
				return _store_terminal_tester_receipt(receipt)
		while bomb_stage_index < 2:
			_active_bomb_stage = true
			bomb_state = [&"diagnosing", &"isolating_power", &"removing_detonator"][bomb_stage_index]
			bomb_stage_progress = 1.0
			var prepared_stage := BOMB_STAGE_IDS[bomb_stage_index]
			_complete_bomb_stage()
			preparation_calls.append({"api": &"complete_bomb_stage", "stage_id": prepared_stage, "accepted": terminal_commit_count == 0})
		bomb_state = &"accessible"
		bomb_stage_progress = 0.0
		_active_bomb_stage = false
	else:
		remaining_time = minf(remaining_time, 1.0)
		preparation_calls.append({"api": &"authoritative_countdown_owner", "remaining_time": remaining_time, "held_for_advance": true})
	var roster_hold: Dictionary = enemy_roster.call(
		&"tester_prepare_region_presence", &"charlie", generation
	) if enemy_roster != null and enemy_roster.has_method(&"tester_prepare_region_presence") else {}
	if roster_hold.get("accepted", false) != true:
		_restore_frontier(frontier_before)
		tester_prepared_terminal_branch = &""
		receipt["preparation_calls"] = preparation_calls
		receipt["roster_hold"] = roster_hold
		receipt["failure_reason"] = &"charlie_stable_roster_unavailable"
		return _store_terminal_tester_receipt(receipt)
	var presentation_relocation := _tester_terminal_presentation_relocation(requested_branch)
	if presentation_relocation.get("accepted", false) != true:
		var roster_release: Dictionary = enemy_roster.call(
			&"tester_release_prepared_region", &"charlie", generation
		) if enemy_roster != null and enemy_roster.has_method(&"tester_release_prepared_region") else {}
		_restore_frontier(frontier_before)
		tester_prepared_terminal_branch = &""
		receipt["preparation_calls"] = preparation_calls
		receipt["roster_hold"] = roster_hold
		receipt["roster_release"] = roster_release
		receipt["presentation_relocation"] = presentation_relocation
		receipt["failure_reason"] = &"terminal_presentation_destination_rejected"
		return _store_terminal_tester_receipt(receipt)
	receipt.merge({
		"resolved": true,
		"accepted": mission_state == &"active_gameplay" and terminal_commit_count == terminal_count_before and tester_prepared_terminal_branch == requested_branch,
		"prepared_branch": tester_prepared_terminal_branch,
		"preparation_calls": preparation_calls,
		"roster_hold": roster_hold,
		"presentation_relocation": presentation_relocation,
		"mission_snapshot": {
			"remaining_time": remaining_time,
			"capture_points": capture_points.duplicate(true),
			"bomb_state": bomb_state,
			"bomb_stage_index": bomb_stage_index,
			"bomb_completed": bomb_completed.duplicate(),
			"terminal_commit_count": terminal_commit_count,
		},
		"reset_isolation": {
			"run_epoch_unchanged": run_epoch == run_epoch_before,
			"terminal_state_unchanged": terminal_commit_count == terminal_count_before and terminal_event_id.is_empty(),
			"countdown_not_increased": remaining_time <= timer_before + 0.001,
			"presentation_not_started": mission_state == &"active_gameplay",
			"result_not_written": last_result_snapshot.is_empty(),
			"charlie_roster_held": roster_hold.get("accepted", false) == true,
			"stable_until_matching_advance": true,
			"route_acceptance_claimed": false,
		},
		"failure_reason": &"",
	}, true)
	_record_event(&"tester_terminal_prepared", receipt.duplicate(true), false)
	return _store_terminal_tester_receipt(receipt)


func _tester_terminal_presentation_relocation(branch_id: StringName) -> Dictionary:
	var charlie_objective := get_node(charlie_path) as Node3D
	var authored_anchor := charlie_objective.get_parent().get_node_or_null("ProductAnchors/Charlie") as Node3D
	if authored_anchor == null:
		return {"accepted": false, "failure_reason": &"authored_charlie_anchor_missing"}
	var candidates: Array[Vector3] = [
		Vector3(-9.0, 0.615, -2.0),
		Vector3(9.0, 0.615, -3.0),
		Vector3(5.0, 0.615, 2.0),
		Vector3(-4.0, 0.615, -8.0),
	]
	var attempts: Array[Dictionary] = []
	for offset: Vector3 in candidates:
		var destination := authored_anchor.global_position + offset
		var direction := authored_anchor.global_position - destination
		var yaw := atan2(-direction.x, -direction.z)
		var target := Transform3D(Basis(Vector3.UP, yaw), destination)
		var relocation: Dictionary = player.call(&"tester_relocate_for_fixture", target, StringName("terminal:%s" % String(branch_id)))
		attempts.append({"offset": offset, "relocation": relocation})
		if relocation.get("accepted", false) == true:
			return {
				"accepted": true,
				"anchor_path": authored_anchor.get_path(),
				"offset": offset,
				"relocation": relocation,
				"attempt_count": attempts.size(),
				"camera_subject": charlie_objective.get_path(),
			}
	return {"accepted": false, "failure_reason": &"no_clear_charlie_presentation_offset", "attempts": attempts}


func tester_prepare_defusal_stage() -> Dictionary:
	tester_defusal_setup_generation += 1
	var generation := tester_defusal_setup_generation
	var receipt := {
		"setup_id": "tester-defusal-%06d" % generation,
		"branch_id": StringName("defusal:%d" % bomb_stage_index),
		"setup_generation": generation,
		"kind": &"defusal_stage_prepare",
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
		"route_acceptance_claimed": false,
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		last_tester_defusal_receipt = receipt
		return receipt.duplicate(true)
	if mission_state != &"active_gameplay" or terminal_commit_count > 0 or tester_prepared_defusal_stage >= 0 or not tester_prepared_terminal_branch.is_empty():
		receipt["failure_reason"] = &"authoritative_state_unavailable"
		last_tester_defusal_receipt = receipt
		return receipt.duplicate(true)
	var frontier_before := _fixture_progression_frontier()
	for point_id: StringName in POINT_IDS:
		if StringName((capture_points[point_id] as Dictionary).get("state", &"")) != &"secured_aegis":
			_complete_capture(point_id)
	if bomb_stage_index >= BOMB_STAGE_IDS.size():
		_restore_frontier(frontier_before)
		receipt["failure_reason"] = &"all_stages_complete"
		last_tester_defusal_receipt = receipt
		return receipt.duplicate(true)
	var roster_hold: Dictionary = enemy_roster.call(&"tester_prepare_region_presence", &"charlie", generation) if enemy_roster != null and enemy_roster.has_method(&"tester_prepare_region_presence") else {}
	if roster_hold.get("accepted", false) != true:
		_restore_frontier(frontier_before)
		receipt["roster_hold"] = roster_hold
		receipt["failure_reason"] = &"charlie_stable_roster_unavailable"
		last_tester_defusal_receipt = receipt
		return receipt.duplicate(true)
	var relocation := _tester_terminal_presentation_relocation(&"defusal")
	if relocation.get("accepted", false) != true:
		_restore_frontier(frontier_before)
		receipt["relocation"] = relocation
		receipt["failure_reason"] = &"defusal_presentation_destination_rejected"
		last_tester_defusal_receipt = receipt
		return receipt.duplicate(true)
	tester_prepared_defusal_stage = bomb_stage_index
	_active_bomb_stage = true
	bomb_stage_progress = 0.0
	bomb_state = [&"diagnosing", &"isolating_power", &"removing_detonator"][bomb_stage_index]
	receipt.merge({
		"resolved": true,
		"accepted": true,
		"stage_id": BOMB_STAGE_IDS[bomb_stage_index],
		"stage_index": bomb_stage_index,
		"completed_stage_count": bomb_stage_index,
		"relocation": relocation,
		"roster_hold": roster_hold,
		"reset_isolation": {
			"terminal_uncommitted": terminal_commit_count == 0,
			"stable_until_matching_advance": true,
			"route_acceptance_claimed": false,
		},
		"failure_reason": &"",
	}, true)
	last_tester_defusal_receipt = receipt.duplicate(true)
	_record_event(&"tester_defusal_stage_prepared", receipt.duplicate(true), false)
	return receipt.duplicate(true)


func tester_advance_defusal_stage(expected_generation: int) -> Dictionary:
	var receipt := {
		"setup_id": "tester-defusal-advance-%06d" % tester_defusal_setup_generation,
		"branch_id": StringName("defusal:%d" % tester_prepared_defusal_stage),
		"setup_generation": tester_defusal_setup_generation,
		"kind": &"defusal_stage_advance",
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
		"route_acceptance_claimed": false,
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
	elif expected_generation != tester_defusal_setup_generation:
		receipt["failure_reason"] = &"stale_setup_generation"
	elif tester_prepared_defusal_stage != bomb_stage_index or not _active_bomb_stage:
		receipt["failure_reason"] = &"mismatched_prepared_stage"
	else:
		# Defusal preparation borrows the stable Charlie roster hold. Release that
		# exact generation as part of the matching advancement before committing the
		# stage, otherwise a completed stage leaves the fixture pinned and prevents
		# the next 1/3 -> 2/3 preparation from resolving.
		var roster_release: Dictionary = enemy_roster.call(
			&"tester_release_prepared_region", &"charlie", expected_generation
		) if enemy_roster != null and enemy_roster.has_method(&"tester_release_prepared_region") else {}
		if roster_release.get("accepted", false) != true:
			receipt["roster_release"] = roster_release
			receipt["failure_reason"] = &"charlie_roster_release_failed"
		else:
			var completed_stage := BOMB_STAGE_IDS[bomb_stage_index]
			bomb_stage_progress = 1.0
			tester_prepared_defusal_stage = -1
			_complete_bomb_stage()
			receipt.merge({
				"resolved": true,
				"accepted": true,
				"stage_id": completed_stage,
				"completed_stage_count": bomb_stage_index,
				"terminal_commit_count": terminal_commit_count,
				"roster_release": roster_release,
				"reset_isolation": {
					"prepared_fixture_cleared": tester_prepared_defusal_stage < 0,
					"completed_stage_latched": completed_stage in BOMB_STAGE_IDS and bomb_completed[BOMB_STAGE_IDS.find(completed_stage)],
					"charlie_roster_hold_released": roster_release.get("accepted", false) == true,
					"route_acceptance_claimed": false,
				},
				"failure_reason": &"",
			}, true)
	last_tester_defusal_receipt = receipt.duplicate(true)
	_record_event(&"tester_defusal_stage_advanced", receipt.duplicate(true), false)
	return receipt.duplicate(true)


func tester_advance_terminal_branch(expected_branch: StringName, expected_generation: int) -> Dictionary:
	var receipt := {
		"setup_id": "tester-terminal-advance-%06d" % tester_terminal_setup_generation,
		"branch_id": StringName("terminal:%s" % String(tester_prepared_terminal_branch)),
		"setup_generation": tester_terminal_setup_generation,
		"kind": &"terminal_advance",
		"requested": true,
		"resolved": false,
		"accepted": false,
		"prepared_branch": tester_prepared_terminal_branch,
		"expected_branch": expected_branch,
		"expected_generation": expected_generation,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
		"route_acceptance_claimed": false,
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return _store_terminal_tester_receipt(receipt)
	if expected_generation != tester_terminal_setup_generation:
		receipt["failure_reason"] = &"stale_setup_generation"
		return _store_terminal_tester_receipt(receipt)
	if expected_branch != tester_prepared_terminal_branch or expected_branch not in [&"success", &"failure"]:
		receipt["failure_reason"] = &"mismatched_prepared_branch"
		return _store_terminal_tester_receipt(receipt)
	if mission_state != &"active_gameplay" or terminal_commit_count > 0:
		receipt["failure_reason"] = &"authoritative_state_unavailable"
		return _store_terminal_tester_receipt(receipt)
	if expected_branch == &"success" and (bomb_stage_index != 2 or remaining_time <= 0.0):
		receipt["failure_reason"] = &"success_preparation_incomplete"
		return _store_terminal_tester_receipt(receipt)
	var roster_release: Dictionary = enemy_roster.call(
		&"tester_release_prepared_region", &"charlie", expected_generation
	) if enemy_roster != null and enemy_roster.has_method(&"tester_release_prepared_region") else {}
	if roster_release.get("accepted", false) != true:
		receipt["roster_release"] = roster_release
		receipt["failure_reason"] = &"charlie_roster_release_failed"
		return _store_terminal_tester_receipt(receipt)
	var terminal_count_before := terminal_commit_count
	tester_prepared_terminal_branch = &""
	if expected_branch == &"success":
		_active_bomb_stage = true
		bomb_state = &"removing_detonator"
		bomb_stage_progress = 1.0
		_complete_bomb_stage()
	else:
		remaining_time = 0.0
		_commit_timer(0.0)
	receipt.merge({
		"resolved": true,
		"accepted": terminal_commit_count == terminal_count_before + 1 and terminal_event_id.length() > 0 and mission_state == (&"bomb_defused" if expected_branch == &"success" else &"bomb_detonated"),
		"terminal_event_id": terminal_event_id,
		"terminal_commit_count": terminal_commit_count,
		"duplicate_terminal_submit_count": terminal_duplicate_submit_count,
		"authoritative_api": &"complete_bomb_stage" if expected_branch == &"success" else &"commit_timer",
		"roster_release": roster_release,
		"reset_isolation": {
			"single_terminal_commit": terminal_commit_count == terminal_count_before + 1,
			"prepared_fixture_cleared": tester_prepared_terminal_branch.is_empty(),
			"result_owned_by_mission": not last_result_snapshot.is_empty(),
			"charlie_roster_hold_released": roster_release.get("accepted", false) == true,
			"route_acceptance_claimed": false,
		},
		"failure_reason": &"" if terminal_commit_count == terminal_count_before + 1 else &"authoritative_terminal_commit_failed",
	}, true)
	return _store_terminal_tester_receipt(receipt)


func _store_terminal_tester_receipt(receipt: Dictionary) -> Dictionary:
	last_tester_terminal_receipt = receipt.duplicate(true)
	tester_terminal_history.append(last_tester_terminal_receipt.duplicate(true))
	while tester_terminal_history.size() > TESTER_RECEIPT_LIMIT:
		tester_terminal_history.pop_front()
	return last_tester_terminal_receipt.duplicate(true)


func tester_prepare_alpha_checkpoint() -> Dictionary:
	tester_alpha_checkpoint_request_count += 1
	var setup_id := "tester-alpha-checkpoint-%06d" % tester_alpha_checkpoint_request_count
	var timer_before := remaining_time
	var event_sequence_before := event_sequence
	var run_epoch_before := run_epoch
	last_tester_alpha_checkpoint_receipt = {
		"setup_id": setup_id,
		"kind": &"alpha_checkpoint_entry",
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"run_epoch": run_epoch,
	}
	if not OS.is_debug_build():
		last_tester_alpha_checkpoint_receipt["failure_reason"] = &"release_build_forbidden"
		return last_tester_alpha_checkpoint_receipt.duplicate(true)
	if mission_state != &"active_gameplay" or deployment_snapshot.is_empty() or checkpoint_restore_in_progress or recovery_input_locked:
		last_tester_alpha_checkpoint_receipt["failure_reason"] = &"authoritative_state_unavailable"
		return last_tester_alpha_checkpoint_receipt.duplicate(true)
	if checkpoint_version > 0 or StringName((capture_points[&"alpha"] as Dictionary).get("state", &"")) == &"secured_aegis":
		last_tester_alpha_checkpoint_receipt["failure_reason"] = &"alpha_checkpoint_already_committed"
		return last_tester_alpha_checkpoint_receipt.duplicate(true)
	var presence_receipt: Dictionary = enemy_roster.call(&"tester_request_alpha_presence") if enemy_roster != null and enemy_roster.has_method(&"tester_request_alpha_presence") else {}
	if presence_receipt.get("accepted", false) != true:
		last_tester_alpha_checkpoint_receipt["failure_reason"] = &"alpha_presence_unavailable"
		last_tester_alpha_checkpoint_receipt["enemy_presence"] = presence_receipt
		return last_tester_alpha_checkpoint_receipt.duplicate(true)
	var hostile_positions := _enemy_positions_from_snapshot(enemy_roster.call(&"snapshot_all"))
	var target_receipt := _tester_alpha_checkpoint_transform(hostile_positions)
	if target_receipt.get("accepted", false) != true:
		last_tester_alpha_checkpoint_receipt["failure_reason"] = &"alpha_checkpoint_destination_rejected"
		last_tester_alpha_checkpoint_receipt["destination"] = target_receipt
		return last_tester_alpha_checkpoint_receipt.duplicate(true)
	var point_before: Dictionary = (capture_points[&"alpha"] as Dictionary).duplicate(true)
	var keys_before := committed_keys.duplicate()
	var locks_before := route_locks.duplicate(true)
	var checkpoint_snapshot_before := checkpoint_snapshot.duplicate(true)
	var checkpoint_version_before := checkpoint_version
	var checkpoint_commit_before := checkpoint_commit_count
	_complete_capture(&"alpha")
	if checkpoint_version != 1 or checkpoint_commit_count != checkpoint_commit_before + 1 or checkpoint_snapshot.is_empty():
		capture_points[&"alpha"] = point_before
		committed_keys.assign(keys_before)
		route_locks = locks_before
		checkpoint_snapshot = checkpoint_snapshot_before
		checkpoint_version = checkpoint_version_before
		checkpoint_commit_count = checkpoint_commit_before
		last_tester_alpha_checkpoint_receipt["failure_reason"] = &"authoritative_checkpoint_commit_failed"
		return last_tester_alpha_checkpoint_receipt.duplicate(true)
	checkpoint_snapshot["player_transform"] = target_receipt["transform"]
	checkpoint_snapshot["tester_setup"] = {
		"setup_id": setup_id,
		"checkpoint_relocation": &"authored_alpha_anchor",
		"route_acceptance_claimed": false,
	}
	var reset_isolation := {
		"run_epoch_unchanged": run_epoch == run_epoch_before,
		"terminal_state_unchanged": terminal_commit_count == 0 and terminal_event_id.is_empty(),
		"timer_not_increased": remaining_time <= timer_before + 0.001,
		"restore_not_started": not checkpoint_restore_in_progress and not recovery_input_locked,
		"single_checkpoint_commit": checkpoint_commit_count == checkpoint_commit_before + 1,
	}
	last_tester_alpha_checkpoint_receipt.merge({
		"resolved": true,
		"accepted": true,
		"checkpoint_version": checkpoint_version,
		"checkpoint_commit_count": checkpoint_commit_count,
		"checkpoint_snapshot": checkpoint_snapshot.duplicate(true),
		"key_commit_count": committed_keys.size(),
		"enemy_presence": presence_receipt,
		"destination": target_receipt,
		"event_sequence_before": event_sequence_before,
		"event_sequence_after": event_sequence,
		"reset_isolation": reset_isolation,
		"failure_reason": &"",
	}, true)
	_record_event(&"tester_alpha_checkpoint_resolved", last_tester_alpha_checkpoint_receipt.duplicate(true), false)
	return last_tester_alpha_checkpoint_receipt.duplicate(true)


func tester_prepare_encounter(region_id: StringName) -> Dictionary:
	## Non-release combat fixture. It changes only roster activation authority;
	## objectives, checkpoints, damage, terminal state, and player transform stay
	## untouched until a separate, generation-matched commit is requested.
	tester_encounter_request_count += 1
	var setup_id := "tester-encounter-%s-%06d" % [region_id, tester_encounter_request_count]
	var setup_generation := tester_encounter_request_count
	var timer_before := remaining_time
	var run_epoch_before := run_epoch
	var frontier_before := _fixture_progression_frontier()
	var terminal_before := terminal_commit_count
	last_tester_encounter_receipt = {
		"setup_id": setup_id,
		"branch_id": StringName("combat:%s" % String(region_id)),
		"setup_generation": setup_generation,
		"kind": &"encounter_prepare",
		"requested_region": region_id,
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
		"run_epoch": run_epoch,
		"route_acceptance_claimed": false,
	}
	if not OS.is_debug_build():
		last_tester_encounter_receipt["failure_reason"] = &"release_build_forbidden"
		return last_tester_encounter_receipt.duplicate(true)
	if region_id not in [&"alpha", &"bravo", &"charlie"]:
		last_tester_encounter_receipt["failure_reason"] = &"unknown_region"
		return last_tester_encounter_receipt.duplicate(true)
	if mission_state != &"active_gameplay" or deployment_snapshot.is_empty() or checkpoint_restore_in_progress or recovery_input_locked:
		last_tester_encounter_receipt["failure_reason"] = &"authoritative_state_unavailable"
		return last_tester_encounter_receipt.duplicate(true)
	var progression: Dictionary = enemy_roster.call(&"tester_prepare_region_presence", region_id, setup_generation) if enemy_roster != null and enemy_roster.has_method(&"tester_prepare_region_presence") else {}
	var roster_state: Dictionary = enemy_roster.call(&"_mcp_state") if enemy_roster != null and enemy_roster.has_method(&"_mcp_state") else {}
	var expected_count := 3 if region_id == &"alpha" else 5 if region_id == &"bravo" else 10
	var actor_ids: Array[String] = []
	var distinct_roles := {}
	var distinct_slots := {}
	for actor: Dictionary in roster_state.get("actor_index", []):
		if StringName(actor.get("region", &"")) != region_id:
			continue
		actor_ids.append(String(actor.get("id", "")))
		distinct_roles[String(actor.get("role", ""))] = true
		distinct_slots[String(actor.get("slot", actor.get("route_slot", "")))] = true
	actor_ids.sort()
	var frontier_after := _fixture_progression_frontier()
	var validation := {
		"roster_accepted": progression.get("accepted", false) == true,
		"region_matched": StringName(progression.get("active_region", &"")) == region_id,
		"active_count_matched": int(progression.get("active_count", 0)) == expected_count,
		"actor_id_count_matched": actor_ids.size() == expected_count,
		"frontier_unchanged": frontier_after == frontier_before,
		"terminal_unchanged": terminal_commit_count == terminal_before,
	}
	var accepted: bool = not validation.values().has(false)
	if not accepted:
		last_tester_encounter_receipt.merge({
			"resolved": true,
			"failure_reason": &"encounter_preparation_validation_failed",
			"validation": validation,
			"progression": progression,
			"frontier_unchanged": frontier_after == frontier_before,
		}, true)
		return last_tester_encounter_receipt.duplicate(true)
	tester_prepared_region = region_id
	tester_prepared_region_generation = setup_generation
	last_tester_encounter_receipt.merge({
		"resolved": true,
		"accepted": true,
		"prepared_region": region_id,
		"prepared_count": expected_count,
		"stable_actor_ids": actor_ids,
		"distinct_role_count": distinct_roles.size(),
		"distinct_slot_count": distinct_slots.size(),
		"validation": validation,
		"prerequisite_commits": [],
		"progression": progression,
		"checkpoint_version": checkpoint_version,
		"reset_isolation": {
			"run_epoch_unchanged": run_epoch == run_epoch_before,
			"timer_not_increased": remaining_time <= timer_before + 0.001,
			"terminal_state_unchanged": terminal_commit_count == terminal_before,
			"capture_points_unchanged": frontier_after == frontier_before,
			"stable_identity_count": int(roster_state.get("stable_identity_count", 0)),
			"no_actor_killed": int(progression.get("active_alive_count", 0)) == expected_count,
			"route_acceptance_claimed": false,
			"player_relocated": false,
		},
		"failure_reason": &"",
	}, true)
	_record_event(&"tester_encounter_prepared", last_tester_encounter_receipt.duplicate(true), false)
	return last_tester_encounter_receipt.duplicate(true)


func tester_commit_prepared_encounter(expected_region: StringName = &"", expected_generation := -1) -> Dictionary:
	var region_id := tester_prepared_region
	var receipt := {
		"setup_id": "tester-encounter-commit-%06d" % tester_encounter_request_count,
		"branch_id": StringName("combat:%s" % String(region_id)),
		"setup_generation": tester_prepared_region_generation,
		"kind": &"encounter_commit",
		"requested": true,
		"resolved": false,
		"accepted": false,
		"prepared_region": region_id,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
		"route_acceptance_claimed": false,
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	if expected_generation >= 0 and expected_generation != tester_prepared_region_generation:
		receipt["failure_reason"] = &"stale_setup_generation"
		return receipt
	if not expected_region.is_empty() and expected_region != region_id:
		receipt["failure_reason"] = &"mismatched_prepared_branch"
		return receipt
	if mission_state != &"active_gameplay" or region_id not in [&"alpha", &"bravo"]:
		receipt["failure_reason"] = &"no_committable_prepared_capture"
		return receipt
	if not _point_is_legal(region_id):
		receipt["failure_reason"] = &"ordinary_capture_prerequisite_missing"
		return receipt
	var checkpoint_before := checkpoint_version
	var timer_before := remaining_time
	var committed := _complete_capture(region_id)
	receipt.merge({
		"resolved": true,
		"accepted": committed,
		"checkpoint_before": checkpoint_before,
		"checkpoint_after": checkpoint_version,
		"timer_not_increased": remaining_time <= timer_before + 0.001,
		"failure_reason": &"" if committed else &"authoritative_capture_commit_failed",
	}, true)
	if committed:
		var roster_release: Dictionary = enemy_roster.call(
			&"tester_release_prepared_region",
			region_id,
			tester_prepared_region_generation,
		) if enemy_roster != null and enemy_roster.has_method(&"tester_release_prepared_region") else {}
		receipt["roster_preparation_release"] = roster_release
		tester_prepared_region = &""
		tester_prepared_region_generation = 0
	return receipt


func tester_advance_prepared_encounter(expected_region: StringName = &"", expected_generation := -1) -> Dictionary:
	var region_id := tester_prepared_region
	var generation := tester_prepared_region_generation
	var receipt := {
		"setup_id": "tester-encounter-advance-%06d" % tester_encounter_request_count,
		"branch_id": StringName("combat:%s" % String(region_id)),
		"setup_generation": generation,
		"kind": &"encounter_advance",
		"requested": true,
		"resolved": false,
		"accepted": false,
		"prepared_region": region_id,
		"non_release": OS.is_debug_build(),
		"release_guard": &"OS.is_debug_build",
		"route_acceptance_claimed": false,
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	if expected_generation >= 0 and expected_generation != generation:
		receipt["failure_reason"] = &"stale_setup_generation"
		return receipt
	if not expected_region.is_empty() and expected_region != region_id:
		receipt["failure_reason"] = &"mismatched_prepared_branch"
		return receipt
	if mission_state != &"active_gameplay" or region_id not in [&"alpha", &"bravo", &"charlie"]:
		receipt["failure_reason"] = &"no_advanceable_prepared_encounter"
		return receipt
	var frontier_before := _fixture_progression_frontier()
	var terminal_before := terminal_commit_count
	var checkpoint_before := checkpoint_version
	var timer_before := remaining_time
	var roster_release: Dictionary = enemy_roster.call(
		&"tester_release_prepared_region",
		region_id,
		generation,
	) if enemy_roster != null and enemy_roster.has_method(&"tester_release_prepared_region") else {}
	var accepted: bool = roster_release.get("accepted", false) == true
	receipt.merge({
		"resolved": roster_release.get("resolved", false) == true,
		"accepted": accepted,
		"active_stable_ids": roster_release.get("active_stable_ids", []),
		"region_count": roster_release.get("active_count", 0),
		"roster_release": roster_release,
		"reset_isolation": {
			"capture_points_unchanged": _fixture_progression_frontier() == frontier_before,
			"checkpoint_version_unchanged": checkpoint_version == checkpoint_before,
			"terminal_state_unchanged": terminal_commit_count == terminal_before,
			"timer_not_increased": remaining_time <= timer_before + 0.001,
			"route_acceptance_claimed": false,
		},
		"failure_reason": &"" if accepted else roster_release.get("failure_reason", &"roster_release_failed"),
	}, true)
	if accepted:
		tester_prepared_region = &""
		tester_prepared_region_generation = 0
	last_tester_encounter_receipt = receipt.duplicate(true)
	_record_event(&"tester_encounter_advanced", receipt.duplicate(true), false)
	return receipt


func _tester_alpha_checkpoint_transform(hostile_positions: Array) -> Dictionary:
	var alpha_objective := get_node(alpha_path) as Node3D
	var authored_anchor := alpha_objective.get_parent().get_node_or_null("ProductAnchors/Alpha") as Node3D
	if authored_anchor == null:
		return {"accepted": false, "failure_reason": &"authored_alpha_anchor_missing"}
	var offsets: Array[Vector3] = [
		Vector3(3.0, 0.0, 0.0), Vector3(-3.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 3.0), Vector3(0.0, 0.0, -3.0),
		Vector3(4.0, 0.0, 2.0), Vector3(-4.0, 0.0, 2.0),
	]
	var attempts: Array[Dictionary] = []
	for offset: Vector3 in offsets:
		var candidate := Transform3D(player.global_basis, authored_anchor.global_position + Vector3.UP * 0.9 + offset)
		var validation: Dictionary = player.call(&"validate_recovery_destination", candidate, hostile_positions)
		attempts.append({"offset": offset, "validation": validation})
		if validation.get("accepted", false) == true:
			return {
				"accepted": true,
				"anchor_path": authored_anchor.get_path(),
				"offset": offset,
				"transform": candidate,
				"validation": validation,
				"attempt_count": attempts.size(),
			}
	return {"accepted": false, "failure_reason": &"no_clear_authored_alpha_offset", "attempts": attempts}


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


func _complete_capture(point_id: StringName) -> bool:
	var point: Dictionary = capture_points[point_id]
	if StringName(point["state"]) == &"secured_aegis":
		return true
	var frontier_before := _capture_frontier()
	var key_was_committed := StringName(point["key_id"]) in committed_keys
	var route_id := &"a_to_b" if point_id == &"alpha" else &"b_to_c"
	var route_was_locked: bool = route_locks[route_id] == true
	point["state"] = &"secured_aegis"
	point["owner"] = &"aegis"
	point["progress"] = 1.0
	point["completion_commit_count"] = int(point["completion_commit_count"]) + 1
	capture_points[point_id] = point
	_active_capture = &""
	var key_id := StringName(point["key_id"])
	if key_id not in committed_keys:
		committed_keys.append(key_id)
	if route_locks[route_id] == true:
		route_locks[route_id] = false
	if point_id == &"bravo":
		bomb_state = &"accessible"
	var checkpoint_receipt := _commit_checkpoint(point_id)
	if checkpoint_receipt.get("accepted", false) != true:
		_restore_frontier(frontier_before)
		var rollback_progression := _sync_roster_after_frontier_restore()
		_record_event(&"checkpoint_rejected", {
			"objective_id": point_id,
			"reason": checkpoint_receipt.get("failure_reason", &"enemy_progression_not_ready"),
			"progression": checkpoint_receipt.get("progression", {}),
			"rollback_progression": rollback_progression,
			"frontier_rolled_back": true,
		})
		return false
	_record_event(&"capture_completed", {"objective_id": point_id, "commit_count": point["completion_commit_count"]})
	if not key_was_committed:
		_record_event(&"key_committed", {"objective_id": point_id, "key_id": key_id, "key_count": committed_keys.size()})
	if route_was_locked:
		_record_event(&"route_unlocked", {"route_id": route_id, "objective_id": point_id})
	_record_event(&"checkpoint_committed", {
		"objective_id": point_id,
		"version": checkpoint_version,
		"commit_count": checkpoint_commit_count,
		"progression": checkpoint_receipt.get("progression", {}),
		"timer_monotonic": checkpoint_receipt.get("timer_monotonic", false),
	})
	return true


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
	if terminal_commit_count > 0:
		terminal_duplicate_submit_count += 1
		return
	if mission_state != &"active_gameplay":
		return
	if result == &"bomb_defused" and remaining_time <= 0.0:
		result = &"bomb_detonated"
		reason = &"countdown_priority"
	terminal_commit_count = 1
	mission_state = result
	bomb_state = &"defused" if result == &"bomb_defused" else &"detonated"
	_active_capture = &""
	_active_bomb_stage = false
	terminal_event_id = "run-%06d:mission-%06d" % [run_epoch, event_sequence + 1]
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


func _commit_checkpoint(point_id: StringName) -> Dictionary:
	var next_version := 1 if point_id == &"alpha" else 2
	if checkpoint_version >= next_version:
		return {"accepted": false, "failure_reason": &"checkpoint_version_already_committed"}
	var timer_before := remaining_time
	var progression_receipt: Dictionary = enemy_roster.call(&"sync_progression_for_checkpoint") if enemy_roster != null and enemy_roster.has_method(&"sync_progression_for_checkpoint") else {}
	if progression_receipt.get("accepted", false) != true:
		return {"accepted": false, "failure_reason": &"enemy_progression_not_ready", "progression": progression_receipt}
	checkpoint_version = next_version
	checkpoint_commit_count += 1
	var candidate_snapshot := _build_snapshot()
	if not _valid_checkpoint_snapshot(candidate_snapshot):
		checkpoint_version -= 1
		checkpoint_commit_count -= 1
		return {"accepted": false, "failure_reason": &"checkpoint_snapshot_invalid", "progression": progression_receipt}
	checkpoint_snapshot = candidate_snapshot
	return {
		"accepted": true,
		"progression": progression_receipt,
		"version": checkpoint_version,
		"commit_count": checkpoint_commit_count,
		"timer_monotonic": remaining_time <= timer_before + 0.001,
	}


func _capture_frontier() -> Dictionary:
	return {
		"capture_points": capture_points.duplicate(true),
		"committed_keys": committed_keys.duplicate(),
		"route_locks": route_locks.duplicate(true),
		"bomb_state": bomb_state,
		"checkpoint_version": checkpoint_version,
		"checkpoint_commit_count": checkpoint_commit_count,
		"checkpoint_snapshot": checkpoint_snapshot.duplicate(true),
		"active_capture": _active_capture,
		"event_sequence": event_sequence,
		"event_history": event_history.duplicate(true),
		"last_event": last_event.duplicate(true),
	}


func _fixture_progression_frontier() -> Dictionary:
	## Tester preparation may legitimately publish bounded roster/animation events.
	## Isolation concerns authoritative mission progression, not telemetry serials.
	return {
		"capture_points": capture_points.duplicate(true),
		"committed_keys": committed_keys.duplicate(),
		"route_locks": route_locks.duplicate(true),
		"bomb_state": bomb_state,
		"bomb_stage_index": bomb_stage_index,
		"bomb_stage_progress": bomb_stage_progress,
		"bomb_completed": bomb_completed.duplicate(),
		"active_bomb_stage": _active_bomb_stage,
		"remaining_time": remaining_time,
		"checkpoint_version": checkpoint_version,
		"checkpoint_commit_count": checkpoint_commit_count,
		"checkpoint_snapshot": checkpoint_snapshot.duplicate(true),
		"active_capture": _active_capture,
	}


func _restore_frontier(frontier: Dictionary) -> void:
	capture_points = (frontier.get("capture_points", {}) as Dictionary).duplicate(true)
	committed_keys.assign(frontier.get("committed_keys", []))
	route_locks = (frontier.get("route_locks", {}) as Dictionary).duplicate(true)
	bomb_state = StringName(frontier.get("bomb_state", &"armed"))
	bomb_stage_index = int(frontier.get("bomb_stage_index", bomb_stage_index))
	bomb_stage_progress = float(frontier.get("bomb_stage_progress", bomb_stage_progress))
	bomb_completed.assign(frontier.get("bomb_completed", bomb_completed))
	_active_bomb_stage = frontier.get("active_bomb_stage", _active_bomb_stage) == true
	remaining_time = float(frontier.get("remaining_time", remaining_time))
	checkpoint_version = int(frontier.get("checkpoint_version", 0))
	checkpoint_commit_count = int(frontier.get("checkpoint_commit_count", 0))
	checkpoint_snapshot = (frontier.get("checkpoint_snapshot", {}) as Dictionary).duplicate(true)
	_active_capture = StringName(frontier.get("active_capture", &""))
	event_sequence = int(frontier.get("event_sequence", event_sequence))
	event_history.assign(frontier.get("event_history", []))
	last_event = (frontier.get("last_event", {}) as Dictionary).duplicate(true)


func _sync_roster_after_frontier_restore() -> Dictionary:
	if enemy_roster == null or not enemy_roster.has_method(&"sync_progression_for_checkpoint"):
		return {"accepted": false, "failure_reason": &"enemy_progression_unavailable"}
	return enemy_roster.call(&"sync_progression_for_checkpoint")


func request_recovery() -> bool:
	if recovery_input_locked or checkpoint_restore_in_progress or mission_state in [&"recovery_restore", &"recovery_failed"]:
		_record_recovery_rejection(&"checkpoint" if checkpoint_version > 0 else &"deployment", &"recovery_already_active", false)
		return false
	_recovery_command_serial += 1
	var recovery_command_id := "mission-recovery-%06d" % _recovery_command_serial
	var recovery_source := &"checkpoint" if checkpoint_version > 0 else &"deployment"
	var source_snapshot := checkpoint_snapshot if recovery_source == &"checkpoint" else deployment_snapshot
	if mission_state != &"active_gameplay" or source_snapshot.is_empty():
		_record_recovery_rejection(recovery_source, &"snapshot_unavailable_or_illegal")
		return false
	var time_before := remaining_time
	var snapshot := source_snapshot.duplicate(true)
	if not _valid_checkpoint_snapshot(snapshot):
		_record_recovery_rejection(recovery_source, &"snapshot_schema_invalid")
		return false
	if enemy_roster == null or not enemy_roster.has_method(&"begin_restore_epoch"):
		_record_recovery_rejection(recovery_source, &"enemy_restore_unavailable")
		return false
	var hostile_positions := _enemy_positions_from_snapshot(snapshot.get("enemy_roster", {}))
	var player_preflight: Dictionary = player.call(&"validate_recovery_destination", snapshot["player_transform"], hostile_positions)
	if player_preflight.get("accepted", false) != true:
		_record_recovery_rejection(recovery_source, StringName(player_preflight.get("failure_reason", &"player_destination_rejected")))
		return false
	var rollback_snapshot := _build_snapshot()
	mission_state = &"recovery_restore"
	player.call(&"set_gameplay_input_enabled", false)
	weapon_controller.call(&"set_gameplay_input_enabled", false)
	recovery_input_locked = true
	enemy_restore_epoch = int(enemy_roster.call(&"begin_restore_epoch"))
	if enemy_restore_epoch < 0:
		_record_recovery_rejection(recovery_source, &"enemy_restore_epoch_rejected")
		return false
	checkpoint_restore_in_progress = true
	last_checkpoint_restore_receipt = {
		"command_id": recovery_command_id,
		"recovery_source": recovery_source,
		"snapshot_version": int(snapshot.get("version", checkpoint_version)),
		"checkpoint_version": checkpoint_version,
		"restore_epoch": enemy_restore_epoch,
		"restored_actor_count": 0,
		"committed": false,
		"rolled_back": false,
		"transient_reset_complete": false,
		"quiescent": true,
		"input_locked": true,
	}
	_apply_checkpoint_snapshot(snapshot, minf(time_before, float(snapshot["remaining_time"])))
	last_player_restore_receipt = player.call(&"restore_checkpoint_state", snapshot["player_transform"], float(snapshot["player_health"]), enemy_restore_epoch)
	if last_player_restore_receipt.get("accepted", false) != true:
		return _fail_checkpoint_restore(&"player_restore_failed", rollback_snapshot, enemy_restore_epoch, recovery_source)
	last_weapon_restore_receipt = weapon_controller.call(&"restore_weapon_state", snapshot["weapon_state"], enemy_restore_epoch)
	if last_weapon_restore_receipt.get("accepted", false) != true:
		return _fail_checkpoint_restore(&"weapon_restore_failed", rollback_snapshot, enemy_restore_epoch, recovery_source)
	if enemy_roster.call(&"apply_restore_snapshot", snapshot.get("enemy_roster", {}), enemy_restore_epoch) != true:
		push_error("Enemy checkpoint restore epoch %d could not apply every actor snapshot" % enemy_restore_epoch)
		return _fail_checkpoint_restore(&"enemy_snapshot_apply_failed", rollback_snapshot, enemy_restore_epoch, recovery_source)
	last_enemy_restore_receipt = enemy_roster.call(&"commit_restore_epoch", enemy_restore_epoch)
	if last_enemy_restore_receipt.is_empty() or int(last_enemy_restore_receipt.get("actor_count", 0)) != 18 or (last_enemy_restore_receipt.get("occupancy", {}) as Dictionary).get("accepted", false) != true:
		push_error("Enemy checkpoint restore epoch %d could not commit atomically" % enemy_restore_epoch)
		return _fail_checkpoint_restore(&"enemy_commit_incomplete", rollback_snapshot, enemy_restore_epoch, recovery_source)
	var restored_positions := _enemy_positions_from_snapshot(enemy_roster.call(&"snapshot_all"))
	var player_postflight: Dictionary = player.call(&"validate_recovery_destination", player.global_transform, restored_positions)
	if player_postflight.get("accepted", false) != true:
		return _fail_checkpoint_restore(&"player_postflight_occupancy_failed", rollback_snapshot, enemy_restore_epoch, recovery_source)
	_reset_transient_presentation(enemy_restore_epoch)
	checkpoint_restore_in_progress = false
	checkpoint_restore_count += 1
	last_checkpoint_restore_receipt = {
		"command_id": recovery_command_id,
		"recovery_source": recovery_source,
		"snapshot_version": int(snapshot.get("version", checkpoint_version)),
		"checkpoint_version": int(snapshot.get("version", checkpoint_version)),
		"restore_epoch": enemy_restore_epoch,
		"restore_count": checkpoint_restore_count,
		"restored_actor_count": int(last_enemy_restore_receipt.get("actor_count", 0)),
		"transient_reset_complete": true,
		"player_receipt": last_player_restore_receipt.duplicate(true),
		"weapon_receipt": last_weapon_restore_receipt.duplicate(true),
		"player_preflight": player_preflight,
		"player_postflight": player_postflight,
		"enemy_occupancy": (last_enemy_restore_receipt.get("occupancy", {}) as Dictionary).duplicate(true),
		"timer_before": time_before,
		"timer_after": remaining_time,
		"timer_monotonic": remaining_time <= time_before + 0.001,
		"committed": true,
		"rolled_back": false,
		"quiescent": false,
		"input_locked": true,
	}
	_record_event(&"checkpoint_restored", last_checkpoint_restore_receipt.duplicate(true))
	return true


func request_checkpoint_restore() -> bool:
	return request_recovery()


func complete_recovery_handoff(epoch: int) -> bool:
	if not recovery_input_locked or checkpoint_restore_in_progress:
		return false
	if not bool(last_checkpoint_restore_receipt.get("committed", false)) or int(last_checkpoint_restore_receipt.get("restore_epoch", -1)) != epoch:
		return false
	if last_player_restore_receipt.get("accepted", false) != true or last_weapon_restore_receipt.get("accepted", false) != true:
		return false
	if ((last_enemy_restore_receipt.get("occupancy", {}) as Dictionary).get("accepted", false) != true):
		return false
	recovery_input_locked = false
	mission_state = &"active_gameplay"
	last_checkpoint_restore_receipt["input_locked"] = false
	last_checkpoint_restore_receipt["handoff_committed"] = true
	player.call(&"set_gameplay_input_enabled", true)
	weapon_controller.call(&"set_gameplay_input_enabled", true)
	_record_event(&"recovery_handoff_completed", {
		"restore_epoch": epoch,
		"recovery_source": last_checkpoint_restore_receipt.get("recovery_source", &"unknown"),
		"input_locked": false,
	})
	return true


func _record_recovery_rejection(source: StringName, reason: StringName, lock_gameplay := true) -> void:
	if lock_gameplay:
		recovery_input_locked = true
		player.call(&"set_gameplay_input_enabled", false)
		weapon_controller.call(&"set_gameplay_input_enabled", false)
	last_recovery_rejection = {
		"recovery_source": source,
		"command_id": "mission-recovery-%06d" % _recovery_command_serial,
		"snapshot_version": checkpoint_version,
		"restore_epoch": enemy_restore_epoch,
		"restored_actor_count": 0,
		"committed": false,
		"rolled_back": false,
		"quiescent": true,
		"input_locked": recovery_input_locked,
		"failure_reason": reason,
	}
	if lock_gameplay:
		last_checkpoint_restore_receipt = last_recovery_rejection.duplicate(true)
	_record_event(&"recovery_rejected", last_recovery_rejection.duplicate(true))


func _valid_checkpoint_snapshot(snapshot: Dictionary) -> bool:
	var required := ["schema_version", "version", "mission_state", "capture_points", "committed_keys", "route_locks", "bomb_state", "bomb_stage_index", "bomb_completed", "remaining_time", "player_transform", "player_health", "weapon_state", "enemy_roster"]
	for key: String in required:
		if not snapshot.has(key):
			return false
	if int(snapshot["schema_version"]) != 2 or int(snapshot["version"]) < 0 or not snapshot["player_transform"] is Transform3D:
		return false
	var roster_snapshot := snapshot["enemy_roster"] as Dictionary
	if roster_snapshot.size() != 18:
		return false
	var unique_ids := {}
	for actor: Variant in roster_snapshot.values():
		if not actor is Dictionary:
			return false
		var actor_id := StringName((actor as Dictionary).get("id", &""))
		if actor_id == &"" or unique_ids.has(actor_id):
			return false
		unique_ids[actor_id] = true
	return unique_ids.size() == 18


func _enemy_positions_from_snapshot(roster_snapshot: Dictionary) -> Array:
	var positions: Array = []
	for actor: Variant in roster_snapshot.values():
		if actor is Dictionary:
			var transform: Variant = (actor as Dictionary).get("transform", Transform3D.IDENTITY)
			if transform is Transform3D:
				positions.append((transform as Transform3D).origin)
	return positions


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
	tester_prepared_region = &""
	tester_prepared_region_generation = 0
	tester_prepared_terminal_branch = &""
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
	if weapon_controller != null and weapon_controller.has_method(&"reset_shot_presentation"):
		weapon_controller.call(&"reset_shot_presentation", run_epoch)
	if enemy_roster != null and enemy_roster.has_method(&"reset_transient_feedback"):
		enemy_roster.call(&"reset_transient_feedback")


func _fail_checkpoint_restore(reason: StringName, rollback_snapshot: Dictionary, epoch: int, recovery_source := &"checkpoint") -> bool:
	if enemy_roster != null and enemy_roster.has_method(&"abort_restore_epoch"):
		last_enemy_restore_receipt = enemy_roster.call(&"abort_restore_epoch", epoch, rollback_snapshot.get("enemy_roster", {}), reason)
	_apply_checkpoint_snapshot(rollback_snapshot, float(rollback_snapshot.get("remaining_time", remaining_time)))
	player.call(&"restore_checkpoint_state", rollback_snapshot["player_transform"], float(rollback_snapshot["player_health"]), epoch, true)
	weapon_controller.call(&"restore_weapon_state", rollback_snapshot["weapon_state"], epoch, true)
	_reset_transient_presentation(epoch)
	checkpoint_restore_in_progress = false
	recovery_input_locked = true
	mission_state = &"recovery_failed"
	last_checkpoint_restore_receipt = {
		"recovery_source": recovery_source,
		"snapshot_version": int(rollback_snapshot.get("version", checkpoint_version)),
		"checkpoint_version": checkpoint_version,
		"restore_epoch": epoch,
		"restored_actor_count": int(last_enemy_restore_receipt.get("rollback_actor_count", 0)),
		"transient_reset_complete": true,
		"committed": false,
		"rolled_back": true,
		"quiescent": true,
		"input_locked": true,
		"failure_reason": reason,
	}
	return false


func _build_snapshot() -> Dictionary:
	return {
		"schema_version": 2,
		"run_epoch": run_epoch,
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
		"stage_index": bomb_stage_index,
		"stage_count": BOMB_STAGE_IDS.size(),
		"completed": bomb_completed.duplicate(),
		"active": _active_bomb_stage,
		"eta_seconds": maxf(_bomb_stage_duration(bomb_stage_index) * (1.0 - bomb_stage_progress), 0.0) if bomb_stage_index < BOMB_STAGE_IDS.size() else 0.0,
		"progress": bomb_stage_progress,
		"legal": route_locks[&"b_to_c"] != true,
		"overlap": overlaps[&"charlie"],
	}


func _record_event(kind: StringName, payload: Dictionary, announce := true) -> void:
	event_sequence += 1
	last_event = {
		"event_id": "run-%06d:mission-%06d" % [run_epoch, event_sequence],
		"run_epoch": run_epoch,
		"sequence": event_sequence,
		"kind": kind,
		"committed_at_usec": Time.get_ticks_usec(),
		"committed_frame": Engine.get_process_frames(),
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
		return "MISSION COMPLETE — BOMB DEFUSED"
	if mission_state == &"bomb_detonated":
		return "MISSION FAILED — DETONATION"
	if StringName(capture_points[&"alpha"]["state"]) != &"secured_aegis":
		return "A  ·  RETAKE FOUNDRY GATE"
	if StringName(capture_points[&"bravo"]["state"]) != &"secured_aegis":
		return "B  ·  SECURE CRANE YARD"
	return "C  ·  DEFUSE ROCKET BAY"


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
		return "BRAVO LOCKED — SECURE ALPHA FIRST"
	if overlaps[&"charlie"] == true:
		if route_locks[&"b_to_c"] == true:
			return "CHARLIE LOCKED — TWO KEYS REQUIRED"
		if _active_bomb_stage:
			return "HOLD [E] — RELEASE OR DAMAGE INTERRUPTS"
		if bomb_stage_index < BOMB_STAGE_IDS.size():
			return "HOLD [E] — %s" % String(BOMB_STAGE_IDS[bomb_stage_index]).replace("_", " ").to_upper()
	return ""


func _state_chip(state: StringName) -> String:
	return "SECURED" if state == &"secured_aegis" else "ACTIVE" if state == &"capturing_aegis" else "HOSTILE"


func _event_text(event: Dictionary) -> String:
	if event.is_empty():
		return ""
	var kind := String(event.get("kind", "")).replace("_", " ").to_upper()
	return "AEGIS  ·  %s" % kind


func _mcp_state() -> Dictionary:
	return {
		"run_epoch": run_epoch,
		"last_run_epoch_receipt": last_run_epoch_receipt,
		"tester_fixture_summary": {
			"encounter_branch_id": last_tester_encounter_receipt.get("branch_id", &""),
			"encounter_generation": tester_prepared_region_generation,
			"encounter_prepared_region": tester_prepared_region,
			"encounter_accepted": last_tester_encounter_receipt.get("accepted", false),
			"encounter_failure_reason": last_tester_encounter_receipt.get("failure_reason", &""),
			"terminal_branch_id": last_tester_terminal_receipt.get("branch_id", &""),
			"terminal_generation": tester_terminal_setup_generation,
			"terminal_prepared_branch": tester_prepared_terminal_branch,
			"terminal_accepted": last_tester_terminal_receipt.get("accepted", false),
			"release_guard": &"OS.is_debug_build",
		},
		"mission_progress_summary": {
			"mission_state": mission_state,
			"alpha_state": (capture_points.get(&"alpha", {}) as Dictionary).get("state", &"unknown"),
			"bravo_state": (capture_points.get(&"bravo", {}) as Dictionary).get("state", &"unknown"),
			"bomb_state": bomb_state,
			"bomb_stage_index": bomb_stage_index,
			"terminal_commit_count": terminal_commit_count,
		},
		# Keep the fixture control plane ahead of the large mission/event payload so
		# bounded MCP digests always expose the current generation and disposition.
		"tester_fixture_state": {
			"encounter_branch_id": last_tester_encounter_receipt.get("branch_id", &""),
			"encounter_setup_generation": tester_prepared_region_generation,
			"encounter_prepared_region": tester_prepared_region,
			"encounter_requested": last_tester_encounter_receipt.get("requested", false),
			"encounter_resolved": last_tester_encounter_receipt.get("resolved", false),
			"encounter_accepted": last_tester_encounter_receipt.get("accepted", false),
			"encounter_release_guard": last_tester_encounter_receipt.get("release_guard", &""),
			"encounter_failure_reason": last_tester_encounter_receipt.get("failure_reason", &""),
			"encounter_validation": last_tester_encounter_receipt.get("validation", {}),
			"encounter_reset_isolation": last_tester_encounter_receipt.get("reset_isolation", {}),
			"encounter_stable_actor_ids": last_tester_encounter_receipt.get("stable_actor_ids", []),
			"terminal_branch_id": last_tester_terminal_receipt.get("branch_id", &""),
			"terminal_setup_generation": tester_terminal_setup_generation,
			"terminal_prepared_branch": tester_prepared_terminal_branch,
			"terminal_requested": last_tester_terminal_receipt.get("requested", false),
			"terminal_resolved": last_tester_terminal_receipt.get("resolved", false),
			"terminal_accepted": last_tester_terminal_receipt.get("accepted", false),
			"terminal_release_guard": last_tester_terminal_receipt.get("release_guard", &""),
			"terminal_reset_isolation": last_tester_terminal_receipt.get("reset_isolation", {}),
		},
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
		"recovery_input_locked": recovery_input_locked,
		"last_enemy_restore_receipt": last_enemy_restore_receipt,
		"last_checkpoint_restore_receipt": last_checkpoint_restore_receipt,
		"last_player_restore_receipt": last_player_restore_receipt,
		"last_weapon_restore_receipt": last_weapon_restore_receipt,
		"last_recovery_rejection": last_recovery_rejection,
		"last_replay_reset_receipt": last_replay_reset_receipt,
		"terminal_commit_count": terminal_commit_count,
		"terminal_duplicate_submit_count": terminal_duplicate_submit_count,
		"terminal_event_id": terminal_event_id,
		"tester_countdown_zero_request_count": tester_countdown_zero_request_count,
		"tester_alpha_checkpoint_request_count": tester_alpha_checkpoint_request_count,
		"last_tester_alpha_checkpoint_receipt": last_tester_alpha_checkpoint_receipt,
		"tester_encounter_request_count": tester_encounter_request_count,
		"tester_prepared_region": tester_prepared_region,
		"tester_prepared_region_generation": tester_prepared_region_generation,
		"last_tester_encounter_receipt": last_tester_encounter_receipt,
		"tester_terminal_setup_generation": tester_terminal_setup_generation,
		"tester_prepared_terminal_branch": tester_prepared_terminal_branch,
		"last_tester_terminal_receipt": last_tester_terminal_receipt,
		"tester_terminal_history": tester_terminal_history,
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
