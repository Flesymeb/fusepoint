class_name FusepointRuntimeQualificationProbe
extends Node

## Presentation-neutral, bounded observer for complete-mission qualification.
## This node never mutates gameplay state and owns no mission truth.

const RAW_SAMPLE_CAPACITY := 18000
const RAW_TAIL_SIZE := 240
const RAW_PAGE_SIZE := 240
const CYCLE_HISTORY_LIMIT := 3
const LOW_FPS_FRAME_MS := 1000.0 / 45.0
const DEEP_OBSERVATION_INTERVAL := 2.0
const SAMPLE_CONTEXT_INTERVAL := 0.25
const COMBAT_SAMPLE_INTERVAL := 1.0
const COMBAT_HISTORY_LIMIT := 24
const TARGET_RESOLUTION := Vector2i(1920, 1080)
const CANDIDATE_HOTPATHS: Array[Dictionary] = [
	{"name": &"runtime_qualification_frame_accumulator", "ordinary_cadence": &"per_frame_scalar_only", "deep_only": false},
	{"name": &"runtime_qualification_sample_context", "ordinary_cadence": SAMPLE_CONTEXT_INTERVAL, "deep_only": false},
	{"name": &"cleanup_counter_scene_scan", "ordinary_cadence": DEEP_OBSERVATION_INTERVAL, "deep_only": true},
	{"name": &"combat_presentation_snapshot", "ordinary_cadence": COMBAT_SAMPLE_INTERVAL, "deep_only": true},
]

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
var _raw_phase_ids: Array[StringName] = []
var _raw_explosion_flags: Array[bool] = []
var _raw_active_enemy_counts: Array[int] = []
var _sample_count := 0
var _sample_sum_ms := 0.0
var _sample_max_ms := 0.0
var _sample_min_ms := INF
var _hitch_count := 0
var _explosion_sample_count := 0
var _explosion_low_streak := 0
var _explosion_max_low_streak := 0
var _explosion_breach_visible := false
var _run_epoch := 0
var _cycle_serial := 0
var _cycle_marker := ""
var _cycle_history: Array[Dictionary] = []
var _cycle_boundaries: Array[Dictionary] = []
var _cycle_cleanup_start: Dictionary = {}
var _cycle_cleanup_settled := false
var _cycle_viewport_start := Vector2i.ZERO
var _observed_viewport := Vector2i.ZERO
var _last_checkpoint_restore_count := 0
var _terminal_boundary_latched := false
var _phase_samples: Dictionary = {}
var _counter_refresh_remaining := 0.0
var _cleanup_counters: Dictionary = {}
var _combat_sample_remaining := 0.0
var _combat_sample_serial := 0
var _combat_animation_history: Array[Dictionary] = []
var _last_mission_state := &"unknown"
var _last_mission_event_sequence := -1
var _deep_observation_count := 0
var _qualification_enabled := false
var _observation_mode := &"ordinary_bounded"
var _observation_epoch := 0
var _last_observation_receipt: Dictionary = {}
var _sample_context_remaining := 0.0
var _cached_phase := &"unknown"
var _cached_explosion_window := false
var _cached_active_enemy_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"mcp_watch")
	add_to_group(&"runtime_qualification")
	# Sibling presenters and the shell finish their own @onready bindings later
	# in the scene-ready traversal. The first process tick observes them only
	# after that traversal is complete.
	_counter_refresh_remaining = 0.0
	set_process(true)
	set_process_input(true)


func _input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if event.is_action_pressed(&"tester_qualification_start"):
		set_qualification_enabled(true, &"tester_input")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"tester_qualification_stop"):
		set_qualification_enabled(false, &"tester_input")
		get_viewport().set_input_as_handled()


func set_qualification_enabled(enabled: bool, source: StringName = &"tester_control") -> Dictionary:
	_observation_epoch += 1
	var debug_allowed := OS.is_debug_build()
	var resolved_enabled := enabled and debug_allowed
	_qualification_enabled = resolved_enabled
	_observation_mode = &"deep_qualification" if resolved_enabled else &"ordinary_bounded"
	if enabled:
		_counter_refresh_remaining = 0.0
		_combat_sample_remaining = 0.0
		_sample_context_remaining = 0.0
		_refresh_sample_context()
	set_process(true)
	_last_observation_receipt = {
		"event_id": "qualification-observation-%06d" % _observation_epoch,
		"requested": true,
		"resolved": true,
		"accepted": debug_allowed,
		"enabled": resolved_enabled,
		"mode": _observation_mode,
		"source": source,
		"release_guard": &"OS.is_debug_build",
		"process_frame": Engine.get_process_frames(),
		"physics_frame": Engine.get_physics_frames(),
		"failure_reason": &"" if debug_allowed else &"release_build_forbidden",
		"reset_isolation": {
			"mutates_gameplay_authority": false,
			"ordinary_process_enabled": true,
			"ordinary_process_limited_to_frame_accumulator": not resolved_enabled,
			"deep_counter_unchanged_when_disabled": true,
			"run_epoch": int(mission.get("run_epoch")),
		},
	}
	return _last_observation_receipt.duplicate(true)


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	_sample_context_remaining -= delta
	if _sample_context_remaining <= 0.0:
		_sample_context_remaining = SAMPLE_CONTEXT_INTERVAL
		_refresh_sample_context()
	var observed_epoch := int(mission.get("run_epoch"))
	var marker := "run-%06d" % observed_epoch
	if observed_epoch != _run_epoch or marker != _cycle_marker:
		_begin_cycle(
			observed_epoch,
			marker,
			int(mission.get("checkpoint_restore_count")),
			{
				"mission_state": mission.get("mission_state"),
				"bomb_state": mission.get("bomb_state"),
				"run_epoch": observed_epoch,
				"event_sequence": int(mission.get("event_sequence")),
			},
			false
		)
	var frame_ms := delta * 1000.0
	_record_sample(frame_ms, _cached_phase, _cached_explosion_window, _cached_active_enemy_count)
	if not _qualification_enabled:
		return
	var mission_state: Dictionary = mission.call(&"_mcp_state") if _counter_refresh_remaining <= 0.0 else {}
	observed_epoch = int(mission_state.get("run_epoch", 0))
	if mission_state.is_empty():
		observed_epoch = int(mission.get("run_epoch"))
	var restore_count := int(mission_state.get("checkpoint_restore_count", 0))
	if mission_state.is_empty():
		restore_count = _last_checkpoint_restore_count
	marker = "run-%06d" % observed_epoch
	if observed_epoch != _run_epoch or marker != _cycle_marker:
		var initial_state: Dictionary = mission.call(&"_mcp_state")
		_begin_cycle(observed_epoch, marker, restore_count, initial_state)
	if not mission_state.is_empty():
		_update_lifecycle_boundaries(mission_state, restore_count)
	_counter_refresh_remaining -= delta
	if _counter_refresh_remaining <= 0.0:
		_counter_refresh_remaining = DEEP_OBSERVATION_INTERVAL
		_refresh_cleanup_counters()
		_deep_observation_count += 1
		_settle_cycle_cleanup_start()
	_combat_sample_remaining -= delta
	if _combat_sample_remaining <= 0.0:
		_combat_sample_remaining = COMBAT_SAMPLE_INTERVAL
		_sample_combat_presentation()


func _refresh_sample_context() -> void:
	var mission_state_id := StringName(mission.get("mission_state"))
	var bomb_state_id := StringName(mission.get("bomb_state"))
	_cached_phase = bomb_state_id if bomb_state_id in [&"diagnosing", &"isolating_power", &"removing_detonator", &"detonated", &"defused"] else mission_state_id
	_cached_explosion_window = bomb_state_id == &"detonated" or mission_state_id == &"bomb_detonated"
	_cached_active_enemy_count = 0
	var roster_enemies: Dictionary = roster.get("enemies")
	for candidate: Variant in roster_enemies.values():
		if candidate != null and is_instance_valid(candidate) and candidate.get("mission_active") == true:
			_cached_active_enemy_count += 1


func _begin_cycle(epoch: int, marker: String, restore_count: int, mission_state: Dictionary, collect_deep_receipts := true) -> void:
	if _sample_count > 0:
		_cycle_history.append(_cycle_record(true))
		while _cycle_history.size() > CYCLE_HISTORY_LIMIT:
			_cycle_history.pop_front()
	_cycle_serial += 1
	_run_epoch = epoch
	_cycle_marker = marker
	_raw_frame_times_ms.clear()
	_raw_phase_ids.clear()
	_raw_explosion_flags.clear()
	_raw_active_enemy_counts.clear()
	_sample_count = 0
	_sample_sum_ms = 0.0
	_sample_max_ms = 0.0
	_sample_min_ms = INF
	_hitch_count = 0
	_explosion_sample_count = 0
	_explosion_low_streak = 0
	_explosion_max_low_streak = 0
	_explosion_breach_visible = false
	_phase_samples.clear()
	_combat_animation_history.clear()
	_combat_sample_remaining = 0.0
	_observed_viewport = Vector2i(get_viewport().get_visible_rect().size)
	_cycle_viewport_start = _observed_viewport
	_last_checkpoint_restore_count = restore_count
	_terminal_boundary_latched = false
	_last_mission_state = StringName(mission_state.get("mission_state", &"unknown"))
	_last_mission_event_sequence = int(mission_state.get("event_sequence", -1))
	_cycle_cleanup_settled = false
	var shell_state: Dictionary = shell.call(&"_mcp_state") if collect_deep_receipts else {}
	var lifecycle_action: Dictionary = shell_state.get("last_lifecycle_action_receipt", {})
	var run_epoch_receipt: Dictionary = mission_state.get("last_run_epoch_receipt", {})
	_cycle_boundaries = [{
		"kind": &"cycle_started",
		"cycle_serial": _cycle_serial,
		"run_epoch": _run_epoch,
		"checkpoint_restore_count": restore_count,
		"process_frame": Engine.get_process_frames(),
		"physics_frame": Engine.get_physics_frames(),
		"observed_viewport": _observed_viewport,
		"cycle_origin": run_epoch_receipt.get("reason", &"unknown"),
		"shell_lifecycle_action": lifecycle_action.get("action", &"none"),
		"shell_lifecycle_action_id": lifecycle_action.get("action_id", ""),
		"at_usec": Time.get_ticks_usec(),
	}]
	if collect_deep_receipts:
		_refresh_cleanup_counters()
		_cycle_cleanup_start = _cleanup_counters.duplicate(true)
		_settle_cycle_cleanup_start()
	else:
		_cleanup_counters = {"deferred_until_qualification": true}
		_cycle_cleanup_start = _cleanup_counters.duplicate(true)
		_append_cycle_boundary(&"ordinary_observer_started", {
			"deep_receipts_collected": false,
			"hotpath_scope": &"frame_time_accumulator_and_sampled_context",
		})


func _settle_cycle_cleanup_start() -> void:
	if _cycle_cleanup_settled or int(_cleanup_counters.get("stable_actor_count", 0)) <= 0:
		return
	_cycle_cleanup_start = _cleanup_counters.duplicate(true)
	_cycle_cleanup_settled = true
	_append_cycle_boundary(&"observer_settled", {
		"stable_actor_count": _cleanup_counters.get("stable_actor_count", 0),
		"signal_connection_count": _cleanup_counters.get("signal_connection_count", 0),
	})


func _update_lifecycle_boundaries(mission_state: Dictionary, restore_count: int) -> void:
	var viewport := Vector2i(get_viewport().get_visible_rect().size)
	if viewport != _observed_viewport:
		_observed_viewport = viewport
		_append_cycle_boundary(&"viewport_changed", {"observed_viewport": viewport})
	if restore_count != _last_checkpoint_restore_count:
		_append_cycle_boundary(&"checkpoint_restored", {
			"previous_restore_count": _last_checkpoint_restore_count,
			"checkpoint_restore_count": restore_count,
		})
		_last_checkpoint_restore_count = restore_count
	var mission_state_id := StringName(mission_state.get("mission_state", &"unknown"))
	if mission_state_id != _last_mission_state:
		_append_cycle_boundary(&"mission_phase_changed", {
			"previous_mission_state": _last_mission_state,
			"mission_state": mission_state_id,
		})
		if _last_mission_state == &"predeployment" and mission_state_id == &"active_gameplay":
			_append_cycle_boundary(&"deployment", {"mission_state": mission_state_id})
		_last_mission_state = mission_state_id
	var mission_event_sequence := int(mission_state.get("event_sequence", -1))
	if mission_event_sequence != _last_mission_event_sequence:
		var last_event: Dictionary = mission_state.get("last_event", {})
		var event_kind := StringName(last_event.get("kind", &"unknown"))
		if event_kind in [&"deployment_started", &"checkpoint_restored", &"recovery_handoff_completed", &"terminal_submitted"]:
			_append_cycle_boundary(event_kind, {
				"mission_event_id": last_event.get("event_id", ""),
				"mission_event_sequence": mission_event_sequence,
			})
		_last_mission_event_sequence = mission_event_sequence
	var bomb_state_id := StringName(mission_state.get("bomb_state", &"unknown"))
	var terminal := mission_state_id in [&"bomb_defused", &"bomb_detonated"] or bomb_state_id in [&"defused", &"detonated"]
	if terminal and not _terminal_boundary_latched:
		_terminal_boundary_latched = true
		_append_cycle_boundary(&"terminal_committed", {
			"mission_state": mission_state_id,
			"bomb_state": bomb_state_id,
		})


func _append_cycle_boundary(kind: StringName, payload: Dictionary = {}) -> void:
	var receipt := payload.duplicate(true)
	receipt["kind"] = kind
	receipt["cycle_serial"] = _cycle_serial
	receipt["run_epoch"] = _run_epoch
	receipt["sample_index"] = _sample_count
	receipt["process_frame"] = Engine.get_process_frames()
	receipt["physics_frame"] = Engine.get_physics_frames()
	receipt["at_usec"] = Time.get_ticks_usec()
	_cycle_boundaries.append(receipt)
	while _cycle_boundaries.size() > 24:
		_cycle_boundaries.pop_front()


func _record_sample(frame_ms: float, phase: StringName, explosion_window: bool, active_enemy_count: int) -> void:
	_sample_count += 1
	_sample_sum_ms += frame_ms
	_sample_max_ms = maxf(_sample_max_ms, frame_ms)
	_sample_min_ms = minf(_sample_min_ms, frame_ms)
	if frame_ms > LOW_FPS_FRAME_MS:
		_hitch_count += 1
	_raw_frame_times_ms.append(frame_ms)
	_raw_phase_ids.append(phase)
	_raw_explosion_flags.append(explosion_window)
	_raw_active_enemy_counts.append(active_enemy_count)
	if _raw_frame_times_ms.size() > RAW_SAMPLE_CAPACITY:
		_raw_frame_times_ms.pop_front()
		_raw_phase_ids.pop_front()
		_raw_explosion_flags.pop_front()
		_raw_active_enemy_counts.pop_front()
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


func _sample_combat_presentation() -> void:
	# Observe only production state already owned by WeaponController and the
	# authoritative roster. This deliberately has no selector or preview path.
	var weapon_state: Dictionary = weapon.call(&"_mcp_state")
	var roster_state: Dictionary = roster.call(&"_mcp_state")
	var actor_cells: Array[Dictionary] = []
	for actor_value: Variant in roster_state.get("actors", []):
		if actor_value is not Dictionary:
			continue
		var actor := actor_value as Dictionary
		if actor.get("active", false) != true:
			continue
		actor_cells.append({
			"actor_id": actor.get("id", &""),
			"region": actor.get("region", &""),
			"alive": actor.get("alive", false),
			"action": actor.get("action", &"idle"),
			"animation_semantic": actor.get("animation_semantic", &""),
			"animation_clip": actor.get("animation_name", ""),
			"animation_normalized_time": actor.get("animation_normalized_time", 0.0),
			"animation_playing": actor.get("animation_playing", false),
			"rifle_action_progress": actor.get("rifle_action_progress", 0.0),
			"velocity": actor.get("velocity", Vector3.ZERO),
			"grounded": actor.get("grounded_occupancy", false),
			"weapon_family": actor.get("weapon_family", &"unbound"),
			"weapon_family_compatible": actor.get("weapon_family_compatible", false),
			"weapon_socket_bound": actor.get("weapon_socket_bound", false),
			"weapon_attached": actor.get("weapon_attached", false),
			"root_pitch_degrees": actor.get("root_pitch_degrees", 0.0),
			"root_roll_degrees": actor.get("root_roll_degrees", 0.0),
			"root_upright": actor.get("root_upright", false),
			"aim_pitch_degrees": actor.get("aim_pitch_degrees", 0.0),
			"shot_event_id": actor.get("shot_event_id", ""),
			"ammo": actor.get("ammo", 0),
			"last_event": actor.get("last_event", {}),
		})
	_combat_sample_serial += 1
	_combat_animation_history.append({
		"sample_serial": _combat_sample_serial,
		"process_frame": Engine.get_process_frames(),
		"physics_frame": Engine.get_physics_frames(),
		"run_epoch": weapon_state.get("run_epoch", 0),
		"weapon": {
			"weapon_id": weapon_state.get("active_weapon_id", ""),
			"profile_id": weapon_state.get("active_profile_id", ""),
			"action": weapon_state.get("action_state", &"idle"),
			"reload_kind": weapon_state.get("reload_kind", &"none"),
			"clip": weapon_state.get("viewmodel_clip", &""),
			"ads": weapon_state.get("ads", false),
			"ads_settled": weapon_state.get("viewmodel_settled_aim", false),
			"trigger_held": weapon_state.get("trigger_held", false),
			"recoil_phase": weapon_state.get("recoil_phase", &"unavailable"),
			"recoil_position_offset": weapon_state.get("recoil_current_position_offset", Vector3.ZERO),
			"recoil_rotation_offset_degrees": weapon_state.get("recoil_current_rotation_offset_degrees", Vector3.ZERO),
			"recoil_recovery_complete": weapon_state.get("recoil_recovery_complete", false),
			"baseline_position_error": weapon_state.get("recoil_baseline_position_error", -1.0),
			"baseline_rotation_error_degrees": weapon_state.get("recoil_baseline_rotation_error_degrees", -1.0),
			"magazine": weapon_state.get("magazine", 0),
			"visible_rig": weapon_state.get("visible_rig", {}),
			"direct_camera_child": weapon_state.get("viewmodel_direct_camera_child", false),
		},
		"active_enemy_count": actor_cells.size(),
		"enemies": actor_cells,
	})
	while _combat_animation_history.size() > COMBAT_HISTORY_LIMIT:
		_combat_animation_history.pop_front()


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


func _one_percent_low_fps(frame_times: Array) -> float:
	if frame_times.is_empty():
		return 0.0
	var ordered: Array[float] = []
	for value: Variant in frame_times:
		ordered.append(float(value))
	ordered.sort()
	var worst_count := maxi(1, ceili(float(ordered.size()) * 0.01))
	var worst_sum := 0.0
	for index in range(ordered.size() - worst_count, ordered.size()):
		worst_sum += ordered[index]
	var worst_average_ms := worst_sum / float(worst_count)
	return 1000.0 / worst_average_ms if worst_average_ms > 0.0 else 0.0


func _workload_counts_seen(counts: Array) -> Array[int]:
	var seen: Array[int] = []
	for value: Variant in counts:
		var count := int(value)
		if count in [3, 5, 10, 18] and count not in seen:
			seen.append(count)
	seen.sort()
	return seen


func _cleanup_delta(start: Dictionary, finish: Dictionary) -> Dictionary:
	var delta := {}
	for key: Variant in finish:
		var start_value: Variant = start.get(key, 0)
		var end_value: Variant = finish[key]
		if (end_value is int or end_value is float) and (start_value is int or start_value is float):
			delta[key] = end_value - start_value
	return delta


func _renderer_context() -> Dictionary:
	return {
		"rendering_method": String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")),
		"mobile_rendering_method": String(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "unknown")),
		"adapter_driver_info": OS.get_video_adapter_driver_info(),
		"platform": OS.get_name(),
		"engine_version": Engine.get_version_info(),
		"hardware_verdict_asserted": false,
	}


func _cycle_incomplete_reasons(record: Dictionary) -> Array[StringName]:
	var reasons: Array[StringName] = []
	if record.get("complete", false) != true:
		reasons.append(&"terminal_boundary_missing")
	if record.get("target_resolution_match", false) != true:
		reasons.append(&"target_resolution_missing")
	if int(record.get("explosion_sample_count", 0)) < 3:
		reasons.append(&"insufficient_explosion_samples")
	var cleanup_end: Dictionary = record.get("cleanup_end", {})
	var cleanup_delta: Dictionary = record.get("cleanup_delta", {})
	if int(cleanup_end.get("stable_actor_count", 0)) != 18:
		reasons.append(&"stable_actor_cleanup_drift")
	if int(cleanup_delta.get("duplicate_event_count", 0)) > 0 or int(cleanup_end.get("terminal_duplicate_submit_count", 0)) > 0:
		reasons.append(&"duplicate_cleanup_drift")
	if int(cleanup_delta.get("signal_connection_count", 0)) != 0:
		reasons.append(&"signal_connection_cleanup_drift")
	return reasons


func _cycle_record(include_raw: bool) -> Dictionary:
	var record := {
		"cycle_serial": _cycle_serial,
		"cycle_marker": _cycle_marker,
		"run_epoch": _run_epoch,
		"complete": _terminal_boundary_latched,
		"observed_viewport_start": _cycle_viewport_start,
		"observed_viewport_end": _observed_viewport,
		"target_resolution_match": _observed_viewport == TARGET_RESOLUTION,
		"renderer_context": _renderer_context(),
		"sample_count": _sample_count,
		"retained_sample_count": _raw_frame_times_ms.size(),
		"average_frame_ms": _sample_sum_ms / float(_sample_count) if _sample_count > 0 else 0.0,
		"min_frame_ms": 0.0 if is_inf(_sample_min_ms) else _sample_min_ms,
		"max_frame_ms": _sample_max_ms,
		"one_percent_low_fps": _one_percent_low_fps(_raw_frame_times_ms),
		"hitch_count": _hitch_count,
		"hitch_threshold_ms": LOW_FPS_FRAME_MS,
		"workload_counts_seen": _workload_counts_seen(_raw_active_enemy_counts),
		"phase_aggregates": _phase_aggregates(),
		"explosion_sample_count": _explosion_sample_count,
		"explosion_max_low_fps_streak": _explosion_max_low_streak,
		"explosion_threshold_breach_visible": _explosion_breach_visible,
		"cleanup_start": _cycle_cleanup_start.duplicate(true),
		"cleanup_end": _cleanup_counters.duplicate(true),
		"cleanup_delta": _cleanup_delta(_cycle_cleanup_start, _cleanup_counters),
		"lifecycle_boundaries": _cycle_boundaries.duplicate(true),
		"raw_page_size": RAW_PAGE_SIZE,
		"raw_page_count": ceili(float(_raw_frame_times_ms.size()) / float(RAW_PAGE_SIZE)),
	}
	var incomplete_reasons := _cycle_incomplete_reasons(record)
	record["evidence_state"] = &"complete" if incomplete_reasons.is_empty() else &"incomplete"
	record["incomplete_reasons"] = incomplete_reasons
	record["hardware_verdict_asserted"] = false
	if include_raw:
		record["raw_frame_times_ms"] = _raw_frame_times_ms.duplicate()
		record["raw_phase_ids"] = _raw_phase_ids.duplicate()
		record["raw_explosion_flags"] = _raw_explosion_flags.duplicate()
		record["raw_active_enemy_counts"] = _raw_active_enemy_counts.duplicate()
	return record


func _public_cycle_summary(record: Dictionary) -> Dictionary:
	var result := record.duplicate(true)
	result.erase("raw_frame_times_ms")
	result.erase("raw_phase_ids")
	result.erase("raw_explosion_flags")
	result.erase("raw_active_enemy_counts")
	return result


func _retained_cycle_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for archived: Dictionary in _cycle_history:
		records.append(archived)
	records.append(_cycle_record(false))
	while records.size() > CYCLE_HISTORY_LIMIT:
		records.pop_front()
	return records


func _retained_cycle_index() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _retained_cycle_records():
		result.append(_public_cycle_summary(record))
	return result


func qualification_sample_page(cycle_serial: int, offset := 0, limit := RAW_PAGE_SIZE) -> Dictionary:
	var source: Dictionary = {}
	if cycle_serial == _cycle_serial:
		source = _cycle_record(true)
	else:
		for archived: Dictionary in _cycle_history:
			if int(archived.get("cycle_serial", -1)) == cycle_serial:
				source = archived
				break
	if source.is_empty():
		return {"accepted": false, "failure_reason": &"cycle_not_retained", "cycle_serial": cycle_serial}
	var frame_times: Array = source.get("raw_frame_times_ms", [])
	var phase_ids: Array = source.get("raw_phase_ids", [])
	var explosion_flags: Array = source.get("raw_explosion_flags", [])
	var active_enemy_counts: Array = source.get("raw_active_enemy_counts", [])
	var safe_offset := clampi(offset, 0, frame_times.size())
	var safe_limit := clampi(limit, 1, RAW_PAGE_SIZE)
	var end := mini(safe_offset + safe_limit, frame_times.size())
	var samples: Array[Dictionary] = []
	for index in range(safe_offset, end):
		var frame_ms := float(frame_times[index])
		samples.append({
			"sample_index": index,
			"frame_ms": frame_ms,
			"phase": phase_ids[index] if index < phase_ids.size() else &"unknown",
			"explosion_window": bool(explosion_flags[index]) if index < explosion_flags.size() else false,
			"active_enemy_count": int(active_enemy_counts[index]) if index < active_enemy_counts.size() else -1,
			"below_45_fps": frame_ms > LOW_FPS_FRAME_MS,
		})
	return {
		"accepted": true,
		"cycle_serial": cycle_serial,
		"run_epoch": source.get("run_epoch", 0),
		"observed_viewport_start": source.get("observed_viewport_start", Vector2i.ZERO),
		"observed_viewport_end": source.get("observed_viewport_end", Vector2i.ZERO),
		"target_resolution": TARGET_RESOLUTION,
		"target_resolution_match": source.get("target_resolution_match", false),
		"renderer_context": source.get("renderer_context", {}),
		"evidence_state": source.get("evidence_state", &"incomplete"),
		"incomplete_reasons": source.get("incomplete_reasons", []),
		"offset": safe_offset,
		"limit": safe_limit,
		"returned_count": samples.size(),
		"total_count": frame_times.size(),
		"next_offset": end if end < frame_times.size() else -1,
		"samples": samples,
			"workload_counts_seen": _workload_counts_seen(active_enemy_counts),
			"one_percent_low_fps": _one_percent_low_fps(frame_times),
			"hitch_count": int(source.get("hitch_count", 0)),
			"hitch_threshold_ms": LOW_FPS_FRAME_MS,
		}


func _qualification_evidence_state() -> Dictionary:
	var records := _retained_cycle_records()
	var complete_cycle_count := 0
	var cycle_receipts: Array[Dictionary] = []
	var incomplete_reasons: Array[StringName] = []
	for record: Dictionary in records:
		var reasons: Array = record.get("incomplete_reasons", _cycle_incomplete_reasons(record))
		if reasons.is_empty():
			complete_cycle_count += 1
		else:
			for reason: Variant in reasons:
				var reason_id := StringName(reason)
				if reason_id not in incomplete_reasons:
					incomplete_reasons.append(reason_id)
		cycle_receipts.append({
			"cycle_serial": record.get("cycle_serial", 0),
			"run_epoch": record.get("run_epoch", 0),
			"evidence_state": record.get("evidence_state", &"incomplete"),
			"incomplete_reasons": reasons,
			"target_resolution_match": record.get("target_resolution_match", false),
			"raw_page_count": record.get("raw_page_count", 0),
		})
	if records.size() < CYCLE_HISTORY_LIMIT:
		incomplete_reasons.append(&"three_cycles_not_retained")
	return {
		"state": &"complete" if complete_cycle_count >= CYCLE_HISTORY_LIMIT and incomplete_reasons.is_empty() else &"incomplete",
		"required_complete_cycles": CYCLE_HISTORY_LIMIT,
		"retained_cycle_count": records.size(),
		"complete_cycle_count": complete_cycle_count,
		"incomplete_reasons": incomplete_reasons,
		"cycle_receipts": cycle_receipts,
		"hardware_verdict_asserted": false,
	}


func qualification_snapshot() -> Dictionary:
	_observed_viewport = Vector2i(get_viewport().get_visible_rect().size)
	return {
		"schema_version": 4,
		"presentation_neutral": true,
		"mutates_gameplay_authority": false,
		"observation_control": {
			"enabled": _qualification_enabled,
			"mode": _observation_mode,
			"epoch": _observation_epoch,
			"last_receipt": _last_observation_receipt,
			"ordinary_process_enabled": is_processing() and not _qualification_enabled,
			"ordinary_hotpath_scope": &"frame_time_accumulator_and_sampled_context",
			"deep_inspection_per_frame_in_ordinary_play": false,
			"candidate_hotpaths": CANDIDATE_HOTPATHS,
			"start_action": &"tester_qualification_start",
			"stop_action": &"tester_qualification_stop",
			"release_guard": &"OS.is_debug_build",
		},
		"target_resolution": TARGET_RESOLUTION,
		"target_resolution_source": &"configured_qualification_target",
		"observed_viewport": _observed_viewport,
		"target_resolution_match": _observed_viewport == TARGET_RESOLUTION,
		"renderer_context": _renderer_context(),
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
		"hitch_count": _hitch_count,
		"hitch_threshold_ms": LOW_FPS_FRAME_MS,
		"phase_aggregates": _phase_aggregates(),
		"explosion_sample_count": _explosion_sample_count,
		"explosion_current_low_fps_streak": _explosion_low_streak,
		"explosion_max_low_fps_streak": _explosion_max_low_streak,
		"explosion_threshold_breach_visible": _explosion_breach_visible,
		"active_enemy_count": _cached_active_enemy_count,
		"required_workload_counts": [3, 5, 10, 18],
		"workload_counts_seen": _workload_counts_seen(_raw_active_enemy_counts),
		"one_percent_low_fps": _one_percent_low_fps(_raw_frame_times_ms),
		"cleanup": _cleanup_counters.duplicate(true),
		"retained_cycle_limit": CYCLE_HISTORY_LIMIT,
		"retained_cycle_count": _retained_cycle_index().size(),
		"retained_cycle_index": _retained_cycle_index(),
		"cycle_history": _retained_cycle_index(),
		"qualification_evidence": _qualification_evidence_state(),
		"raw_sample_access": {
			"method": &"qualification_sample_page",
			"page_size": RAW_PAGE_SIZE,
			"independently_addressed_by": &"cycle_serial",
			"bounded": true,
		},
		"raw_frame_time_tail_ms": _raw_tail(),
		"qualification_fixture_contract": {
			"prepare_actions": {
				3: &"tester_encounter_alpha_prepare",
				5: &"tester_encounter_bravo_prepare",
				10: &"tester_encounter_charlie_prepare",
				18: &"tester_encounter_all_prepare",
			},
			"advance_action": &"tester_encounter_advance",
			"controls_unbound": true,
			"non_release": true,
			"requested_resolved_reset_receipt": true,
		},
		"combat_animation_observation": {
			"presentation_neutral": true,
			"production_bindings_only": true,
			"mutates_mission_authority": false,
			"deep_observation_interval_seconds": DEEP_OBSERVATION_INTERVAL,
			"deep_observation_count": _deep_observation_count,
			"sample_interval_seconds": COMBAT_SAMPLE_INTERVAL,
			"sample_count": _combat_animation_history.size(),
			"history": _combat_animation_history.duplicate(true),
		},
	}


func _mcp_state() -> Dictionary:
	return qualification_snapshot()
