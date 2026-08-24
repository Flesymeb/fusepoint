class_name FusepointBombObjectiveAdapter
extends Area3D

@export var player_path: NodePath
@export var mission_controller_path: NodePath

@onready var player: CharacterBody3D = get_node(player_path) as CharacterBody3D
@onready var mission_controller: Node = get_node(mission_controller_path)
@onready var label: Label3D = $ObjectiveLabel
@onready var core: MeshInstance3D = $BombCore
@onready var interaction_ring: MeshInstance3D = $InteractionRing
@onready var assembly: Node3D = $RocketBombAssembly
@onready var source_model: Node3D = $RocketBombAssembly/SourceModel
@onready var armed_light: OmniLight3D = $RocketBombAssembly/ArmedLight
var diagnosis_module: MeshInstance3D
var power_bus: MeshInstance3D
var detonator_lock: MeshInstance3D
var _core_material: StandardMaterial3D
var _module_materials: Array[StandardMaterial3D] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if core.get_active_material(0) is StandardMaterial3D:
		_core_material = core.get_active_material(0).duplicate() as StandardMaterial3D
		core.material_override = _core_material
	core.visible = false
	interaction_ring.visible = false
	_bind_imported_stage_parts()
	for module: MeshInstance3D in [diagnosis_module, power_bus, detonator_lock]:
		if module != null and module.get_active_material(0) is StandardMaterial3D:
			var material := module.get_active_material(0).duplicate() as StandardMaterial3D
			module.material_override = material
			_module_materials.append(material)


func _bind_imported_stage_parts() -> void:
	var fallback: Array[MeshInstance3D] = []
	for child in source_model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh == null:
			continue
		fallback.append(mesh)
		var mesh_name := String(mesh.name).to_lower()
		if mesh_name.begins_with("gold1"):
			diagnosis_module = mesh
		elif mesh_name.begins_with("green"):
			power_bus = mesh
		elif mesh_name.begins_with("red"):
			detonator_lock = mesh
	if diagnosis_module == null and fallback.size() > 0:
		diagnosis_module = fallback[0]
	if power_bus == null and fallback.size() > 1:
		power_bus = fallback[1]
	if detonator_lock == null and fallback.size() > 2:
		detonator_lock = fallback[2]


func _process(_delta: float) -> void:
	var state := mission_controller.call(&"objective_state_for", &"charlie") as Dictionary
	var legal: bool = state.get("legal", false) == true
	var bomb_state := StringName(state.get("state", &"armed"))
	var stage := String(state.get("stage_id", &"locked")).replace("_", " ").to_upper()
	var camera := get_viewport().get_camera_3d()
	var distance := INF if camera == null else camera.global_position.distance_to(global_position)
	label.visible = player.get("gameplay_input_enabled") == true and distance > 10.0 and (camera == null or not camera.is_position_behind(label.global_position))
	label.text = "C  ·  DEVICE SAFE" if bomb_state == &"defused" else "C  ·  DETONATED" if bomb_state == &"detonated" else "C  ·  BOMB" if legal else "C  ·  LOCKED"
	label.modulate = Color(0.2, 1.0, 0.72) if bomb_state == &"defused" else Color(1.0, 0.12, 0.035) if bomb_state == &"detonated" else Color(0.22, 0.92, 1.0) if legal else Color(1.0, 0.24, 0.14)
	if _core_material != null:
		_core_material.emission = Color(0.01, 0.5, 0.24) if bomb_state == &"defused" else Color(0.72, 0.015, 0.002) if bomb_state == &"detonated" else Color(0.02, 0.42, 0.6) if legal else Color(0.5, 0.025, 0.005)
		_core_material.albedo_color = Color(0.04, 0.26, 0.18) if bomb_state == &"defused" else Color(0.24, 0.035, 0.012) if bomb_state == &"detonated" else Color(0.08, 0.3, 0.36) if legal else Color(0.18, 0.08, 0.055)
	_update_assembly_presentation(state)


func _update_assembly_presentation(state: Dictionary) -> void:
	var bomb_state := StringName(state.get("state", &"armed"))
	var completed_count := int(mission_controller.get("bomb_stage_index"))
	var active_progress := clampf(float(state.get("progress", 0.0)), 0.0, 1.0)
	var active_stage: bool = mission_controller.get("_active_bomb_stage") == true
	var modules: Array[MeshInstance3D] = [diagnosis_module, power_bus, detonator_lock]
	for index in modules.size():
		var module := modules[index]
		if module == null or index >= _module_materials.size():
			continue
		var completed := index < completed_count or bomb_state == &"defused"
		var current := index == completed_count and active_stage
		var color := Color(0.045, 0.88, 0.62) if completed else Color(0.08, 0.72, 0.95) if current else Color(0.9, 0.055, 0.012)
		if bomb_state == &"detonated":
			color = Color(0.5, 0.018, 0.004)
		var material := _module_materials[index]
		material.emission = color
		material.emission_energy_multiplier = 0.55 if completed else (0.22 + active_progress * 0.26 if current else 0.08)
	if detonator_lock != null:
		detonator_lock.visible = bomb_state != &"defused" and completed_count < 3
	if armed_light != null:
		armed_light.light_color = Color(0.04, 0.95, 0.68) if bomb_state == &"defused" else Color(1.0, 0.08, 0.012)
		armed_light.light_energy = 0.0 if bomb_state == &"defused" else 2.4 if bomb_state == &"detonated" else 0.65


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
	state["authored_device"] = {
		"family_id": &"rocket_bomb_objective",
		"prd_style": &"grounded_military_maintenance",
		"source_quality": &"authored_textured_pbr",
		"expected_runtime_uses": 1,
		"semantic_singleton": true,
		"distinct_source_variants": 1,
		"runtime_variants": 1,
		"maximum_single_variant_share": 1.0,
		"diversity_axes": [&"physical_modules", &"indicators", &"safe_detonated_materials", &"staged_animation"],
		"declared_background": &"opaque_3d",
		"assembly_path": String(assembly.get_path()),
		"production_source": String(assembly.get_meta(&"production_source", "")),
		"mechanism": StringName(assembly.get_meta(&"mechanism", &"")),
		"collision_footprint_path": String($RocketBombAssembly/DeviceCollision/CollisionShape3D.get_path()),
		"primitive_core_visible": core.visible,
		"primitive_ring_visible": interaction_ring.visible,
		"stage_count": 3,
		"completed_stage_count": int(mission_controller.get("bomb_stage_index")),
		"stage_parts": [String(diagnosis_module.get_path()) if diagnosis_module != null else "", String(power_bus.get_path()) if power_bus != null else "", String(detonator_lock.get_path()) if detonator_lock != null else ""],
		"stage_binding": &"intact_imported_rocket_submeshes",
		"terminal_state": StringName(state.get("state", &"armed")),
	}
	return state
