extends Node

const ROUTE_ID := "standoff_spawn_to_alpha"
const EXPECTED_MIN_SECONDS := 30.0
const EXPECTED_MAX_SECONDS := 45.0
const MAX_SAMPLES := 24
const ROUTE_DECISIONS := [
	{"id": "spawn_courtyard", "position": Vector3(0.0, 0.9, 0.0)},
	{"id": "north_courtyard_turn", "position": Vector3(0.5, 0.9, 21.8)},
	{"id": "west_perimeter_lane", "position": Vector3(-19.4, 0.9, -18.7)},
	{"id": "central_cover_return", "position": Vector3(5.4, 0.9, -8.2)},
	{"id": "alpha_approach", "position": Vector3(-5.0, 0.9, -23.2)},
]

@export var player_path: NodePath
@export var alpha_path: NodePath
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
	route_samples.append({
		"effective_seconds": snappedf(effective_traversal_seconds, 0.01),
		"position": player.global_position,
		"grounded": player.is_on_floor(),
		"horizontal_speed": snappedf(horizontal_speed, 0.01),
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
	var arena := get_node_or_null(arena_path)
	if player == null or alpha == null:
		return {"route_id": ROUTE_ID, "ready": false}
	var distance_to_alpha := player.global_position.distance_to(alpha.global_position)
	var objective_inside := bool(alpha.get("objective_state") == "inside")
	var within_budget := effective_traversal_seconds >= EXPECTED_MIN_SECONDS and effective_traversal_seconds <= EXPECTED_MAX_SECONDS
	return {
		"route_id": ROUTE_ID,
		"ready": arena != null and bool(arena.get("collision_ready")),
		"fixed_spawn": _fixed_spawn,
		"alpha_position": alpha.global_position,
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
