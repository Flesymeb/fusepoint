class_name FusepointTacticalHUD
extends CanvasLayer

const STORY_COPY := "11:40 — KESTREL RIDGE MILITARY BASE\nThe Rift Front planted a timed bomb in the Sector C rocket maintenance bay.\nCommunications are down. Support is not coming. You are the only operator who can enter.\nRetake Alpha, secure Bravo, then recover both defusal keys.\nIn five minutes, the base disappears with the bomb."

@onready var root: Control = $Root
@onready var minimap: Control = $Root/Minimap
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

var player: CharacterBody3D
var weapon: Node
var mission: Node
var route_probe: Node
var arena: Node3D
var _story_elapsed := 99.0
var _story_active := false
var _event_rows: Array[String] = []
var _minimap_bound := false
var _hud_enabled := false
var _applied_ui_scale := 1.0
var _applied_subtitle_size := 18
var _restore_epoch := 0


func _ready() -> void:
	root.visible = false
	vitals.call(&"set_armor_visible", false)
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
	narrative.add_theme_font_size_override("font_size", _applied_subtitle_size)
	var multiplier := 1.0 + (_applied_ui_scale - 1.0) * 0.16
	for node: Node in root.find_children("*", "Control", true, false):
		var control := node as Control
		if not (control is Label or control is Button):
			continue
		if not control.has_meta(&"fusepoint_hud_base_font_size"):
			control.set_meta(&"fusepoint_hud_base_font_size", control.get_theme_font_size("font_size"))
		var base_size := int(control.get_meta(&"fusepoint_hud_base_font_size"))
		if base_size > 0 and base_size < 32:
			control.add_theme_font_size_override("font_size", int(round(base_size * multiplier)))


func reset_transient_feedback_for_restore(epoch: int) -> void:
	_restore_epoch = maxi(_restore_epoch, epoch)
	_story_active = false
	_story_elapsed = 99.0
	narrative.visible = false
	narrative.text = ""
	_event_rows.clear()
	for child: Node in feed.get_children():
		if child is Label:
			(child as Label).text = ""


func _unhandled_input(event: InputEvent) -> void:
	if _hud_enabled and event.is_action_pressed(&"skip_presentation") and _story_active:
		_story_active = false
		narrative.visible = false
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
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
	weapon_hud.call(&"set_weapon", String(state.get("equipped_id", &"ak74m")).replace("ak74m", "AK-74M").replace("saiga12", "SAIGA-12"), String(state.get("fire_mode", &"AUTO")))
	var current: Dictionary = state.get("ak74m_state", {}) if state.get("equipped_id", &"ak74m") == &"ak74m" else state.get("saiga12_state", {})
	weapon_hud.call(&"set_ammo", int(state.get("magazine", 0)), int(state.get("reserve", 0)), int(current.get("capacity", 0)))
	if StringName(state.get("action_state", &"hip")) == &"reload":
		var duration := float(current.get("empty_reload_seconds", 2.8) if state.get("reload_kind", &"tactical") == &"empty" else current.get("tactical_reload_seconds", 2.2))
		var remaining := maxf(float(weapon.get("_action_until")) - Time.get_ticks_msec() / 1000.0, 0.0)
		weapon_hud.call(&"set_reload_progress", 1.0 - remaining / maxf(duration, 0.01))
	else:
		weapon_hud.call(&"set_reload_progress", -1.0)


func _update_mission_state() -> void:
	var remaining := int(ceil(float(mission.get("remaining_time"))))
	time_label.text = "%02d:%02d" % [remaining / 60, remaining % 60]
	time_label.modulate = Color(1.0, 0.25, 0.17) if remaining <= 60 else Color(0.95, 0.97, 0.94)
	keys_label.text = "KEYS  %s  %s" % ["◆" if mission.get("committed_keys").size() >= 1 else "◇", "◆" if mission.get("committed_keys").size() >= 2 else "◇"]
	var points: Dictionary = mission.get("capture_points")
	var alpha_marker := "◆" if StringName(points[&"alpha"]["state"]) == &"secured_aegis" else "◇"
	var bravo_marker := "◆" if StringName(points[&"bravo"]["state"]) == &"secured_aegis" else "◇"
	stage_label.text = "A %s CAPTURE      B %s CAPTURE      C [BOMB] • %s" % [alpha_marker, bravo_marker, String(mission.get("bomb_state")).replace("_", " ").to_upper()]
	var point_id := _current_objective_id()
	var point_state: Dictionary = mission.call(&"objective_state_for", point_id)
	var objective_node := arena.get_node(String(point_id).capitalize()) as Node3D
	var distance := player.global_position.distance_to(objective_node.global_position)
	var active_capture := not StringName(mission.get("_active_capture")).is_empty()
	var contextual := bool(point_state.get("overlap", false)) or distance <= 12.0 or active_capture or bool(mission.get("_active_bomb_stage"))
	objective_band.visible = contextual
	if contextual:
		objective_label.text = _objective_title(point_id)
		objective_progress.value = float(point_state.get("progress", 0.0)) * 100.0
		var threat_count := int(point_state.get("contest_enemy_count", 0))
		objective_detail.text = "%s   •   %dm   •   THREATS %d" % [String(point_state.get("state", &"unknown")).replace("_", " ").to_upper(), int(distance), threat_count]


func _update_navigation_state() -> void:
	if route_probe == null:
		return
	var state: Dictionary = route_probe.call(&"_mcp_state")
	var route: Dictionary = state.get("active_route", {})
	var next_corner: Vector3 = route.get("next_corner", player.global_position)
	var delta := next_corner - player.global_position
	var bearing := fposmod(rad_to_deg(atan2(delta.x, -delta.z)), 360.0)
	var cross_track := float(route.get("cross_track_distance", 0.0))
	route_label.text = "NEXT ROUTE  %03d°  •  %dm%s" % [int(bearing), int(delta.length()), "  OFF ROUTE" if cross_track > 3.5 else ""]


func _current_objective_id() -> StringName:
	var points: Dictionary = mission.get("capture_points")
	if StringName(points[&"alpha"]["state"]) != &"secured_aegis":
		return &"alpha"
	if StringName(points[&"bravo"]["state"]) != &"secured_aegis":
		return &"bravo"
	return &"charlie"


func _objective_title(point_id: StringName) -> String:
	if point_id == &"alpha":
		return "ALPHA • RETAKE FOUNDRY GATE"
	if point_id == &"bravo":
		return "BRAVO • SECURE CRANE YARD"
	return "CHARLIE • DEFUSE ROCKET BAY"


func _on_mission_event(event: Dictionary) -> void:
	var kind := StringName(event.get("kind", &""))
	if kind == &"deployment_started":
		_story_elapsed = 0.0
		_story_active = true
		narrative.visible = true
	var important := kind in [&"capture_started", &"capture_contested", &"capture_completed", &"key_committed", &"route_unlocked", &"checkpoint_committed", &"enemy_death", &"terminal_submitted"]
	if important:
		_event_rows.push_front(_format_event(event))
		while _event_rows.size() > 5:
			_event_rows.pop_back()
		for index in feed.get_child_count():
			var row := feed.get_child(index) as Label
			row.text = _event_rows[index] if index < _event_rows.size() else ""


func _format_event(event: Dictionary) -> String:
	var kind := String(event.get("kind", "event")).replace("_", " ").to_upper()
	var payload: Dictionary = event.get("payload", {})
	var subject := String(payload.get("objective_id", payload.get("actor_id", ""))).to_upper()
	return "◆  %s%s" % [subject + "  " if not subject.is_empty() else "", kind]


func _update_story(delta: float) -> void:
	if not _story_active:
		return
	_story_elapsed += delta
	if _story_elapsed <= 6.0:
		var count := int(floor(STORY_COPY.length() * _story_elapsed / 6.0))
		narrative.text = STORY_COPY.left(count)
		narrative.modulate.a = 1.0
	elif _story_elapsed <= 10.0:
		narrative.text = STORY_COPY
		narrative.modulate.a = 1.0
	elif _story_elapsed <= 13.0:
		narrative.text = STORY_COPY
		narrative.modulate.a = 1.0 - (_story_elapsed - 10.0) / 3.0
	else:
		_story_active = false
		narrative.visible = false


func _mcp_state() -> Dictionary:
	return {
		"hud_enabled": _hud_enabled,
		"minimap_component": minimap.get_path(),
		"vitals_component": vitals.get_path(),
		"weapon_component": weapon_hud.get_path(),
		"north_up": minimap.get("rotate_with_player") == false,
		"contextual_objective_visible": objective_band.visible,
		"story_active": _story_active,
		"story_elapsed": _story_elapsed,
		"event_rows": _event_rows,
		"applied_ui_scale": _applied_ui_scale,
		"applied_subtitle_size": _applied_subtitle_size,
		"restore_epoch": _restore_epoch,
	}
