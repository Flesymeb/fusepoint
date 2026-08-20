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
var route_samples: Array[Dictionary] = []
var _sample_clock := 0.0
var _fixed_spawn := Vector3.ZERO
var _last_player_position := Vector3.ZERO


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
	if player.get_slide_collision_count() > 0:
		collision_frames += 1
	_sample_clock += delta
	if _sample_clock >= 2.0:
		_sample_clock = 0.0
		_append_sample(player, horizontal_speed)


func _append_sample(player: CharacterBody3D, horizontal_speed: float) -> void:
	var alpha := get_node_or_null(alpha_path) as Area3D
	var bravo := get_node_or_null(bravo_path) as Area3D
	var charlie := get_node_or_null(charlie_path) as Area3D
	var player_state: Dictionary = player.call("_mcp_state")
	route_samples.append({
		"effective_seconds": snappedf(effective_traversal_seconds, 0.01),
		"position": player.global_position,
		"grounded": player.is_on_floor(),
		"horizontal_speed": snappedf(horizontal_speed, 0.01),
		"locomotion_mode": player_state.get("locomotion_mode", "unknown"),
		"stance": player_state.get("stance", "unknown"),
		"jump_phase": player_state.get("jump_phase", "unknown"),
		"camera_height": player_state.get("camera_height", -1.0),
		"camera_fov": player_state.get("camera_fov", -1.0),
		"distance_to_alpha": player.global_position.distance_to(alpha.global_position) if alpha != null else -1.0,
	})
	while route_samples.size() > MAX_SAMPLES:
		route_samples.pop_front()


func _nearest_route_decision(player_position: Vector3) -> Dictionary:
	var decisions := _route_decisions()
	var nearest: Dictionary = decisions[0]
	var nearest_distance := INF
	for decision in decisions:
		var distance: float = player_position.distance_to(decision["position"])
		if distance < nearest_distance:
			nearest = decision
			nearest_distance = distance
	return {"id": nearest["id"], "distance": snappedf(nearest_distance, 0.01)}


func _route_decisions() -> Array[Dictionary]:
	var alpha := get_node_or_null(alpha_path) as Node3D
	var bravo := get_node_or_null(bravo_path) as Node3D
	var charlie := get_node_or_null(charlie_path) as Node3D
	var a := alpha.global_position - Vector3.UP * 0.3
	var b := bravo.global_position - Vector3.UP * 0.3
	var c := charlie.global_position - Vector3.UP * 0.3
	return [
		{"id":"spawn_courtyard","position":_fixed_spawn},
		{"id":"alpha_main","position":_project_to_nav(_fixed_spawn.lerp(a, 0.55))},
		{"id":"alpha_flank","position":_project_to_nav(_fixed_spawn.lerp(a, 0.55) + Vector3(6,0,0))},
		{"id":"alpha_fallback","position":_project_to_nav(a.lerp(_fixed_spawn, 0.25))},
		{"id":"alpha_overlap","position":a},
		{"id":"bravo_main","position":_project_to_nav(a.lerp(b, 0.55))},
		{"id":"bravo_flank","position":_project_to_nav(a.lerp(b, 0.55) + Vector3(-7,0,0))},
		{"id":"bravo_fallback","position":_project_to_nav(b.lerp(a, 0.25))},
		{"id":"bravo_overlap","position":b},
		{"id":"charlie_main","position":_project_to_nav(b.lerp(c, 0.55))},
		{"id":"charlie_flank","position":_project_to_nav(b.lerp(c, 0.55) + Vector3(0,0,7))},
		{"id":"charlie_fallback","position":_project_to_nav(c.lerp(b, 0.25))},
		{"id":"charlie_overlap","position":c},
	]


func _project_to_nav(point: Vector3) -> Vector3:
	var arena := get_node_or_null(arena_path) as Node3D
	return NavigationServer3D.map_get_closest_point(arena.get_world_3d().navigation_map, point)


func _path_report(from: Vector3, to: Vector3) -> Dictionary:
	var arena := get_node_or_null(arena_path) as Node3D
	var path := NavigationServer3D.map_get_path(arena.get_world_3d().navigation_map, _project_to_nav(from), _project_to_nav(to), true)
	var length := 0.0
	for index in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
	return {"connected": path.size() >= 2, "point_count": path.size(), "length": snappedf(length, 0.01)}


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
		"objective_separation": {
			"a_to_b": alpha.global_position.distance_to(bravo.global_position) if bravo != null else -1.0,
			"b_to_c": bravo.global_position.distance_to(charlie.global_position) if bravo != null and charlie != null else -1.0,
			"a_to_c": alpha.global_position.distance_to(charlie.global_position) if charlie != null else -1.0,
		},
		"route_edges": {
			"spawn_to_a": {"routes":["main","flank","fallback"],"navigation":_path_report(_fixed_spawn, alpha.global_position)},
			"a_to_b": {"routes":["main","flank","fallback"],"navigation":_path_report(alpha.global_position, bravo.global_position)},
			"b_to_c": {"routes":["main","flank","fallback"],"navigation":_path_report(bravo.global_position, charlie.global_position)},
		},
		"player_position": player.global_position,
		"distance_to_alpha": snappedf(distance_to_alpha, 0.01),
		"effective_traversal_seconds": snappedf(effective_traversal_seconds, 0.01),
		"path_length_traveled": snappedf(path_length_traveled, 0.01),
		"total_elapsed_seconds": snappedf(total_elapsed_seconds, 0.01),
		"expected_seconds": Vector2(EXPECTED_MIN_SECONDS, EXPECTED_MAX_SECONDS),
		"within_budget": within_budget,
		"grounded_ratio": snappedf(grounded_seconds / maxf(total_elapsed_seconds, 0.001), 0.001),
		"collision_frames": collision_frames,
		"objective_inside": objective_inside,
		"nearest_route_decision": _nearest_route_decision(player.global_position),
		"bounded_samples": route_samples,
	}
