class_name FusepointTacticalHUD
extends CanvasLayer

signal combat_row_presented(receipt: Dictionary)

const DEPLOYMENT_STORY_TEXT := "11:40 - Kestrel Ridge Military Base\nRift Front armed a timed bomb in Sector C.\nCommunications are down. Support is not coming.\nRetake Alpha, hold Bravo, recover both keys.\nDefuse Charlie before the five-minute detonation."
const DEPLOYMENT_STORY_CUES: Array[String] = [
	"11:40 - Kestrel Ridge Military Base.",
	"Rift Front armed a timed bomb in Sector C.",
	"Communications are down. Support is not coming.",
	"Retake Alpha, hold Bravo, and recover both keys.",
	"Defuse Charlie before the five-minute detonation.",
]
const SAFE_AREA_RATIO := 0.05
const LAYOUT_CONTRACT_ID := &"fusepoint_safe_area_v4_split_narrative_lanes"
const COMBAT_ROW_LIFETIME_SECONDS := 6.0
const COMBAT_ROW_LIMIT := 5
const STORY_TYPE_SECONDS := 1.35
const OPENING_REVEAL_SECONDS := 6.0
const OPENING_HOLD_END_SECONDS := 10.0
const OPENING_FADE_END_SECONDS := 13.0
const COMBAT_FEED_ALLOWED_KINDS: Array[StringName] = [
	&"capture_started", &"capture_contested", &"capture_interrupted", &"capture_completed",
	&"key_committed", &"route_unlocked", &"checkpoint_committed",
	&"deployment_started", &"checkpoint_restored", &"weapon_hit",
	&"enemy_died", &"defusal_locked", &"defusal_started", &"defusal_interrupted",
	&"defusal_completed", &"terminal_submitted", &"player_damage", &"player_death",
]

@onready var root: Control = $Root
@onready var minimap: Control = $Root/Minimap
@onready var map_title: Label = $Root/MapTitle
@onready var vitals: Control = $Root/Vitals
@onready var weapon_hud: Control = $Root/WeaponAmmoHUD
@onready var time_label: Label = $Root/CountdownRail/Time
@onready var keys_label: Label = $Root/CountdownRail/Keys
@onready var stage_label: Label = $Root/CountdownRail/Stage
@onready var compass_label: Label = $Root/Compass
@onready var route_label: Label = $Root/RouteMarker
@onready var stance_label: Label = $Root/Stance
@onready var objective_band: Control = $Root/ObjectiveBand
@onready var objective_label: Label = $Root/ObjectiveBand/Layout/Objective
@onready var objective_progress: ProgressBar = $Root/ObjectiveBand/Layout/Progress
@onready var objective_detail: Label = $Root/ObjectiveBand/Layout/Detail
@onready var narrative: Label = $Root/Narrative
@onready var feed: VBoxContainer = $Root/CombatFeed
@onready var reticle: Control = $Root/Reticle

var player: CharacterBody3D
var weapon: Node
var mission: Node
var route_probe: Node
var arena: Node3D
var _story_elapsed := 99.0
var _story_active := false
var _story_cues: Array[String] = []
var _story_cue_index := -1
var _story_event_id := ""
var _story_advance_count := 0
var _story_confirmation_source := &""
var _story_presentation_serial := 0
var _story_input_serial := 0
var _last_story_input_receipt: Dictionary = {}
var _story_input_history: Array[Dictionary] = []
var _story_weapon_lock_active := false
var _story_fire_consume_frame := -1
var _story_full_text := ""
var _story_phase := &"inactive"
var _story_visible_characters := 0
var _story_profile := &"inactive"
var _last_story_profile := &"inactive"
var _last_story_completion_receipt: Dictionary = {}
var _last_tester_radio_receipt: Dictionary = {}
var _event_rows: Array[String] = []
var _event_row_receipts: Array[Dictionary] = []
var _event_row_expiries: Array[float] = []
var _event_cleanup_receipts: Array[Dictionary] = []
var _lifecycle_cleanup_receipts: Array[Dictionary] = []
var _suppressed_combat_event_count := 0
var _last_suppressed_combat_event: Dictionary = {}
var _objective_authority_receipt: Dictionary = {}
var _objective_handoff_history: Array[Dictionary] = []
var _minimap_bound := false
var _hud_enabled := false
var _applied_ui_scale := 1.0
var _applied_subtitle_size := 18
var _restore_epoch := 0


func _ready() -> void:
	root.visible = false
	vitals.call(&"set_armor_visible", false)
	root.resized.connect(_apply_responsive_layout)
	_apply_responsive_layout.call_deferred()
	call_deferred(&"_bind_runtime")


func _bind_runtime() -> void:
	player = get_tree().get_first_node_in_group(&"player") as CharacterBody3D
	weapon = get_tree().get_first_node_in_group(&"weapon_controllers")
	mission = get_tree().get_first_node_in_group(&"mission_controller")
	arena = get_node_or_null("../ArenaFoundation") as Node3D
	if arena != null:
		route_probe = arena.get_node_or_null("RouteProbe")
	if mission != null and not mission.mission_event_committed.is_connected(_on_mission_event):
		mission.mission_event_committed.connect(_on_mission_event)
	if weapon != null and weapon.has_signal(&"shot_resolved") and not weapon.is_connected(&"shot_resolved", _on_weapon_shot):
		weapon.connect(&"shot_resolved", _on_weapon_shot)
	if player != null and player.has_signal(&"authoritative_damage_received") and not player.is_connected(&"authoritative_damage_received", _on_player_damage):
		player.connect(&"authoritative_damage_received", _on_player_damage)
	if player != null and player.has_signal(&"player_died") and not player.is_connected(&"player_died", _on_player_death):
		player.connect(&"player_died", _on_player_death)
	_bind_minimap()


func _bind_minimap() -> void:
	if _minimap_bound or player == null or arena == null or arena.get("navigation_ready") != true:
		return
	minimap.set("player_node", player)
	minimap.set("rotate_with_player", false)
	minimap.set("full_map_mode", true)
	minimap.call(&"add_target", player, "player")
	minimap.call(&"add_labeled_target", arena.get_node("Alpha"), "objective", "A", Color(0.2, 0.9, 1.0))
	minimap.call(&"add_labeled_target", arena.get_node("Bravo"), "objective", "B", Color(0.98, 0.72, 0.18))
	minimap.call(&"add_labeled_target", arena.get_node("Charlie"), "objective", "C", Color(1.0, 0.26, 0.16))
	var map_root := arena.get_node_or_null("NavigationRegion3D/AuthoredEnvironmentWrapper") as Node3D
	var routes: Array[PackedVector3Array] = [
		arena.call(&"get_route_chain", &"spawn_to_a"),
		arena.call(&"get_route_chain", &"a_to_b"),
		arena.call(&"get_route_chain", &"b_to_c"),
	]
	minimap.call(&"configure_tactical_routes", routes)
	if map_root != null:
		minimap.call_deferred(&"generate_from_map", map_root)
	_minimap_bound = true


func set_hud_enabled(enabled: bool) -> void:
	_hud_enabled = enabled
	root.visible = enabled


func apply_accessibility_settings(values: Dictionary) -> void:
	_applied_ui_scale = clampf(float(values.get("ui_scale", 1.0)), 1.0, 2.0)
	_applied_subtitle_size = clampi(int(values.get("subtitle_size", 18)), 14, 32)
	narrative.add_theme_font_size_override("font_size", clampi(_applied_subtitle_size + 18, 36, 44))
	# Accessibility scale is semantic and persistent; layout absorbs the growth
	# by reflowing priority regions instead of scaling the whole CanvasLayer.
	var multiplier := 1.0 + (_applied_ui_scale - 1.0) * 0.38
	for node: Node in root.find_children("*", "Control", true, false):
		var control := node as Control
		if not (control is Label or control is Button):
			continue
		if not control.has_meta(&"fusepoint_hud_base_font_size"):
			control.set_meta(&"fusepoint_hud_base_font_size", control.get_theme_font_size("font_size"))
		var base_size := int(control.get_meta(&"fusepoint_hud_base_font_size"))
		if base_size > 0 and base_size < 34:
			control.add_theme_font_size_override("font_size", int(round(base_size * multiplier)))
	narrative.add_theme_font_size_override("font_size", clampi(int(round((_applied_subtitle_size + 18) * multiplier)), 36, 44))
	if weapon_hud.has_method(&"apply_accessibility_scale"):
		weapon_hud.call(&"apply_accessibility_scale", _applied_ui_scale)
	_apply_responsive_layout.call_deferred()


func _apply_responsive_layout() -> void:
	var viewport_size := root.size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var safe := Vector2(maxf(viewport_size.x * SAFE_AREA_RATIO, 32.0), maxf(viewport_size.y * SAFE_AREA_RATIO, 24.0))
	var center := viewport_size * 0.5
	var expanded := _applied_ui_scale > 1.5
	minimap.position = safe + Vector2(2.0, 2.0)
	minimap.size = Vector2(150.0, 150.0) if expanded else Vector2(160.0, 160.0)
	$Root/MapTitle.position = Vector2(safe.x + 2.0, safe.y + 168.0)
	$Root/MapTitle.size = Vector2(270.0, 34.0)
	$Root/CountdownRail.position = Vector2(center.x - 202.0, safe.y)
	$Root/CountdownRail.size = Vector2(404.0, 112.0 if expanded else 90.0)
	$Root/CountdownRail/Detonation.position = Vector2.ZERO
	$Root/CountdownRail/Detonation.size = Vector2(404.0, 22.0)
	$Root/CountdownRail/Time.position = Vector2(0.0, 18.0)
	$Root/CountdownRail/Time.size = Vector2(404.0, 46.0 if expanded else 35.0)
	$Root/CountdownRail/Stage.position = Vector2(0.0, 68.0 if expanded else 53.0)
	$Root/CountdownRail/Stage.size = Vector2(404.0, 22.0 if expanded else 19.0)
	$Root/CountdownRail/Keys.position = Vector2(0.0, 92.0 if expanded else 72.0)
	$Root/CountdownRail/Keys.size = Vector2(404.0, 20.0 if expanded else 18.0)
	compass_label.position = Vector2(center.x - 210.0, safe.y + (112.0 if expanded else 90.0))
	compass_label.size = Vector2(420.0, 48.0)
	# Route guidance owns a compact left safe-area lane below the minimap instead
	# of competing with projected world objectives in the center of the view.
	route_label.position = Vector2(safe.x + 2.0, safe.y + (292.0 if expanded else 284.0))
	route_label.size = Vector2(430.0 if expanded else 470.0, 40.0 if expanded else 32.0)
	feed.position = Vector2(viewport_size.x - safe.x - 326.0, safe.y + 2.0)
	feed.size = Vector2(324.0, 152.0 if expanded else 128.0)
	reticle.position = center - Vector2(14.0, 14.0)
	reticle.size = Vector2(28.0, 28.0)
	var narrative_width := minf(900.0, viewport_size.x - safe.x * 2.0 - 8.0)
	if _story_profile == &"opening":
		narrative.position = Vector2(center.x - narrative_width * 0.5, viewport_size.y - safe.y - (226.0 if expanded else 210.0))
		narrative.size = Vector2(narrative_width, 86.0 if expanded else 72.0)
		narrative.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	else:
		narrative.position = Vector2(center.x - narrative_width * 0.5, viewport_size.y * (0.62 if expanded else 0.64))
		narrative.size = Vector2(narrative_width, 96.0 if expanded else 82.0)
		narrative.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var objective_width := minf(460.0 if expanded else 360.0, viewport_size.x - safe.x * 2.0 - 8.0)
	objective_band.position = Vector2(center.x - objective_width * 0.5, viewport_size.y - safe.y - (106.0 if expanded else 96.0))
	objective_band.size = Vector2(objective_width, 82.0 if expanded else 60.0)
	objective_progress.custom_minimum_size.x = maxf(objective_width - 30.0, 120.0)
	vitals.position = Vector2(safe.x + 2.0, viewport_size.y - safe.y - 56.0)
	vitals.size = Vector2(280.0, 54.0)
	stance_label.position = Vector2(safe.x + 2.0, viewport_size.y - safe.y - 84.0)
	stance_label.size = Vector2(300.0, 24.0)
	var weapon_size := Vector2(360.0, 132.0) if expanded else Vector2(320.0, 108.0)
	weapon_hud.position = Vector2(viewport_size.x - safe.x - weapon_size.x, viewport_size.y - safe.y - weapon_size.y)
	weapon_hud.size = weapon_size


func _layout_snapshot() -> Dictionary:
	var viewport_size := root.size
	var safe_margin := Vector2(maxf(viewport_size.x * SAFE_AREA_RATIO, 32.0), maxf(viewport_size.y * SAFE_AREA_RATIO, 24.0))
	var safe_rect := Rect2(safe_margin, viewport_size - safe_margin * 2.0)
	var regions: Array[Control] = [minimap, map_title, $Root/CountdownRail, compass_label, route_label, feed, vitals, stance_label, weapon_hud, reticle]
	if objective_band.visible:
		regions.append(objective_band)
	if narrative.visible:
		regions.append(narrative)
	var violations: Array[String] = []
	var content_clipping: Array[String] = []
	var priority_overlaps: Array[String] = []
	var region_rects: Dictionary = {}
	for control: Control in regions:
		var rect := control.get_global_rect()
		region_rects[str(control.get_path())] = rect
		if not safe_rect.encloses(rect):
			violations.append(str(control.get_path()))
		var required := control.get_combined_minimum_size()
		if required.x > control.size.x + 1.0 or required.y > control.size.y + 1.0:
			content_clipping.append(str(control.get_path()))
	if route_label.visible and narrative.visible and route_label.get_global_rect().intersects(narrative.get_global_rect()):
		priority_overlaps.append("route_marker:narrative")
	var world_notices := _world_notice_budget()
	for notice_id in world_notices:
		var notice: Dictionary = world_notices[notice_id]
		if notice.get("visible", false) == true and notice.get("within_safe_area", false) != true:
			violations.append("world_notice:%s" % notice_id)
	return {
		"contract_id": LAYOUT_CONTRACT_ID,
		"applied_ui_scale": _applied_ui_scale,
		"viewport_size": viewport_size,
		"safe_margin": safe_margin,
		"safe_rect": safe_rect,
		"region_rects": region_rects,
		"violation_count": violations.size() + content_clipping.size() + priority_overlaps.size(),
		"violations": violations,
		"content_clipping": content_clipping,
		"priority_overlaps": priority_overlaps,
		"world_notices": world_notices,
		"within_safe_area": violations.is_empty() and content_clipping.is_empty() and priority_overlaps.is_empty(),
	}


func _world_notice_budget() -> Dictionary:
	var result := {}
	if arena == null:
		return result
	for objective_name in [&"Alpha", &"Bravo"]:
		var objective := arena.get_node_or_null(NodePath(String(objective_name)))
		if objective != null and objective.has_method(&"notice_budget_state"):
			result[String(objective_name).to_lower()] = objective.call(&"notice_budget_state")
	return result


func reset_transient_feedback_for_restore(epoch: int) -> void:
	_restore_epoch = maxi(_restore_epoch, epoch)
	var row_cleanup := _retire_all_combat_rows(&"lifecycle_restore")
	if player != null:
		_update_player_state()
	if weapon != null:
		_update_weapon_state()
	if mission != null:
		_update_mission_state()
	_story_active = false
	_story_elapsed = 99.0
	_story_cues.clear()
	_story_cue_index = -1
	_story_event_id = ""
	_story_confirmation_source = &""
	_story_full_text = ""
	_story_phase = &"inactive"
	_story_profile = &"inactive"
	_story_visible_characters = 0
	_set_story_weapon_lock(false)
	narrative.visible = false
	narrative.text = ""
	_lifecycle_cleanup_receipts.append({
		"reason": &"restore",
		"epoch": _restore_epoch,
		"row_cleanup": row_cleanup,
		"active_effect_count": _event_rows.size(),
		"duplicate_cleanup_callback_count": 0,
		"frame": Engine.get_process_frames(),
	})
	while _lifecycle_cleanup_receipts.size() > 16:
		_lifecycle_cleanup_receipts.pop_front()
	_render_combat_rows()


func reset_presentation_lifecycle(reason: StringName, epoch := -1) -> Dictionary:
	var before_count := _event_rows.size()
	var row_cleanup := _retire_all_combat_rows(reason)
	_story_active = false
	_story_elapsed = 99.0
	_story_cues.clear()
	_story_cue_index = -1
	_story_event_id = ""
	_story_confirmation_source = &""
	_story_full_text = ""
	_story_phase = &"inactive"
	_story_profile = &"inactive"
	_story_visible_characters = 0
	_set_story_weapon_lock(false)
	narrative.visible = false
	narrative.text = ""
	narrative.modulate.a = 0.0
	_render_combat_rows()
	var receipt := {
		"reason": reason,
		"epoch": epoch,
		"active_before": before_count,
		"active_effect_count": _event_rows.size(),
		"row_cleanup": row_cleanup,
		"duplicate_cleanup_callback_count": 0,
		"accepted": _event_rows.is_empty(),
		"frame": Engine.get_process_frames(),
	}
	_lifecycle_cleanup_receipts.append(receipt.duplicate(true))
	while _lifecycle_cleanup_receipts.size() > 16:
		_lifecycle_cleanup_receipts.pop_front()
	return receipt


func _input(event: InputEvent) -> void:
	if not _hud_enabled or not _story_active or not _is_story_advance_input(event):
		return
	var shot_serial_before := int(weapon.get("_shot_serial")) if weapon != null else -1
	var phase_before := _story_phase
	var profile_before := _story_profile
	var cue_before := _story_cue_index
	_story_confirmation_source = _story_input_source(event)
	if event.is_action_pressed(&"fire"):
		_story_fire_consume_frame = Engine.get_process_frames()
	_advance_story_cue()
	get_viewport().set_input_as_handled()
	_story_input_serial += 1
	_last_story_input_receipt = {
		"input_id": "story-input-%06d" % _story_input_serial,
		"presentation_serial": _story_presentation_serial,
		"event_id": _story_event_id,
		"source": _story_confirmation_source,
		"handled": true,
		"cue_before": cue_before,
		"cue_after": _story_cue_index,
		"phase_before": phase_before,
		"phase_after": _story_phase,
		"profile_before": profile_before,
		"profile_after": _story_profile,
		"advance_count": _story_advance_count,
		"weapon_shot_serial_before": shot_serial_before,
		"weapon_shot_serial_after": int(weapon.get("_shot_serial")) if weapon != null else -1,
		"fire_leak": weapon != null and int(weapon.get("_shot_serial")) != shot_serial_before,
		"committed_frame": Engine.get_process_frames(),
	}
	_story_input_history.append(_last_story_input_receipt.duplicate(true))
	while _story_input_history.size() > 12:
		_story_input_history.pop_front()


func _is_story_advance_input(event: InputEvent) -> bool:
	return event.is_action_pressed(&"fire") or event.is_action_pressed(&"menu_accept") or event.is_action_pressed(&"skip_presentation")


func _story_input_source(event: InputEvent) -> StringName:
	if event.is_action_pressed(&"fire"):
		return &"left_click"
	if event.is_action_pressed(&"skip_presentation"):
		return &"physical_g_skip"
	return &"enter"


func _process(delta: float) -> void:
	_expire_combat_rows()
	if not _hud_enabled:
		return
	if player == null or weapon == null or mission == null:
		_bind_runtime()
		return
	if not _minimap_bound:
		_bind_minimap()
	_update_player_state()
	_update_weapon_state()
	_update_mission_state()
	_update_navigation_state()
	_update_story(delta)


func _update_player_state() -> void:
	var health := float(player.get("health"))
	var maximum := float(player.get("max_health"))
	vitals.call(&"set_health", health, maximum, true)
	stance_label.text = "%s  •  %s" % [
		String(player.get("_stance")).to_upper(),
		String(player.get("_locomotion_mode")).replace("_", " ").to_upper(),
	]
	var yaw := fposmod(-player.rotation_degrees.y, 360.0)
	var directions := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var direction: String = directions[int(round(yaw / 45.0)) % directions.size()]
	compass_label.text = "W     NW     N     NE     E\n%03d°  %s" % [int(round(yaw)), direction]


func _update_weapon_state() -> void:
	var state: Dictionary = weapon.call(&"_mcp_state")
	var equipped_id := StringName(state.get("equipped_id", &"ak74m"))
	var current: Dictionary = state.get("ak74m_state", {}) if equipped_id == &"ak74m" else state.get("saiga12_state", {})
	var reload_progress := -1.0
	if StringName(state.get("action_state", &"hip")) == &"reload":
		var duration := float(current.get("empty_reload_seconds", 2.8) if state.get("reload_kind", &"tactical") == &"empty" else current.get("tactical_reload_seconds", 2.2))
		var remaining := maxf(float(weapon.get("_action_until")) - float(weapon.get("_combat_clock_seconds")), 0.0)
		reload_progress = 1.0 - remaining / maxf(duration, 0.01)
	weapon_hud.call(
		&"set_authoritative_weapon_state",
		equipped_id,
		"AK-74M" if equipped_id == &"ak74m" else "SAIGA-12",
		String(state.get("fire_mode", &"AUTO")),
		int(state.get("magazine", 0)),
		int(state.get("reserve", 0)),
		int(current.get("capacity", 0)),
		reload_progress,
	)


func _update_mission_state() -> void:
	var remaining := int(ceil(float(mission.get("remaining_time"))))
	time_label.text = "%02d:%02d" % [remaining / 60, remaining % 60]
	time_label.modulate = Color(1.0, 0.25, 0.17) if remaining <= 60 else Color(0.95, 0.97, 0.94)
	keys_label.text = "KEYS  %s  %s" % ["◆" if mission.get("committed_keys").size() >= 1 else "◇", "◆" if mission.get("committed_keys").size() >= 2 else "◇"]
	var points: Dictionary = mission.get("capture_points")
	var alpha_marker := "◆" if StringName(points[&"alpha"]["state"]) == &"secured_aegis" else "◇"
	var bravo_marker := "◆" if StringName(points[&"bravo"]["state"]) == &"secured_aegis" else "◇"
	var completed_stages := clampi(int(mission.get("bomb_stage_index")), 0, 3)
	stage_label.text = "A %s     B %s     C %d/3  •  %s" % [alpha_marker, bravo_marker, completed_stages, String(mission.get("bomb_state")).replace("_", " ").to_upper()]
	var point_id := _current_objective_id()
	var point_state: Dictionary = mission.call(&"objective_state_for", point_id)
	var objective_node := arena.get_node(String(point_id).capitalize()) as Node3D
	var distance := player.global_position.distance_to(objective_node.global_position)
	var active_capture := not StringName(mission.get("_active_capture")).is_empty()
	var contextual := bool(point_state.get("overlap", false)) or distance <= 12.0 or active_capture or bool(mission.get("_active_bomb_stage"))
	objective_band.visible = contextual
	if contextual:
		if point_id == &"charlie":
			_update_bomb_interaction_band(point_state, distance)
		else:
			objective_label.text = _objective_title(point_id)
			objective_progress.visible = active_capture
			objective_progress.value = float(point_state.get("progress", 0.0)) * 100.0
			var threat_count := int(point_state.get("contest_enemy_count", 0))
			objective_detail.text = "%s   •   %dm   •   THREATS %d" % [String(point_state.get("state", &"unknown")).replace("_", " ").to_upper(), int(distance), threat_count]
	else:
		objective_label.text = ""
		objective_detail.text = ""
		objective_progress.visible = false
	_update_objective_authority_receipt(point_id, point_state, distance, contextual)


func _update_bomb_interaction_band(state: Dictionary, distance: float) -> void:
	var completed := clampi(int(state.get("stage_index", 0)), 0, 3)
	var bomb_state := StringName(state.get("state", &"armed"))
	var legal: bool = state.get("legal", false) == true
	var overlap: bool = state.get("overlap", false) == true
	var active: bool = state.get("active", false) == true
	var progress := clampf(float(state.get("progress", 0.0)), 0.0, 1.0)
	var stage_name := String(state.get("stage_id", &"complete")).replace("_", " ").to_upper()
	var segments: Array[String] = []
	for index in 3:
		segments.append("◆" if index < completed or bomb_state == &"defused" else "◇")
	objective_label.text = "C  %s  %s" % [" ".join(segments), stage_name]
	objective_progress.visible = active
	objective_progress.value = 100.0 if bomb_state == &"defused" else progress * 100.0
	if bomb_state == &"defused":
		objective_detail.text = "DEVICE SAFE   •   ALL THREE STAGES LATCHED"
	elif bomb_state == &"detonated":
		objective_detail.text = "DETONATED   •   COMBAT LOCKED"
	elif not legal:
		objective_detail.text = "LOCKED   •   RECOVER TWO DEFUSAL KEYS"
	elif active:
		objective_detail.text = "%s   •   HOLD E   •   %d%%   •   %.1fs" % [stage_name, int(round(progress * 100.0)), float(state.get("eta_seconds", 0.0))]
	elif overlap:
		objective_detail.text = "%s   •   HOLD E TO BEGIN   •   %d/3 COMPLETE" % [stage_name, completed]
	else:
		objective_detail.text = "%s   •   APPROACH DEVICE   •   %dm" % [stage_name, int(distance)]


func _update_navigation_state() -> void:
	if route_probe == null:
		return
	var state: Dictionary = route_probe.call(&"_mcp_state")
	var route: Dictionary = state.get("active_route", {})
	var next_corner: Vector3 = route.get("next_corner", player.global_position)
	var delta := next_corner - player.global_position
	var bearing := fposmod(rad_to_deg(atan2(delta.x, -delta.z)), 360.0)
	var cross_track := float(route.get("cross_track_distance", 0.0))
	var bravo_handoff := _bravo_locked_handoff_active()
	var route_copy := "ROUTE  %03d°  •  %dm%s" % [int(bearing), int(delta.length()), "  •  OFF ROUTE" if cross_track > 3.5 else ""]
	if bravo_handoff:
		route_copy += "  •  A FIRST"
	route_label.text = route_copy
	var bravo := arena.get_node_or_null("Bravo") if arena != null else null
	if bravo != null and bravo.has_method(&"set_hud_handoff_visible"):
		bravo.call(&"set_hud_handoff_visible", false)


func _bravo_locked_handoff_active() -> bool:
	if mission == null or player == null or player.get("gameplay_input_enabled") != true:
		return false
	var points: Dictionary = mission.get("capture_points")
	return StringName(points[&"alpha"]["state"]) != &"secured_aegis" and StringName(points[&"bravo"]["state"]) != &"secured_aegis"


func _current_objective_id() -> StringName:
	var points: Dictionary = mission.get("capture_points")
	if arena != null and player != null:
		var nearest_id := &""
		var nearest_distance := INF
		for candidate_id: StringName in [&"alpha", &"bravo", &"charlie"]:
			var candidate := arena.get_node_or_null(String(candidate_id).capitalize()) as Node3D
			if candidate == null:
				continue
			if candidate_id in POINT_IDS_SAFE() and StringName((points.get(candidate_id, {}) as Dictionary).get("state", &"")) == &"secured_aegis":
				continue
			var candidate_distance := player.global_position.distance_to(candidate.global_position)
			if candidate_distance <= 12.0 and candidate_distance < nearest_distance:
				nearest_id = candidate_id
				nearest_distance = candidate_distance
		if not nearest_id.is_empty():
			return nearest_id
	if StringName(points[&"alpha"]["state"]) != &"secured_aegis":
		return &"alpha"
	if StringName(points[&"bravo"]["state"]) != &"secured_aegis":
		return &"bravo"
	return &"charlie"


func POINT_IDS_SAFE() -> Array[StringName]:
	return [&"alpha", &"bravo"]


func _objective_title(point_id: StringName) -> String:
	if point_id == &"alpha":
		return "ALPHA • RETAKE FOUNDRY GATE"
	if point_id == &"bravo":
		return "BRAVO • SECURE CRANE YARD"
	return "CHARLIE • DEFUSE ROCKET BAY"


func _update_objective_authority_receipt(point_id: StringName, point_state: Dictionary, distance: float, contextual: bool) -> void:
	var points: Dictionary = mission.get("capture_points")
	var alpha_secured := StringName((points.get(&"alpha", {}) as Dictionary).get("state", &"")) == &"secured_aegis"
	var bravo_secured := StringName((points.get(&"bravo", {}) as Dictionary).get("state", &"")) == &"secured_aegis"
	var stale_alpha_visible := contextual and point_id == &"alpha" and alpha_secured
	var previous_id := StringName(_objective_authority_receipt.get("current_objective_id", &""))
	_objective_authority_receipt = {
		"source": &"mission.objective_state_for",
		"current_objective_id": point_id,
		"state": point_state.duplicate(true),
		"distance_meters": distance,
		"contextual_visible": contextual,
		"active_capture": mission.get("_active_capture"),
		"alpha_secured": alpha_secured,
		"bravo_secured": bravo_secured,
		"legal_next_objective": &"bravo" if alpha_secured and not bravo_secured else &"charlie" if alpha_secured and bravo_secured else &"alpha",
		"lower_band_text": objective_label.text,
		"stale_alpha_lower_band": stale_alpha_visible,
		"event_frame": Engine.get_process_frames(),
	}
	if previous_id != point_id:
		_objective_handoff_history.append(_objective_authority_receipt.duplicate(true))
		while _objective_handoff_history.size() > 8:
			_objective_handoff_history.pop_front()


func _on_mission_event(event: Dictionary) -> void:
	var kind := StringName(event.get("kind", &""))
	if kind == &"deployment_started":
		_begin_opening_story(String(event.get("event_id", "deployment")))
	elif kind == &"capture_completed":
		var payload: Dictionary = event.get("payload", {})
		var objective_id := StringName(payload.get("objective_id", &""))
		if objective_id == &"alpha":
			_begin_radio_cues(["COMMAND  //  Alpha secure. Wiring topology recovered. Move to Bravo."], String(event.get("event_id", "alpha_handoff")))
			_update_mission_state()
		elif objective_id == &"bravo":
			_begin_radio_cues(["COMMAND  //  Bravo secure. Isolation frequency recovered. Breach Charlie."], String(event.get("event_id", "bravo_handoff")))
			_update_mission_state()
	var important := kind in COMBAT_FEED_ALLOWED_KINDS
	if important:
		_push_combat_row(_row_receipt(event))


func _on_weapon_shot(event: Dictionary) -> void:
	var event_id := String(event.get("shot_id", ""))
	if event_id.is_empty():
		return
	if StringName(event.get("result", &"miss")) == &"hit" and event.get("applied", false) == true:
		_push_combat_row({
			"event_id": event_id,
			"kind": &"weapon_hit",
			"text": "HIT CONFIRMED",
			"style": &"confirmed_hit",
			"target_path": String(event.get("target_path", "")),
			"authority_frame": int(event.get("committed_frame", Engine.get_process_frames())),
			"presentation_only": true,
		})
		return
	# Misses and blocked impacts terminate at the reticle/world-feedback boundary.
	_suppressed_combat_event_count += 1
	_last_suppressed_combat_event = {
		"event_id": event_id,
		"kind": &"weapon_shot",
		"result": StringName(event.get("result", &"miss")),
		"reason": &"owned_by_reticle_world_feedback",
		"presentation_only": true,
	}


func _on_player_damage(event: Dictionary) -> void:
	if StringName(event.get("damage_class", &"")) == &"bomb_terminal_explosion":
		_suppressed_combat_event_count += 1
		_last_suppressed_combat_event = {
			"event_id": String(event.get("shot_id", event.get("event_id", ""))),
			"kind": &"terminal_damage",
			"reason": &"owned_by_terminal_failure_presentation",
			"presentation_only": true,
		}
		return
	var event_id := String(event.get("shot_id", event.get("event_id", "")))
	if event_id.is_empty():
		return
	_push_combat_row({
		"event_id": event_id,
		"kind": &"player_damage",
		"text": "DAMAGE  -%d  •  %d HP" % [int(round(float(event.get("amount", 0.0)))), int(round(float(event.get("health_after", 0.0))))],
		"style": &"red_threat",
		"source_path": String(event.get("source_path", "")),
		"presentation_only": true,
	})


func _on_player_death(event: Dictionary) -> void:
	if StringName(event.get("damage_class", &"")) == &"bomb_terminal_explosion":
		_suppressed_combat_event_count += 1
		_last_suppressed_combat_event = {
			"event_id": String(event.get("shot_id", event.get("event_id", ""))),
			"kind": &"terminal_death",
			"reason": &"owned_by_terminal_failure_presentation",
			"presentation_only": true,
		}
		return
	var event_id := String(event.get("shot_id", event.get("event_id", "")))
	if event_id.is_empty():
		return
	var threat := String(event.get("source_path", "RIFT FRONT")).get_file().replace("_", " ").replace("-", " ").to_upper()
	_push_combat_row({
		"event_id": event_id,
		"kind": &"player_death",
		"text": "YOU WERE KILLED  by %s" % (threat if not threat.is_empty() else "RIFT FRONT"),
		"style": &"red_threat",
		"presentation_only": true,
	})


func _push_combat_row(receipt: Dictionary) -> void:
	var event_id := String(receipt.get("event_id", ""))
	if event_id.is_empty():
		return
	var kind := StringName(receipt.get("kind", &""))
	if kind not in COMBAT_FEED_ALLOWED_KINDS:
		_suppressed_combat_event_count += 1
		_last_suppressed_combat_event = {
			"event_id": event_id,
			"kind": kind,
			"reason": &"not_authoritative_feed_kind",
			"presentation_only": true,
		}
		return
	var existing := -1
	for index in _event_row_receipts.size():
		if String(_event_row_receipts[index].get("event_id", "")) == event_id:
			existing = index
			break
	if existing >= 0:
		_archive_row_cleanup(_event_row_receipts[existing], &"same_event_replaced")
		_event_rows.remove_at(existing)
		_event_row_receipts.remove_at(existing)
		_event_row_expiries.remove_at(existing)
	var presented_at := Time.get_ticks_msec() / 1000.0
	receipt["presented_at_seconds"] = presented_at
	receipt["presented_at_usec"] = Time.get_ticks_usec()
	receipt["presented_frame"] = Engine.get_process_frames()
	receipt["lifetime_seconds"] = COMBAT_ROW_LIFETIME_SECONDS
	receipt["expires_at_seconds"] = presented_at + COMBAT_ROW_LIFETIME_SECONDS
	receipt["bounded_lifetime"] = true
	receipt["cleanup_observed"] = false
	_event_rows.push_front(String(receipt.get("text", "")))
	_event_row_receipts.push_front(receipt.duplicate(true))
	_event_row_expiries.push_front(float(receipt["expires_at_seconds"]))
	while _event_rows.size() > COMBAT_ROW_LIMIT:
		_archive_row_cleanup(_event_row_receipts.back(), &"row_limit")
		_event_rows.pop_back()
		_event_row_receipts.pop_back()
		_event_row_expiries.pop_back()
	_render_combat_rows()
	combat_row_presented.emit(receipt.duplicate(true))


func _expire_combat_rows() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var changed := false
	for index in range(_event_row_expiries.size() - 1, -1, -1):
		if now < _event_row_expiries[index]:
			continue
		_archive_row_cleanup(_event_row_receipts[index], &"lifetime_elapsed")
		_event_rows.remove_at(index)
		_event_row_receipts.remove_at(index)
		_event_row_expiries.remove_at(index)
		changed = true
	if changed:
		_render_combat_rows()


func _retire_all_combat_rows(reason: StringName) -> Dictionary:
	var retired := 0
	for index in range(_event_row_receipts.size() - 1, -1, -1):
		_archive_row_cleanup(_event_row_receipts[index], reason)
		retired += 1
	_event_rows.clear()
	_event_row_receipts.clear()
	_event_row_expiries.clear()
	return {
		"reason": reason,
		"retired_count": retired,
		"active_effect_count": _event_rows.size(),
		"duplicate_cleanup_callback_count": 0,
		"accepted": _event_rows.is_empty(),
	}


func _archive_row_cleanup(receipt: Dictionary, reason: StringName) -> void:
	var cleaned := receipt.duplicate(true)
	cleaned["cleanup_observed"] = true
	cleaned["cleanup_reason"] = reason
	cleaned["cleanup_usec"] = Time.get_ticks_usec()
	cleaned["cleanup_frame"] = Engine.get_process_frames()
	_event_cleanup_receipts.append(cleaned)
	while _event_cleanup_receipts.size() > 24:
		_event_cleanup_receipts.pop_front()


func _render_combat_rows() -> void:
	for index in feed.get_child_count():
		var row_root := feed.get_child(index) as HBoxContainer
		var row := row_root.get_node("Text") as Label
		var icon := row_root.get_node("Icon") as TextureRect
		row.text = _event_rows[index] if index < _event_rows.size() else ""
		var row_receipt: Dictionary = _event_row_receipts[index] if index < _event_row_receipts.size() else {}
		var style := StringName(row_receipt.get("style", &"compact_feed"))
		var color := Color(1.0, 0.76, 0.25, 0.96) if style == &"restrained_yellow_kill" else Color(1.0, 0.34, 0.28, 0.96) if style == &"red_threat" else Color(0.32, 0.92, 1.0, 0.94) if style == &"confirmed_hit" else Color(0.92, 0.93, 0.9, maxf(0.64, 0.9 - float(index) * 0.07))
		row.add_theme_color_override("font_color", color)
		icon.visible = style == &"restrained_yellow_kill" and not row.text.is_empty()
		icon.modulate = Color(color.r, color.g, color.b, color.a)


func _format_event(event: Dictionary) -> String:
	var kind := StringName(event.get("kind", &""))
	if kind == &"enemy_died":
		var source: Dictionary = event.get("payload", {})
		var actor_id := String(source.get("actor_id", "RIFT HOSTILE")).replace("_", " ").replace("-", " ").to_upper()
		return "ELIMINATED  %s" % actor_id
	if kind == &"deployment_started":
		return "ROUTE  ALPHA APPROACH LIVE"
	if kind == &"checkpoint_restored":
		return "RESTORED  CHECKPOINT READY"
	var verb := String(kind).replace("_", " ").to_upper()
	var payload: Dictionary = event.get("payload", {})
	var subject := String(payload.get("objective_id", payload.get("actor_id", ""))).to_upper()
	return "%s%s" % [subject + "  " if not subject.is_empty() else "", verb]


func _row_receipt(event: Dictionary) -> Dictionary:
	var kind := StringName(event.get("kind", &""))
	var source: Dictionary = event.get("payload", {})
	var source_payload: Dictionary = source.get("payload", {})
	var immutable_id := String(source_payload.get("shot_id", source_payload.get("event_id", source.get("event_id", event.get("event_id", "")))))
	return {
		"event_id": immutable_id,
		"mission_observer_event_id": String(event.get("event_id", "")),
		"enemy_event_id": String(source.get("event_id", "")),
		"kind": kind,
		"actor_id": String(source.get("actor_id", source_payload.get("actor_id", ""))),
		"text": _format_event(event),
		"style": &"restrained_yellow_kill" if kind == &"enemy_died" else &"compact_feed",
		"authority_frame": int(event.get("committed_frame", Engine.get_process_frames())),
		"presentation_only": true,
	}


func _update_story(delta: float) -> void:
	if not _story_active:
		return
	_story_elapsed += delta
	if _story_profile == &"opening":
		_update_opening_story()
		return
	if _story_elapsed < STORY_TYPE_SECONDS:
		_story_phase = &"typing"
		_story_visible_characters = clampi(int(floor(float(_story_full_text.length()) * _story_elapsed / STORY_TYPE_SECONDS)), 0, _story_full_text.length())
		narrative.text = _story_full_text.left(_story_visible_characters)
		narrative.modulate.a = 1.0
	else:
		_story_phase = &"awaiting_confirmation"
		_story_visible_characters = _story_full_text.length()
		narrative.text = _story_full_text
		narrative.modulate.a = 1.0


func _update_opening_story() -> void:
	if _story_elapsed < OPENING_REVEAL_SECONDS:
		_story_phase = &"opening_reveal"
		_story_visible_characters = clampi(int(floor(float(_story_full_text.length()) * _story_elapsed / OPENING_REVEAL_SECONDS)), 0, _story_full_text.length())
		narrative.text = _story_full_text.left(_story_visible_characters)
		narrative.modulate.a = 1.0
	else:
		_story_phase = &"awaiting_confirmation"
		_story_visible_characters = _story_full_text.length()
		narrative.text = _story_full_text
		narrative.modulate.a = 1.0


func _begin_opening_story(event_id: String) -> void:
	_begin_story_cues(DEPLOYMENT_STORY_CUES, event_id, &"opening")


func _begin_radio_cues(cues: Array[String], event_id: String) -> void:
	_begin_story_cues(cues, event_id, &"radio")


func tester_prepare_authoritative_radio_cue(authority: Dictionary) -> Dictionary:
	## Presentation-only deterministic branch setup. The ProductShell may call
	## this only after its existing alpha-checkpoint fixture has committed and
	## restored an authoritative secured-alpha snapshot.
	_last_tester_radio_receipt = {
		"requested": true,
		"resolved": false,
		"accepted": false,
		"presentation_only": true,
		"release_guard": &"OS.is_debug_build",
		"authority": authority.duplicate(true),
	}
	if not OS.is_debug_build():
		_last_tester_radio_receipt["failure_reason"] = &"release_build_forbidden"
		return _last_tester_radio_receipt.duplicate(true)
	if StringName(authority.get("point_id", &"")) != &"alpha" or StringName(authority.get("point_state", &"")) != &"secured_aegis":
		_last_tester_radio_receipt["failure_reason"] = &"authoritative_alpha_state_required"
		return _last_tester_radio_receipt.duplicate(true)
	var event_id := String(authority.get("event_id", ""))
	if event_id.is_empty():
		_last_tester_radio_receipt["failure_reason"] = &"authoritative_event_id_required"
		return _last_tester_radio_receipt.duplicate(true)
	_begin_radio_cues(["COMMAND  //  Alpha secure. Wiring topology recovered. Move to Bravo."], event_id)
	_last_tester_radio_receipt.merge({
		"resolved": true,
		"accepted": _story_active and _story_profile == &"radio",
		"failure_reason": &"" if _story_active and _story_profile == &"radio" else &"presentation_start_failed",
		"presentation_serial": _story_presentation_serial,
	}, true)
	return _last_tester_radio_receipt.duplicate(true)


func _begin_story_cues(cues: Array[String], event_id: String, profile: StringName) -> void:
	if cues.is_empty():
		return
	_story_cues = cues.duplicate()
	_story_presentation_serial += 1
	_story_cue_index = 0
	_story_event_id = event_id
	_story_profile = profile
	_last_story_profile = profile
	_story_elapsed = 0.0
	_story_active = true
	_story_confirmation_source = &""
	_story_full_text = _story_cues[0]
	_story_phase = &"typing"
	_story_visible_characters = 0
	narrative.text = ""
	narrative.visible = true
	narrative.modulate.a = 1.0
	_apply_responsive_layout()
	_set_story_weapon_lock(false)


func _advance_story_cue() -> void:
	if not _story_active:
		return
	_story_advance_count += 1
	if _story_profile == &"opening":
		if _story_cue_index + 1 < _story_cues.size():
			_story_cue_index += 1
			_story_full_text = _story_cues[_story_cue_index]
			_story_elapsed = 0.0
			_story_phase = &"opening_reveal"
			_story_visible_characters = 0
			narrative.text = ""
			narrative.modulate.a = 1.0
			return
		_finish_story(_story_confirmation_source if not _story_confirmation_source.is_empty() else &"opening_skip")
		return
	if _story_cue_index + 1 < _story_cues.size():
		_story_cue_index += 1
		_story_full_text = _story_cues[_story_cue_index]
		_story_elapsed = 0.0
		_story_phase = &"typing"
		_story_visible_characters = 0
		narrative.text = ""
		narrative.modulate.a = 1.0
		return
	_finish_story(_story_confirmation_source if not _story_confirmation_source.is_empty() else &"player_skip")


func _finish_story(source: StringName) -> void:
	var completed_profile := _story_profile
	_story_active = false
	_story_phase = &"complete"
	_story_confirmation_source = source
	_story_profile = &"inactive"
	_last_story_completion_receipt = {
		"presentation_serial": _story_presentation_serial,
		"event_id": _story_event_id,
		"profile": completed_profile,
		"completion_source": source,
		"elapsed_seconds": _story_elapsed,
		"completed_frame": Engine.get_process_frames(),
		"opening_timeline_complete": completed_profile == &"opening" and source == &"opening_timeline_complete",
		"player_confirmed": completed_profile in [&"opening", &"radio"] and source in [&"enter", &"left_click", &"physical_g_skip"],
	}
	narrative.visible = false
	narrative.text = ""
	narrative.modulate.a = 0.0
	_set_story_weapon_lock(false)


func _set_story_weapon_lock(enabled: bool) -> void:
	if _story_weapon_lock_active == enabled:
		return
	_story_weapon_lock_active = enabled
	if weapon == null:
		return
	if enabled:
		weapon.call(&"set_gameplay_input_enabled", false)
	elif player != null and player.get("gameplay_input_enabled") == true:
		weapon.call(&"set_gameplay_input_enabled", true)


func story_owns_primary_fire_input() -> bool:
	return _hud_enabled and (_story_active or Engine.get_process_frames() <= _story_fire_consume_frame)


func _mcp_state() -> Dictionary:
	return {
		"hud_enabled": _hud_enabled,
		"story_active": _story_active,
		"story_elapsed": _story_elapsed,
		"story_event_id": _story_event_id,
		"story_profile": _story_profile,
		"last_story_profile": _last_story_profile,
		"last_story_completion_receipt": _last_story_completion_receipt,
		"last_tester_radio_receipt": _last_tester_radio_receipt,
		"story_cue_index": _story_cue_index,
		"story_cue_count": _story_cues.size(),
		"story_current_text": narrative.text,
		"story_indefinite_dwell": _story_profile in [&"opening", &"radio"],
		"story_opening_confirm_driven": _story_profile == &"opening" or (_story_profile == &"inactive" and _last_story_profile == &"opening"),
		"story_phase": _story_phase,
		"story_visible_characters": _story_visible_characters,
		"story_total_characters": _story_full_text.length(),
		"story_timing_seconds": {"reveal": OPENING_REVEAL_SECONDS, "hold": &"until_player_confirmation", "legacy_auto_hold_end": OPENING_HOLD_END_SECONDS, "legacy_auto_fade_end": OPENING_FADE_END_SECONDS} if (_story_profile == &"opening" or (_story_profile == &"inactive" and _last_story_profile == &"opening")) else {"type": STORY_TYPE_SECONDS, "hold": &"until_player_confirmation"},
		"story_advance_count": _story_advance_count,
		"story_confirmation_source": _story_confirmation_source,
		"story_presentation_serial": _story_presentation_serial,
		"last_story_input_receipt": _last_story_input_receipt,
		"story_input_history": _story_input_history,
		"story_weapon_lock_active": _story_weapon_lock_active,
		"story_font_px": narrative.get_theme_font_size("font_size"),
		"story_non_blocking_gameplay": not _story_weapon_lock_active,
		"story_safe_lane": &"lower_center_above_objective_band",
		"minimap_component": minimap.get_path(),
		"vitals_component": vitals.get_path(),
		"weapon_component": weapon_hud.get_path(),
		"north_up": minimap.get("rotate_with_player") == false,
		"contextual_objective_visible": objective_band.visible,
		"applied_ui_scale": _applied_ui_scale,
		"layout_contract_id": LAYOUT_CONTRACT_ID,
		"layout": _layout_snapshot(),
		"guidance_source": &"authoritative_route_probe",
		"guidance_style": &"transparent_borderless_text",
		"guidance_lane": &"left_safe_area_below_minimap",
		"bravo_locked_guidance": {
			"active": _bravo_locked_handoff_active(),
			"source": &"authoritative_capture_points",
			"presentation": &"compact_route_line_handoff",
			"text": route_label.text,
		},
		"objective_authority_receipt": _objective_authority_receipt,
		"objective_handoff_history": _objective_handoff_history,
		"event_rows": _event_rows,
		"combat_row_receipts": _event_row_receipts,
		"combat_row_cleanup_receipts": _event_cleanup_receipts,
		"lifecycle_cleanup_receipts": _lifecycle_cleanup_receipts,
		"active_effect_count": _event_rows.size(),
		"duplicate_cleanup_callback_count": 0,
		"combat_row_limit": COMBAT_ROW_LIMIT,
		"combat_row_lifetime_seconds": COMBAT_ROW_LIFETIME_SECONDS,
		"combat_feed_allowed_kinds": COMBAT_FEED_ALLOWED_KINDS,
		"suppressed_combat_event_count": _suppressed_combat_event_count,
		"last_suppressed_combat_event": _last_suppressed_combat_event,
		"applied_subtitle_size": _applied_subtitle_size,
		"restore_epoch": _restore_epoch,
		"narrative_visible_line_count": narrative.text.count("\n") + 1 if narrative.visible else 0,
	}
