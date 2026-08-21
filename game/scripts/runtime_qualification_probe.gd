class_name FusepointRuntimeQualificationProbe
extends Node

## Presentation-neutral, bounded observer for complete-mission qualification.
## This node never mutates gameplay state and owns no mission truth.

const RAW_SAMPLE_CAPACITY := 18000
const RAW_TAIL_SIZE := 240
const CYCLE_HISTORY_LIMIT := 3
const LOW_FPS_FRAME_MS := 1000.0 / 45.0

@export var mission_path: NodePath
@export var roster_path: NodePath
@export var weapon_path: NodePath
@export var shell_path: NodePath
@export var terminal_path: NodePath
@export var mission_feedback_path: NodePath
@export var feedback_matrix_path: NodePath

@onready var mission: Node = get_node(mission_path)
@onready var roster: Node = get_node(roster_path)
@onready var weapon: Node = get_node(weapon_path)
@onready var shell: Node = get_node(shell_path)
@onready var terminal: Node = get_node(terminal_path)
@onready var mission_feedback: Node = get_node(mission_feedback_path)
@onready var feedback_matrix: Node = get_node(feedback_matrix_path)

var _raw_frame_times_ms: Array[float] = []
var _sample_count := 0
var _sample_sum_ms := 0.0
var _sample_max_ms := 0.0
var _sample_min_ms := INF
var _explosion_sample_count := 0
var _explosion_low_streak := 0
var _explosion_max_low_streak := 0
var _explosion_breach_visible := false
var _run_epoch := 0
var _cycle_serial := 0
var _cycle_marker := ""
var _cycle_history: Array[Dictionary] = []
var _phase_samples: Dictionary = {}
var _counter_refresh_remaining := 0.0
var _cleanup_counters: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"mcp_watch")
	add_to_group(&"runtime_qualification")
	# Sibling presenters and the shell finish their own @onready bindings later
	# in the scene-ready traversal. The first process tick observes them only
	# after that traversal is complete.
	_counter_refresh_remaining = 0.0


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	var mission_state: Dictionary = mission.call(&"_mcp_state")
	var observed_epoch := int(mission_state.get("run_epoch", 0))
	var restore_count := int(mission_state.get("checkpoint_restore_count", 0))
	var marker := "%06d:%06d" % [observed_epoch, restore_count]
	if observed_epoch != _run_epoch or marker != _cycle_marker:
		_begin_cycle(observed_epoch, marker)
	var frame_ms := delta * 1000.0
	_record_sample(frame_ms, _phase_id(mission_state), _is_explosion_window(mission_state))
	_counter_refresh_remaining -= delta
	if _counter_refresh_remaining <= 0.0:
		_counter_refresh_remaining = 0.5
		_refresh_cleanup_counters()


func _begin_cycle(epoch: int, marker: String) -> void:
	if _sample_count > 0:
		_cycle_history.append(_cycle_summary())
		while _cycle_history.size() > CYCLE_HISTORY_LIMIT:
			_cycle_history.pop_front()
	_cycle_serial += 1
	_run_epoch = epoch
	_cycle_marker = marker
	_raw_frame_times_ms.clear()
	_sample_count = 0
	_sample_sum_ms = 0.0
	_sample_max_ms = 0.0
	_sample_min_ms = INF
	_explosion_sample_count = 0
	_explosion_low_streak = 0
	_explosion_max_low_streak = 0
	_explosion_breach_visible = false
	_phase_samples.clear()


func _record_sample(frame_ms: float, phase: StringName, explosion_window: bool) -> void:
	_sample_count += 1
	_sample_sum_ms += frame_ms
	_sample_max_ms = maxf(_sample_max_ms, frame_ms)
	_sample_min_ms = minf(_sample_min_ms, frame_ms)
	_raw_frame_times_ms.append(frame_ms)
	if _raw_frame_times_ms.size() > RAW_SAMPLE_CAPACITY:
		_raw_frame_times_ms.pop_front()
	var phase_entry: Dictionary = _phase_samples.get(phase, {
		"sample_count": 0,
		"sum_ms": 0.0,
		"max_ms": 0.0,
	})
	phase_entry["sample_count"] = int(phase_entry["sample_count"]) + 1
	phase_entry["sum_ms"] = float(phase_entry["sum_ms"]) + frame_ms
	phase_entry["max_ms"] = maxf(float(phase_entry["max_ms"]), frame_ms)
	_phase_samples[phase] = phase_entry
	if explosion_window:
		_explosion_sample_count += 1
		if frame_ms > LOW_FPS_FRAME_MS:
			_explosion_low_streak += 1
			_explosion_max_low_streak = maxi(_explosion_max_low_streak, _explosion_low_streak)
			_explosion_breach_visible = _explosion_max_low_streak >= 3
		else:
			_explosion_low_streak = 0
	else:
		_explosion_low_streak = 0


func _phase_id(state: Dictionary) -> StringName:
	var mission_state := StringName(state.get("mission_state", &"unknown"))
	var bomb_state := StringName(state.get("bomb_state", &"unknown"))
	if bomb_state in [&"diagnosing", &"isolating_power", &"removing_detonator", &"detonated", &"defused"]:
		return bomb_state
	return mission_state


func _is_explosion_window(state: Dictionary) -> bool:
	return StringName(state.get("bomb_state", &"")) == &"detonated" or StringName(state.get("mission_state", &"")) == &"bomb_detonated"


func _refresh_cleanup_counters() -> void:
	var mission_state: Dictionary = mission.call(&"_mcp_state")
	var roster_state: Dictionary = roster.call(&"_mcp_state")
	var weapon_state: Dictionary = weapon.call(&"_mcp_state")
	var shell_state: Dictionary = shell.call(&"_mcp_state")
	var terminal_state: Dictionary = terminal.call(&"_mcp_state")
	var mission_feedback_state: Dictionary = mission_feedback.call(&"_mcp_state")
	var feedback_matrix_state: Dictionary = feedback_matrix.call(&"_mcp_state")
	var actors: Array = roster_state.get("actors", [])
	var corpse_count := 0
	var active_effect_count := int(mission_feedback_state.get("active_cue_count", 0))
	var presented_event_count := 0
	var duplicate_event_count := 0
	for actor_value: Variant in actors:
		if not actor_value is Dictionary:
			continue
		var actor := actor_value as Dictionary
		if actor.get("alive", true) != true:
			corpse_count += 1
		var feedback_state: Dictionary = actor.get("shot_feedback", {})
		active_effect_count += int(feedback_state.get("active_effect_count", 0))
		presented_event_count += int(feedback_state.get("presented_event_count", 0))
		duplicate_event_count += int(feedback_state.get("duplicate_event_count", 0))
	var player_feedback: Dictionary = weapon_state.get("shot_feedback", {})
	active_effect_count += int(player_feedback.get("active_effect_count", 0))
	presented_event_count += int(player_feedback.get("presented_event_count", 0))
	duplicate_event_count += int(player_feedback.get("duplicate_event_count", 0))
	_cleanup_counters = {
		"stable_actor_count": int(roster_state.get("stable_identity_count", 0)),
		"alive_actor_count": int(roster_state.get("alive_count", 0)),
		"corpse_count": corpse_count,
		"active_effect_count": active_effect_count,
		"presented_event_count": presented_event_count,
		"duplicate_event_count": duplicate_event_count,
		"mission_event_count": int(mission_state.get("event_sequence", 0)),
		"terminal_result_count": int(mission_state.get("terminal_commit_count", 0)),
		"terminal_effect_layer_count": int(terminal_state.get("effect_layer_count", 0)),
		"playing_audio_role_count": _playing_audio_role_count(),
		"signal_connection_count": _signal_connection_count(),
		"shell_transition_count": int(shell_state.get("transition_serial", 0)),
		"shot_commit_count": int(weapon_state.get("unique_commit_count", 0)),
		"joined_receipt_count": int(feedback_matrix_state.get("cached_event_count", 0)),
		"retained_previous_receipt_count": int(feedback_matrix_state.get("previous_receipt_count", 0)),
		"terminal_branch_receipt_count": int(terminal_state.get("retained_branch_receipt_count", 0)),
		"terminal_duplicate_submit_count": int(mission_state.get("terminal_duplicate_submit_count", 0)),
	}


func _playing_audio_role_count() -> int:
	var count := 0
	var scene := get_tree().current_scene
	if scene == null:
		return 0
	for node: Node in scene.find_children("*", "AudioStreamPlayer", true, false):
		if (node as AudioStreamPlayer).playing:
			count += 1
	for node: Node in scene.find_children("*", "AudioStreamPlayer3D", true, false):
		if (node as AudioStreamPlayer3D).playing:
			count += 1
	return count


func _signal_connection_count() -> int:
	var count := 0
	for observed: Node in [mission, roster, weapon, shell, terminal, mission_feedback]:
		count += observed.get_incoming_connections().size()
	return count


func _phase_aggregates() -> Dictionary:
	var result := {}
	for phase: Variant in _phase_samples:
		var entry: Dictionary = _phase_samples[phase]
		var count := int(entry.get("sample_count", 0))
		result[phase] = {
			"sample_count": count,
			"average_ms": float(entry.get("sum_ms", 0.0)) / float(count) if count > 0 else 0.0,
			"max_ms": float(entry.get("max_ms", 0.0)),
		}
	return result


func _raw_tail() -> Array[float]:
	var tail: Array[float] = []
	var start := maxi(0, _raw_frame_times_ms.size() - RAW_TAIL_SIZE)
	for index in range(start, _raw_frame_times_ms.size()):
		tail.append(_raw_frame_times_ms[index])
	return tail


func _cycle_summary() -> Dictionary:
	return {
		"cycle_serial": _cycle_serial,
		"cycle_marker": _cycle_marker,
		"run_epoch": _run_epoch,
		"sample_count": _sample_count,
		"average_frame_ms": _sample_sum_ms / float(_sample_count) if _sample_count > 0 else 0.0,
		"max_frame_ms": _sample_max_ms,
		"explosion_max_low_fps_streak": _explosion_max_low_streak,
		"cleanup": _cleanup_counters.duplicate(true),
	}


func qualification_snapshot() -> Dictionary:
	return {
		"schema_version": 1,
		"presentation_neutral": true,
		"target_resolution": Vector2i(1920, 1080),
		"target_fps": 60,
		"explosion_min_fps": 45,
		"run_epoch": _run_epoch,
		"cycle_serial": _cycle_serial,
		"cycle_marker": _cycle_marker,
		"mission_phase": _phase_id(mission.call(&"_mcp_state")),
		"sample_window_capacity": RAW_SAMPLE_CAPACITY,
		"retained_sample_count": _raw_frame_times_ms.size(),
		"sample_count": _sample_count,
		"average_frame_ms": _sample_sum_ms / float(_sample_count) if _sample_count > 0 else 0.0,
		"minimum_frame_ms": 0.0 if is_inf(_sample_min_ms) else _sample_min_ms,
		"maximum_frame_ms": _sample_max_ms,
		"phase_aggregates": _phase_aggregates(),
		"explosion_sample_count": _explosion_sample_count,
		"explosion_current_low_fps_streak": _explosion_low_streak,
		"explosion_max_low_fps_streak": _explosion_max_low_streak,
		"explosion_threshold_breach_visible": _explosion_breach_visible,
		"cleanup": _cleanup_counters.duplicate(true),
		"cycle_history": _cycle_history.duplicate(true),
		"raw_frame_time_tail_ms": _raw_tail(),
	}


func _mcp_state() -> Dictionary:
	return qualification_snapshot()
