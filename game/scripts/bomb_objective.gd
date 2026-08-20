class_name FusepointBombObjectiveAdapter
extends Area3D

@export var player_path: NodePath
@export var mission_controller_path: NodePath

@onready var player: CharacterBody3D = get_node(player_path) as CharacterBody3D
@onready var mission_controller: Node = get_node(mission_controller_path)
@onready var label: Label3D = $ObjectiveLabel
@onready var core: MeshInstance3D = $BombCore
var _core_material: StandardMaterial3D


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if core.get_active_material(0) is StandardMaterial3D:
		_core_material = core.get_active_material(0).duplicate() as StandardMaterial3D
		core.material_override = _core_material


func _process(_delta: float) -> void:
	var state := mission_controller.call(&"objective_state_for", &"charlie") as Dictionary
	var legal := bool(state.get("legal", false))
	var stage := String(state.get("stage_id", &"locked")).replace("_", " ").to_upper()
	label.text = "C  //  %s" % (stage if legal else "LOCKED")
	label.modulate = Color(0.22, 0.92, 1.0) if legal else Color(1.0, 0.24, 0.14)
	if _core_material != null:
		_core_material.emission = Color(0.02, 0.42, 0.6) if legal else Color(0.5, 0.025, 0.005)
		_core_material.albedo_color = Color(0.08, 0.3, 0.36) if legal else Color(0.18, 0.08, 0.055)


func _on_body_entered(body: Node3D) -> void:
	mission_controller.call(&"report_objective_overlap", &"charlie", true, body)


func _on_body_exited(body: Node3D) -> void:
	mission_controller.call(&"report_objective_overlap", &"charlie", false, body)


func _mcp_state() -> Dictionary:
	var state := mission_controller.call(&"objective_state_for", &"charlie") as Dictionary
	state["actual_overlap"] = overlaps_body(player)
	state["adapter_path"] = get_path()
	state["authority_path"] = mission_controller.get_path()
	state["player_position"] = player.global_position
	return state
