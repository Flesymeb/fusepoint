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
@onready var device_root: Node3D = get_node_or_null("DeviceRoot") as Node3D
@onready var state_beacon: MeshInstance3D = get_node_or_null("DeviceRoot/StateBeacon") as MeshInstance3D
@onready var progress_lens: MeshInstance3D = get_node_or_null("DeviceRoot/ProgressLens") as MeshInstance3D
@onready var device_light: OmniLight3D = get_node_or_null("DeviceRoot/DeviceLight") as OmniLight3D
var _marker_material: StandardMaterial3D
var _source_state_materials: Array[StandardMaterial3D] = []
var _notice_budget: Dictionary = {}
var _hud_handoff_visible := false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if marker != null and marker.get_active_material(0) is StandardMaterial3D:
		_marker_material = marker.get_active_material(0).duplicate() as StandardMaterial3D
		marker.material_override = _marker_material
	if marker != null:
		marker.visible = false
	_bind_source_state_materials()


func _bind_source_state_materials() -> void:
	if device_root == null:
		return
	var source_root := device_root.get_node_or_null("SourceModel")
	if source_root == null:
		return
	for child in source_root.find_children("*", "MeshInstance3D", true, false):
		var source_mesh := child as MeshInstance3D
		if source_mesh == null or not source_mesh.get_active_material(0) is StandardMaterial3D:
			continue
		var material := source_mesh.get_active_material(0).duplicate() as StandardMaterial3D
		material.emission_enabled = true
		source_mesh.material_override = material
		_source_state_materials.append(material)


func _process(_delta: float) -> void:
	var state := mission_controller.call(&"objective_state_for", objective_id) as Dictionary
	if label != null:
		label.text = "%s  ·  %s" % [String(objective_id).left(1).to_upper(), _display_state(state)]
		label.modulate = Color(0.12, 0.88, 1.0) if state.get("legal", false) == true else Color(1.0, 0.32, 0.18)
		_update_notice_visibility(state)
	if _marker_material != null:
		_marker_material.albedo_color = Color(0.04, 0.72, 0.86, 0.26) if state.get("legal", false) == true else Color(0.92, 0.12, 0.04, 0.24)
		_marker_material.emission = Color(0.01, 0.36, 0.5) if state.get("legal", false) == true else Color(0.5, 0.025, 0.005)
	_update_device_presentation(state)


func _unique_material(mesh: MeshInstance3D) -> StandardMaterial3D:
	if mesh == null or not mesh.get_active_material(0) is StandardMaterial3D:
		return null
	var material := mesh.get_active_material(0).duplicate() as StandardMaterial3D
	mesh.material_override = material
	return material


func _update_device_presentation(state: Dictionary) -> void:
	var point_state := StringName(state.get("state", &"held_rift"))
	var progress := clampf(float(state.get("progress", 0.0)), 0.0, 1.0)
	# Preserve state truth while keeping the two device functions visually
	# distinct: Alpha reads as warning-yellow topology gear and Bravo as a cyan
	# communications console before state animation takes over.
	var color := Color(1.0, 0.52, 0.035) if objective_id == &"alpha" else Color(0.04, 0.68, 0.96)
	match point_state:
		&"capturing_aegis": color = Color(0.02, 0.72, 0.92)
		&"contested_rift": color = Color(1.0, 0.52, 0.035)
		&"recapturing_rift": color = Color(0.95, 0.19, 0.02)
		&"secured_aegis": color = Color(0.04, 0.92, 0.68)
	var pulse := 0.82 + sin(Time.get_ticks_msec() * 0.012) * 0.18 if point_state == &"contested_rift" else 1.0
	for state_material in _source_state_materials:
		state_material.emission = color
		state_material.emission_energy_multiplier = (0.18 + progress * 0.22) * pulse
	if device_light != null:
		device_light.light_color = color
		device_light.light_energy = (1.2 if point_state in [&"capturing_aegis", &"contested_rift"] else 0.42) * pulse


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
	state["authored_device"] = {
		"family_id": &"capture_objective_devices",
		"prd_style": &"grounded_military_industrial",
		"source_quality": &"authored_textured_pbr",
		"expected_runtime_uses": 2,
		"distinct_source_variants": 2,
		"runtime_variants": 2,
		"maximum_single_variant_share": 0.5,
		"diversity_axes": [&"device_silhouette", &"function", &"materials", &"light_assembly", &"state_motion"],
		"declared_background": &"opaque_3d",
		"device_path": String(device_root.get_path()) if device_root != null else "",
		"production_source": String(device_root.get_meta(&"production_source", "")) if device_root != null else "",
		"mechanism": StringName(device_root.get_meta(&"mechanism", &"")) if device_root != null else &"",
		"state_beacon_path": String(state_beacon.get_path()) if state_beacon != null else "",
		"state_binding": &"intact_source_materials_and_device_light",
		"source_material_binding_count": _source_state_materials.size(),
		"collision_footprint_path": String(get_node("DeviceRoot/DeviceCollision/CollisionShape3D").get_path()) if has_node("DeviceRoot/DeviceCollision/CollisionShape3D") else "",
		"primitive_surface_ring_visible": marker.visible if marker != null else false,
		"presentation_state": StringName(state.get("state", &"held_rift")),
		"presentation_progress": float(state.get("progress", 0.0)),
	}
	return state
