extends Node

const ROUTE_ID := "standoff_authoritative_a_b_c"
const EXPECTED_MIN_SECONDS := 30.0
const EXPECTED_MAX_SECONDS := 45.0
const MAX_SAMPLES := 24
const ROUTE_DECISIONS := [
	{"id": "spawn_courtyard", "position": Vector3(0.0, 0.9, 0.0)},
	{"id": "north_courtyard_turn", "position": Vector3(0.5, 0.9, 21.8)},
	{"id": "west_perimeter_lane", "position": Vector3(-19.4, 0.9, -18.7)},
	{"id": "central_cover_return", "position": Vector3(5.4, 0.9, -8.2)},
	{"id": "alpha_approach", "position": Vector3(-5.0, 0.9, -23.2)},
	{"id": "alpha_to_bravo_main", "position": Vector3(-5.0, 0.9, 2.0)},
	{"id": "alpha_to_bravo_flank", "position": Vector3(-17.0, 0.9, -5.0)},
	{"id": "bravo_fallback", "position": Vector3(-12.0, 0.9, 10.0)},
	{"id": "bravo_approach", "position": Vector3(-12.0, 0.9, 18.0)},
	{"id": "bravo_to_charlie_main", "position": Vector3(0.0, 0.9, 21.0)},
	{"id": "bravo_to_charlie_flank", "position": Vector3(-2.0, 0.9, 30.0)},
	{"id": "charlie_fallback", "position": Vector3(5.0, 0.9, 23.0)},
	{"id": "charlie_approach", "position": Vector3(10.0, 0.9, 29.0)},
]

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
	var nearest: Dictionary = ROUTE_DECISIONS[0]
	var nearest_distance := INF
	for decision in ROUTE_DECISIONS:
		var distance: float = player_position.distance_to(decision["position"])
		if distance < nearest_distance:
			nearest = decision
			nearest_distance = distance
	return {"id": nearest["id"], "distance": snappedf(nearest_distance, 0.01)}


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
		"ready": arena != null and bool(arena.get("collision_ready")),
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
			"spawn_to_a": ["main", "flank", "fallback"],
			"a_to_b": ["main", "flank", "fallback"],
			"b_to_c": ["main", "flank", "fallback"],
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
