extends Area3D

@export var objective_id := "alpha"
@export var player_path: NodePath
@export_range(2, 32, 1) var history_limit := 16

var objective_state := "outside"
var occupant_path := ""
var transition_count := 0
var last_event: Dictionary = {}
var event_history: Array[Dictionary] = []


func _ready() -> void:
	var entered_callable := Callable(self, "_on_body_entered")
	var exited_callable := Callable(self, "_on_body_exited")
	if not body_entered.is_connected(entered_callable):
		body_entered.connect(entered_callable)
	if not body_exited.is_connected(exited_callable):
		body_exited.connect(exited_callable)
	var player := get_node_or_null(player_path) as CharacterBody3D
	if player != null and player.has_signal("spawn_reset"):
		var reset_callable := Callable(self, "_reset_authority")
		if not player.is_connected("spawn_reset", reset_callable):
			player.connect("spawn_reset", reset_callable)


func _reset_authority() -> void:
	objective_state = "outside"
	occupant_path = ""
	transition_count = 0
	last_event = {}
	event_history.clear()


func _on_body_entered(body: Node3D) -> void:
	if not _is_authoritative_player(body) or objective_state == "inside":
		return
	_record_transition("enter", body, "outside", "inside", true)
	objective_state = "inside"
	occupant_path = str(body.get_path())


func _on_body_exited(body: Node3D) -> void:
	if not _is_authoritative_player(body) or objective_state != "inside":
		return
	_record_transition("leave", body, "inside", "outside", false)
	objective_state = "outside"
	occupant_path = ""


func _is_authoritative_player(body: Node3D) -> bool:
	var player := get_node_or_null(player_path) as CharacterBody3D
	return player != null and body == player and body.is_in_group("player")


func _record_transition(
	kind: String,
	body: Node3D,
	prior_state: String,
	resulting_state: String,
	overlap_predicate: bool
) -> void:
	transition_count += 1
	last_event = {
		"sequence": transition_count,
		"kind": kind,
		"prior_state": prior_state,
		"resulting_state": resulting_state,
		"player_path": str(body.get_path()),
		"player_position": body.global_position,
		"overlap_predicate": overlap_predicate,
		"timestamp_msec": Time.get_ticks_msec(),
	}
	event_history.append(last_event.duplicate(true))
	while event_history.size() > history_limit:
		event_history.pop_front()


func _mcp_state() -> Dictionary:
	var player := get_node_or_null(player_path) as CharacterBody3D
	var actual_overlap := player != null and overlaps_body(player)
	return {
		"objective_id": objective_id,
		"objective_state": objective_state,
		"inside": objective_state == "inside",
		"occupant_path": occupant_path,
		"transition_count": transition_count,
		"last_event": last_event,
		"event_history": event_history,
		"history_limit": history_limit,
		"actual_overlap": actual_overlap,
		"player_position": player.global_position if player != null else Vector3.ZERO,
		"body_entered_bound": body_entered.is_connected(Callable(self, "_on_body_entered")),
		"body_exited_bound": body_exited.is_connected(Callable(self, "_on_body_exited")),
	}
