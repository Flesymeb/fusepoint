extends Node

const ROUTE_ID := "standoff_authoritative_a_b_c"
const EXPECTED_MIN_SECONDS := 30.0
const EXPECTED_MAX_SECONDS := 45.0
const MAX_SAMPLES := 24

@export var player_path: NodePath
@export var alpha_path: NodePath
@export var bravo_path: NodePath
@export var charlie_path: NodePath
@export var arena_path: NodePath

var effective_traversal_seconds := 0.0
var path_length_traveled := 0.0
var total_elapsed_seconds := 0.0
var grounded_seconds := 0.0
var collision_frames := 0
var persistent_stall_seconds := 0.0
var route_samples: Array[Dictionary] = []
var _sample_clock := 0.0
var _fixed_spawn := Vector3.ZERO
var _last_player_position := Vector3.ZERO
var _last_blocker: Dictionary = {}
var _measurement_generation := 0
var _measurement_source := &"initial_ready"
var _first_movement: Dictionary = {}
var _completion_result: Dictionary = {}
var _route_milestones: Array[Dictionary] = []
var _capture_receipts: Array[Dictionary] = []
var _progression_receipts: Array[Dictionary] = []
var _last_capture_signature := ""
var _run_epoch := 0


func _ready() -> void:
	var player := get_node_or_null(player_path) as CharacterBody3D
	if player != null:
		_fixed_spawn = player.global_position
		_last_player_position = player.global_position
		if player.has_signal("spawn_reset"):
			player.connect("spawn_reset", Callable(self, "_reset_trace"))
	var arena := get_node_or_null(arena_path)
	if arena != null and arena.has_signal("walkable_topology_bound"):
		arena.connect("walkable_topology_bound", Callable(self, "_on_topology_bound"))
	var mission := get_tree().get_first_node_in_group(&"mission_controller")
	if mission != null and mission.has_signal(&"mission_event_committed"):
		mission.connect(&"mission_event_committed", Callable(self, "_on_mission_event"))
	_reset_trace(&"initial_ready")


func _on_topology_bound(report: Dictionary) -> void:
	if report.get("anchors_applied", false) == true:
		_reset_trace(&"native_anchor_bound")


func _reset_trace(source: StringName = &"spawn_reset") -> void:
	var player := get_node_or_null(player_path) as CharacterBody3D
	effective_traversal_seconds = 0.0
	path_length_traveled = 0.0
	total_elapsed_seconds = 0.0
	grounded_seconds = 0.0
	collision_frames = 0
	persistent_stall_seconds = 0.0
	_last_blocker.clear()
	_sample_clock = 0.0
	route_samples.clear()
	_first_movement.clear()
	_completion_result.clear()
	_route_milestones.clear()
	_capture_receipts.clear()
	_progression_receipts.clear()
	_last_capture_signature = ""
	_measurement_source = source
	_measurement_generation += 1
	if player != null:
		_fixed_spawn = player.global_position
		_last_player_position = player.global_position
		var player_state: Dictionary = player.call(&"_mcp_state")
		_measurement_generation = int(player_state.get("deployment_generation", _measurement_generation))
	var mission := get_tree().get_first_node_in_group(&"mission_controller")
	_run_epoch = int(mission.get("run_epoch")) if mission != null else 0
	_append_route_milestone(&"generation_reset", {"source": source})


func _physics_process(delta: float) -> void:
	var player := get_node_or_null(player_path) as CharacterBody3D
	if player == null:
		return
	total_elapsed_seconds += delta
	if player.is_on_floor():
		grounded_seconds += delta
	var horizontal_speed := Vector2(player.velocity.x, player.velocity.z).length()
	var horizontal_displacement := Vector2(
		player.global_position.x - _last_player_position.x,
		player.global_position.z - _last_player_position.z
	).length()
	if horizontal_displacement > 0.001:
		if _first_movement.is_empty():
			_first_movement = {
				"event_id": "route-first-movement-g%04d" % _measurement_generation,
				"measurement_generation": _measurement_generation,
				"mission_generation": _measurement_generation,
				"elapsed_seconds": snappedf(maxf(total_elapsed_seconds - delta, 0.0), 0.001),
				"position": player.global_position,
			}
			_append_route_milestone(&"first_movement", _first_movement)
		effective_traversal_seconds += delta
		path_length_traveled += horizontal_displacement
	_last_player_position = player.global_position
	_update_collision_stall(player, horizontal_speed, delta)
	_sample_clock += delta
	if _sample_clock >= 2.0:
		_sample_clock = 0.0
		_append_sample(player, horizontal_speed)
	_latch_first_legal_alpha_overlap(player)
	_update_authoritative_capture_receipt(player)
	_update_progress_milestones(player)


func _on_mission_event(event: Dictionary) -> void:
	var kind := StringName(event.get("kind", &""))
	if kind in [&"deployment_started", &"checkpoint_restored"]:
		_reset_trace(kind)
	if kind in [&"capture_started", &"capture_progress", &"capture_contested", &"capture_interrupted", &"capture_completed"]:
		_append_capture_receipt(kind, event)
	if kind in [&"deployment_started", &"capture_completed", &"checkpoint_committed", &"objective_enter", &"defusal_started", &"terminal_submitted", &"checkpoint_restored"]:
		_append_progression_receipt(kind, event)


func _append_progression_receipt(kind: StringName, event: Dictionary) -> void:
	var mission := get_tree().get_first_node_in_group(&"mission_controller")
	var roster := get_tree().get_first_node_in_group(&"enemy_roster")
	var mission_state: Dictionary = mission.call(&"_mcp_state") if mission != null else {}
	var roster_state: Dictionary = roster.call(&"_mcp_state") if roster != null else {}
	var payload: Dictionary = event.get("payload", {})
	var objective_id := StringName(payload.get("objective_id", &""))
	if kind == &"objective_enter" and objective_id != &"charlie":
		return
	var stage := kind
	if kind == &"capture_completed":
		stage = &"alpha_secured" if objective_id == &"alpha" else &"bravo_secured" if objective_id == &"bravo" else kind
	elif kind == &"objective_enter":
		stage = &"charlie_entered"
	var receipt := {
		"event_id": String(event.get("event_id", "run-%06d:progression:%03d" % [_run_epoch, _progression_receipts.size() + 1])),
		"kind": kind,
		"stage": stage,
		"objective_id": objective_id,
		"run_epoch": _run_epoch,
		"measurement_generation": _measurement_generation,
		"player_position": (get_node_or_null(player_path) as Node3D).global_position if get_node_or_null(player_path) is Node3D else Vector3.ZERO,
		"capture_points": mission_state.get("capture_points", {}).duplicate(true),
		"overlaps": mission_state.get("overlaps", {}).duplicate(true),
		"bomb_state": mission_state.get("bomb_state", &"unknown"),
		"enemy_region_counts": roster_state.get("region_counts", {}).duplicate(true),
		"enemy_active_count": roster_state.get("active_count", -1),
		"enemy_alive_count": roster_state.get("alive_count", -1),
		"stable_identity_count": roster_state.get("stable_identity_count", -1),
		"committed_frame": int(event.get("committed_frame", Engine.get_process_frames())),
		"committed_at_usec": int(event.get("committed_at_usec", Time.get_ticks_usec())),
	}
	_progression_receipts.append(receipt)
	while _progression_receipts.size() > 24:
		_progression_receipts.pop_front()


func _append_route_milestone(kind: StringName, payload: Dictionary = {}) -> void:
	var receipt := payload.duplicate(true)
	receipt["event_id"] = "run-%06d:route-g%04d:%s:%03d" % [_run_epoch, _measurement_generation, kind, _route_milestones.size() + 1]
	receipt["kind"] = kind
	receipt["run_epoch"] = _run_epoch
	receipt["measurement_generation"] = _measurement_generation
	receipt["committed_frame"] = Engine.get_process_frames()
	receipt["committed_at_usec"] = Time.get_ticks_usec()
	_route_milestones.append(receipt)
	while _route_milestones.size() > 32:
		_route_milestones.pop_front()


func _append_capture_receipt(kind: StringName, payload: Dictionary) -> void:
	var receipt := payload.duplicate(true)
	receipt["kind"] = kind
	receipt["run_epoch"] = _run_epoch
	receipt["measurement_generation"] = _measurement_generation
	receipt["committed_frame"] = int(receipt.get("committed_frame", Engine.get_process_frames()))
	receipt["committed_at_usec"] = int(receipt.get("committed_at_usec", Time.get_ticks_usec()))
	_capture_receipts.append(receipt)
	while _capture_receipts.size() > 32:
		_capture_receipts.pop_front()


func _update_authoritative_capture_receipt(player: CharacterBody3D) -> void:
	var alpha := get_node_or_null(alpha_path) as Area3D
	var mission := get_tree().get_first_node_in_group(&"mission_controller")
	if alpha == null or mission == null:
		return
	var state: Dictionary = mission.call(&"objective_state_for", &"alpha")
	var overlap := alpha.overlaps_body(player)
	var progress_bucket := int(floor(float(state.get("progress", 0.0)) * 20.0))
	var signature := "%s:%s:%d" % [overlap, String(state.get("state", &"unknown")), progress_bucket]
	if signature == _last_capture_signature:
		return
	_last_capture_signature = signature
	_append_capture_receipt(&"authoritative_alpha_sample", {
		"event_id": "run-%06d:alpha-sample-g%04d:%03d" % [_run_epoch, _measurement_generation, _capture_receipts.size() + 1],
		"overlap": overlap,
		"legal": state.get("legal", false),
		"progress": state.get("progress", 0.0),
		"state": state.get("state", &"unknown"),
		"owner": state.get("owner", &"unknown"),
		"player_position": player.global_position,
	})


func _update_progress_milestones(player: CharacterBody3D) -> void:
	if _first_movement.is_empty():
		return
	var route := _route_progress(player.global_position)
	var ratio := float(route.get("progress_ratio", 0.0))
	for milestone in [{"kind": &"early", "threshold": 0.08}, {"kind": &"middle", "threshold": 0.45}, {"kind": &"late", "threshold": 0.82}]:
		var kind := StringName(milestone["kind"])
		var already_recorded := _route_milestones.any(func(receipt: Dictionary) -> bool: return StringName(receipt.get("kind", &"")) == kind)
		if not already_recorded and ratio >= float(milestone["threshold"]):
			_append_route_milestone(kind, {
				"player_position": player.global_position,
				"route_progress": ratio,
				"cross_track_distance": route.get("cross_track_distance", -1.0),
			})


func _latch_first_legal_alpha_overlap(player: CharacterBody3D) -> void:
	if not _completion_result.is_empty() or _first_movement.is_empty():
		return
	var alpha := get_node_or_null(alpha_path) as Area3D
	var mission := get_tree().get_first_node_in_group(&"mission_controller")
	if alpha == null or mission == null or not alpha.overlaps_body(player):
		return
	var objective_state: Dictionary = mission.call(&"objective_state_for", &"alpha")
	if objective_state.get("legal", false) != true:
		return
	var elapsed_from_first_movement := total_elapsed_seconds - float(_first_movement.get("elapsed_seconds", 0.0))
	var within_observed_budget := elapsed_from_first_movement >= EXPECTED_MIN_SECONDS and elapsed_from_first_movement <= EXPECTED_MAX_SECONDS
	_completion_result = {
		"event_id": "route-alpha-overlap-g%04d" % _measurement_generation,
		"measurement_generation": _measurement_generation,
		"mission_generation": _measurement_generation,
		"first_movement": _first_movement.duplicate(true),
		"first_alpha_overlap_elapsed_seconds": snappedf(total_elapsed_seconds, 0.01),
		"elapsed_from_first_movement_seconds": snappedf(elapsed_from_first_movement, 0.01),
		"effective_traversal_seconds": snappedf(effective_traversal_seconds, 0.01),
		"traveled_distance": snappedf(path_length_traveled, 0.01),
		"grounded_ratio": snappedf(grounded_seconds / maxf(total_elapsed_seconds, 0.001), 0.001),
		"collision_frames": collision_frames,
		"persistent_stall_seconds": snappedf(persistent_stall_seconds, 0.01),
		"collision_blocker": _last_blocker.duplicate(true),
		"ordered_navigation_corners": _route_chain(&"spawn_to_a"),
		"within_budget": within_observed_budget,
		"budget_metric": &"elapsed_from_first_movement_seconds",
		"ordinary_input_authority": true,
		"latched": true,
	}
	_append_route_milestone(&"legal_alpha_overlap", _completion_result)
	var arena := get_node_or_null(arena_path)
	if arena != null and arena.has_method(&"accept_observed_route_budget"):
		_completion_result["arena_transaction_accepted"] = arena.call(&"accept_observed_route_budget", _completion_result)


func _update_collision_stall(player: CharacterBody3D, horizontal_speed: float, delta: float) -> void:
	var input_vector := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var blocker := _horizontal_blocker(player)
	var stalled := input_vector.length() > 0.25 and horizontal_speed < 0.25 and not blocker.is_empty()
	if stalled:
		collision_frames += 1
		persistent_stall_seconds += delta
		_last_blocker = blocker
	else:
		persistent_stall_seconds = 0.0


func _horizontal_blocker(player: CharacterBody3D) -> Dictionary:
	for index in player.get_slide_collision_count():
		var collision := player.get_slide_collision(index)
		if absf(collision.get_normal().y) >= 0.55:
			continue
		var collider := collision.get_collider()
		return {
			"collider_path": str(collider.get_path()) if collider is Node else str(collider),
			"normal": collision.get_normal(),
			"position": collision.get_position(),
		}
	return {}


func _append_sample(player: CharacterBody3D, horizontal_speed: float) -> void:
	var alpha := get_node_or_null(alpha_path) as Area3D
	var player_state: Dictionary = player.call("_mcp_state")
	var route := _route_progress(player.global_position)
	route_samples.append({
		"effective_seconds": snappedf(effective_traversal_seconds, 0.01),
		"position": player.global_position,
		"grounded": player.is_on_floor(),
		"horizontal_speed": snappedf(horizontal_speed, 0.01),
		"locomotion_mode": player_state.get("locomotion_mode", "unknown"),
		"stance": player_state.get("stance", "unknown"),
		"jump_phase": player_state.get("jump_phase", "unknown"),
		"distance_to_alpha": player.global_position.distance_to(alpha.global_position) if alpha != null else -1.0,
		"leg_id": route.get("leg_id", &""),
		"route_progress": route.get("progress_ratio", 0.0),
		"next_corner": route.get("next_corner", Vector3.ZERO),
		"stall_seconds": snappedf(persistent_stall_seconds, 0.01),
	})
	while route_samples.size() > MAX_SAMPLES:
		route_samples.pop_front()


func _active_leg_id() -> StringName:
	var mission := get_tree().get_first_node_in_group(&"mission_controller")
	if mission == null:
		return &"spawn_to_a"
	var points: Dictionary = mission.get("capture_points")
	if StringName(points.get(&"alpha", {}).get("state", &"held_rift")) != &"secured_aegis":
		return &"spawn_to_a"
	if StringName(points.get(&"bravo", {}).get("state", &"held_rift")) != &"secured_aegis":
		return &"a_to_b"
	return &"b_to_c"


func _route_chain(leg_id: StringName) -> PackedVector3Array:
	var arena := get_node_or_null(arena_path)
	if arena != null and arena.has_method(&"get_route_chain"):
		return arena.call(&"get_route_chain", leg_id)
	return PackedVector3Array()


func _route_progress(player_position: Vector3) -> Dictionary:
	var leg_id := _active_leg_id()
	var path := _route_chain(leg_id)
	if path.size() < 2:
		return {"leg_id": leg_id, "ready": false}
	var total_length := 0.0
	var lengths := PackedFloat32Array([0.0])
	for index in range(1, path.size()):
		total_length += path[index - 1].distance_to(path[index])
		lengths.append(total_length)
	var best_distance := INF
	var best_progress := 0.0
	var best_segment := 0
	for index in range(1, path.size()):
		var from := path[index - 1]
		var to := path[index]
		var segment := to - from
		var segment_length_squared := segment.length_squared()
		var weight := 0.0 if segment_length_squared <= 0.0001 else clampf((player_position - from).dot(segment) / segment_length_squared, 0.0, 1.0)
		var projected := from + segment * weight
		var distance := Vector2(player_position.x - projected.x, player_position.z - projected.z).length()
		if distance < best_distance:
			best_distance = distance
			best_segment = index - 1
			best_progress = lengths[index - 1] + from.distance_to(projected)
	var next_index := mini(best_segment + 1, path.size() - 1)
	while next_index < path.size() - 1 and player_position.distance_to(path[next_index]) < 1.25:
		next_index += 1
	return {
		"ready": true,
		"leg_id": leg_id,
		"ordered_corners": path,
		"corner_count": path.size(),
		"current_segment": best_segment,
		"next_corner_index": next_index,
		"next_corner": path[next_index],
		"path_length": snappedf(total_length, 0.01),
		"progress_distance": snappedf(best_progress, 0.01),
		"progress_ratio": snappedf(best_progress / maxf(total_length, 0.001), 0.001),
		"cross_track_distance": snappedf(best_distance, 0.01),
	}


func _path_report(leg_id: StringName) -> Dictionary:
	var path := _route_chain(leg_id)
	var length := 0.0
	for index in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
	return {
		"connected": path.size() >= 2,
		"point_count": path.size(),
		"length": snappedf(length, 0.01),
		"ordered_corners": path,
	}


func _mcp_state() -> Dictionary:
	var player := get_node_or_null(player_path) as CharacterBody3D
	var alpha := get_node_or_null(alpha_path) as Area3D
	var bravo := get_node_or_null(bravo_path) as Area3D
	var charlie := get_node_or_null(charlie_path) as Area3D
	var arena := get_node_or_null(arena_path)
	if player == null or alpha == null:
		return {"route_id": ROUTE_ID, "ready": false}
	var distance_to_alpha := player.global_position.distance_to(alpha.global_position)
	var objective_inside := alpha.overlaps_body(player)
	var elapsed_from_first_movement := (
		total_elapsed_seconds - float(_first_movement.get("elapsed_seconds", 0.0))
		if not _first_movement.is_empty()
		else 0.0
	)
	var within_budget := elapsed_from_first_movement >= EXPECTED_MIN_SECONDS and elapsed_from_first_movement <= EXPECTED_MAX_SECONDS
	return {
		"route_id": ROUTE_ID,
		"ready": arena != null and arena.get("collision_ready") == true and arena.get("topology_ready") == true,
		"fixed_spawn": _fixed_spawn,
		"measurement_generation": _measurement_generation,
		"measurement_source": _measurement_source,
		"run_epoch": _run_epoch,
		"first_movement": _first_movement,
		"completion_result": _completion_result,
		"alpha_position": alpha.global_position,
		"bravo_position": bravo.global_position if bravo != null else Vector3.ZERO,
		"charlie_position": charlie.global_position if charlie != null else Vector3.ZERO,
		"route_edges": {
			"spawn_to_a": _path_report(&"spawn_to_a"),
			"a_to_b": _path_report(&"a_to_b"),
			"b_to_c": _path_report(&"b_to_c"),
		},
		"active_route": _route_progress(player.global_position),
		"capsule_clearance": arena.get("route_clearance") if arena != null else {},
		"player_position": player.global_position,
		"distance_to_alpha": snappedf(distance_to_alpha, 0.01),
		"effective_traversal_seconds": snappedf(effective_traversal_seconds, 0.01),
		"elapsed_from_first_movement_seconds": snappedf(elapsed_from_first_movement, 0.01),
		"budget_metric": &"elapsed_from_first_movement_seconds",
		"path_length_traveled": snappedf(path_length_traveled, 0.01),
		"total_elapsed_seconds": snappedf(total_elapsed_seconds, 0.01),
		"expected_seconds": Vector2(EXPECTED_MIN_SECONDS, EXPECTED_MAX_SECONDS),
		"within_budget": within_budget,
		"grounded_ratio": snappedf(grounded_seconds / maxf(total_elapsed_seconds, 0.001), 0.001),
		"collision_frames": collision_frames,
		"persistent_stall_seconds": snappedf(persistent_stall_seconds, 0.01),
		"collision_blocker": _last_blocker,
		"objective_inside": objective_inside,
		"bounded_samples": route_samples,
		"route_milestones": _route_milestones,
		"capture_receipts": _capture_receipts,
		"progression_receipts": _progression_receipts,
		"uninterrupted_progression_generation": _progression_receipts.all(func(receipt: Dictionary) -> bool: return int(receipt.get("measurement_generation", -1)) == _measurement_generation),
		"causal_generation_bound": _route_milestones.all(func(receipt: Dictionary) -> bool: return int(receipt.get("measurement_generation", -1)) == _measurement_generation) and _capture_receipts.all(func(receipt: Dictionary) -> bool: return int(receipt.get("measurement_generation", -1)) == _measurement_generation),
	}
