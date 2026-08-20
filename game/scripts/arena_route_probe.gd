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


func _ready() -> void:
	var player := get_node_or_null(player_path) as CharacterBody3D
	if player != null:
		_fixed_spawn = player.global_position
		_last_player_position = player.global_position
		if player.has_signal("spawn_reset"):
			player.connect("spawn_reset", Callable(self, "_reset_trace"))


func _reset_trace() -> void:
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
	if player != null:
		_fixed_spawn = player.global_position
		_last_player_position = player.global_position


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
		effective_traversal_seconds += delta
		path_length_traveled += horizontal_displacement
	_last_player_position = player.global_position
	_update_collision_stall(player, horizontal_speed, delta)
	_sample_clock += delta
	if _sample_clock >= 2.0:
		_sample_clock = 0.0
		_append_sample(player, horizontal_speed)


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
	if player_position.distance_to(path[next_index]) < 1.25:
		next_index = mini(next_index + 1, path.size() - 1)
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
	var within_budget := effective_traversal_seconds >= EXPECTED_MIN_SECONDS and effective_traversal_seconds <= EXPECTED_MAX_SECONDS
	return {
		"route_id": ROUTE_ID,
		"ready": arena != null and arena.get("collision_ready") == true,
		"fixed_spawn": _fixed_spawn,
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
	}
