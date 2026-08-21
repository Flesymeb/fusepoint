class_name FusepointCaptureObjectiveAdapter
extends Area3D

@export var objective_id := &"alpha"
@export var player_path: NodePath
@export var mission_controller_path: NodePath

@onready var player: CharacterBody3D = get_node(player_path) as CharacterBody3D
@onready var mission_controller: Node = get_node(mission_controller_path)
@onready var label: Label3D = get_node_or_null("ObjectiveLabel") as Label3D
@onready var marker: MeshInstance3D = get_node_or_null("SurfaceMarker") as MeshInstance3D
var _marker_material: StandardMaterial3D


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if marker != null and marker.get_active_material(0) is StandardMaterial3D:
		_marker_material = marker.get_active_material(0).duplicate() as StandardMaterial3D
		marker.material_override = _marker_material


func _process(_delta: float) -> void:
	var state := mission_controller.call(&"objective_state_for", objective_id) as Dictionary
	if label != null:
		label.text = "%s  ·  %s" % [String(objective_id).left(1).to_upper(), _display_state(state)]
		label.modulate = Color(0.12, 0.88, 1.0) if state.get("legal", false) == true else Color(1.0, 0.32, 0.18)
	if _marker_material != null:
		_marker_material.albedo_color = Color(0.04, 0.72, 0.86, 0.26) if state.get("legal", false) == true else Color(0.92, 0.12, 0.04, 0.24)
		_marker_material.emission = Color(0.01, 0.36, 0.5) if state.get("legal", false) == true else Color(0.5, 0.025, 0.005)


func _on_body_entered(body: Node3D) -> void:
	mission_controller.call(&"report_objective_overlap", objective_id, true, body)


func _on_body_exited(body: Node3D) -> void:
	mission_controller.call(&"report_objective_overlap", objective_id, false, body)


func _display_state(state: Dictionary) -> String:
	if state.get("legal", false) != true:
		return "LOCKED"
	match StringName(state.get("state", &"held_rift")):
		&"secured_aegis": return "SECURED"
		&"capturing_aegis": return "CAPTURING %d%%" % int(float(state.get("progress", 0.0)) * 100.0)
		_: return "HOSTILE"


func _mcp_state() -> Dictionary:
	var state := mission_controller.call(&"objective_state_for", objective_id) as Dictionary
	state["actual_overlap"] = overlaps_body(player)
	state["adapter_path"] = get_path()
	state["authority_path"] = mission_controller.get_path()
	state["player_position"] = player.global_position
	return state
