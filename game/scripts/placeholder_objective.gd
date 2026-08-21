class_name FusepointCaptureObjectiveAdapter
extends Area3D

@export var objective_id := &"alpha"
@export var player_path: NodePath
@export var mission_controller_path: NodePath

const SAFE_AREA_RATIO := 0.05
const NOTICE_MIN_DISTANCE := 5.5
const NOTICE_RETICLE_CLEARANCE := Vector2(120.0, 96.0)

@onready var player: CharacterBody3D = get_node(player_path) as CharacterBody3D
@onready var mission_controller: Node = get_node(mission_controller_path)
@onready var label: Label3D = get_node_or_null("ObjectiveLabel") as Label3D
@onready var marker: MeshInstance3D = get_node_or_null("SurfaceMarker") as MeshInstance3D
var _marker_material: StandardMaterial3D
var _notice_budget: Dictionary = {}
var _hud_handoff_visible := false


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
		_update_notice_visibility(state)
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


func _update_notice_visibility(state: Dictionary) -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var margin := viewport_size * SAFE_AREA_RATIO
	var safe_rect := Rect2(margin, viewport_size - margin * 2.0)
	var camera := get_viewport().get_camera_3d()
	var desired: bool = player.get("gameplay_input_enabled") == true
	var suppression_reason := &""
	# Keep the locked world label out of reserved screen regions; the tactical
	# HUD owns its compact, authoritative route handoff at large UI scales.
	if state.get("legal", false) != true and objective_id != &"alpha":
		desired = false
		suppression_reason = &"authoritative_hud_handoff"
	if camera == null or not camera.current:
		desired = false
		suppression_reason = &"no_current_camera"
	var distance := INF if camera == null else camera.global_position.distance_to(label.global_position)
	if desired and (distance < NOTICE_MIN_DISTANCE or camera.is_position_behind(label.global_position)):
		desired = false
		suppression_reason = &"near_plane_or_behind_guard"
	var center := Vector2.ZERO if camera == null or camera.is_position_behind(label.global_position) else camera.unproject_position(label.global_position)
	var projected_height := 0.0
	if camera != null and distance > 0.01:
		var focal_pixels := viewport_size.y * 0.5 / tan(deg_to_rad(camera.fov) * 0.5)
		projected_height = (float(label.font_size + label.outline_size * 2) * label.pixel_size) * focal_pixels / distance
	var projected_width := projected_height * maxf(float(label.text.length()) * 0.58, 1.0)
	var screen_rect := Rect2(center - Vector2(projected_width, projected_height) * 0.5, Vector2(projected_width, projected_height))
	var reticle_rect := Rect2(viewport_size * 0.5 - NOTICE_RETICLE_CLEARANCE * 0.5, NOTICE_RETICLE_CLEARANCE)
	var top_guidance_rect := Rect2(Vector2(viewport_size.x * 0.5 - 310.0, margin.y), Vector2(620.0, 205.0))
	var viewmodel_rect := Rect2(Vector2(viewport_size.x * 0.48, viewport_size.y * 0.58), Vector2(viewport_size.x * 0.52 - margin.x, viewport_size.y * 0.42 - margin.y))
	var within_safe := safe_rect.encloses(screen_rect)
	var overlaps_reserved := screen_rect.intersects(reticle_rect) or screen_rect.intersects(top_guidance_rect) or screen_rect.intersects(viewmodel_rect)
	if desired and (not within_safe or overlaps_reserved):
		desired = false
		suppression_reason = &"reserved_hud_or_safe_area_guard"
	label.visible = desired
	_notice_budget = {
		"objective_id": objective_id,
		"source": &"authoritative_objective_state",
		"desired_visible": player.get("gameplay_input_enabled") == true,
		"visible": label.visible,
		"presentation_mode": &"compact_hud_handoff" if objective_id == &"bravo" and state.get("legal", false) != true else &"world_label",
		"hud_handoff_requested": objective_id == &"bravo" and state.get("legal", false) != true and player.get("gameplay_input_enabled") == true,
		"hud_handoff_visible": _hud_handoff_visible,
		"truthful_guidance_visible": label.visible or _hud_handoff_visible,
		"legal": state.get("legal", false) == true,
		"suppression_reason": suppression_reason,
		"screen_rect": screen_rect,
		"safe_rect": safe_rect,
		"within_safe_area": within_safe,
		"overlaps_reserved_hud": overlaps_reserved,
		"distance": distance,
	}


func notice_budget_state() -> Dictionary:
	return _notice_budget.duplicate(true)


func set_hud_handoff_visible(visible: bool) -> void:
	_hud_handoff_visible = visible


func _mcp_state() -> Dictionary:
	var state := mission_controller.call(&"objective_state_for", objective_id) as Dictionary
	state["actual_overlap"] = overlaps_body(player)
	state["adapter_path"] = get_path()
	state["authority_path"] = mission_controller.get_path()
	state["player_position"] = player.global_position
	state["notice_budget"] = notice_budget_state()
	return state
