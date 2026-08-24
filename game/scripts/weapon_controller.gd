class_name FusepointWeaponController
extends Node

signal shot_resolved(receipt: Dictionary)
signal weapon_state_changed(state: Dictionary)

const WEAPON_ORDER: Array[StringName] = [&"ak74m", &"saiga12"]
const FIRE_MODE_SEMI := &"SEMI"
const FIRE_MODE_AUTO := &"AUTO"
const READY_STATES: Array[StringName] = [&"hip", &"ads", &"fire", &"recoil"]
const AUTO_FIRST_CONTINUATION_RELEASE_GRACE_SECONDS := 0.018

@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("Node3D") var viewmodel_path: NodePath
@export var hud_weapon_path: NodePath
@export var hud_ammo_path: NodePath
@export var hud_mode_path: NodePath
@export var hud_action_path: NodePath
@export var hud_result_path: NodePath
@export var hud_reticle_path: NodePath
@export_flags_3d_physics var ballistics_mask := 1
@export_range(10.0, 500.0, 1.0) var max_range := 180.0
@export_group("Product recoil adapter")
@export_range(0.0, 0.08, 0.001) var recoil_back_distance := 0.015
@export_range(0.0, 8.0, 0.1) var recoil_pitch_degrees := 2.1
@export_range(0.0, 4.0, 0.1) var recoil_yaw_degrees := 0.5
@export_range(0.0, 4.0, 0.1) var recoil_roll_degrees := 0.35
@export_range(0.02, 0.2, 0.01) var recoil_out_seconds := 0.05
@export_range(0.02, 0.2, 0.01) var recoil_return_seconds := 0.09
@export_range(0.0, 0.15, 0.005) var recoil_hold_seconds := 0.02

@onready var camera: Camera3D = get_node(camera_path) as Camera3D
@onready var viewmodel: Node3D = get_node(viewmodel_path) as Node3D
@onready var feedback: Node = viewmodel.get_node("FPSViewmodelFeedback")
@onready var shot_feedback: FPSShotFeedback3D = $ShotFeedback
@onready var hud_weapon: Label = get_node_or_null(hud_weapon_path) as Label
@onready var hud_ammo: Label = get_node_or_null(hud_ammo_path) as Label
@onready var hud_mode: Label = get_node_or_null(hud_mode_path) as Label
@onready var hud_action: Label = get_node_or_null(hud_action_path) as Label
@onready var hud_result: Label = get_node_or_null(hud_result_path) as Label
@onready var hud_reticle: Control = get_node_or_null(hud_reticle_path) as Control

var _weapons: Dictionary = {}
var _equipped_id := &"ak74m"
var _pending_equipped_id := &""
var _action_state := &"hip"
var _reload_kind := &"none"
var _trigger_held := false
var _ads_held := false
var _next_shot_time := 0.0
var _action_until := 0.0
var _recovery_until := 0.0
var _shot_serial := 0
var _shot_commits: Dictionary = {}
var _shot_history: Array[Dictionary] = []
var _last_shot: Dictionary = {}
var _impact_commits: Dictionary = {}
var _impact_history: Array[Dictionary] = []
var _last_result_until := 0.0
var _inspect_tween: Tween
var _ready_for_combat := false
var gameplay_input_enabled := true
var _observed_fire_down := false
var _fire_rearm_required := false
var _fire_edge_queue: Array[Dictionary] = []
var _active_fire_source := &"none"
var _active_fire_press_edge_id := ""
var _active_fire_press_time_usec := 0
var _active_fire_press_started_combat_seconds := 0.0
var _active_fire_press_shot_count := 0
var _active_fire_continuation_authorized := false
var _auto_continuation_confirmation_pending := false
var _input_edge_serial := 0
var _last_input_receipt: Dictionary = {}
var _input_history: Array[Dictionary] = []
var _combat_clock_seconds := 0.0
var _last_input_pump_delta_seconds := 0.0
var _restore_epoch := 0
var _transient_reset_complete := false
var _last_restore_receipt: Dictionary = {}
var _observed_ads_down := false
var _ads_rearm_required := false
var _ads_edge_serial := 0
var _last_ads_receipt: Dictionary = {}
var _ads_history: Array[Dictionary] = []
var _viewmodel_ads_settled := false
var _ads_transition_complete := true
var _ads_transition_serial := 0
var _product_recoil_tween: Tween
var _product_recoil_mount: Node3D
var _product_recoil_baseline_position := Vector3.ZERO
var _product_recoil_baseline_rotation_degrees := Vector3.ZERO
var _product_recoil_phase := &"settled"
var _product_recoil_shot_serial := 0
var _product_recoil_peak_serial := 0
var _product_recoil_recovery_complete := true
var _run_epoch := 0
var _last_run_epoch_receipt: Dictionary = {}
var _report_serial := 0
var _last_report_receipt: Dictionary = {}
var _report_history: Array[Dictionary] = []
var _last_report_stop_reason := &"initial_state"
var _single_report_generation := 0
var _single_report_deadline := -1.0
var _single_report_shot_id := ""
var _single_report_source_path := ""
var _bounded_single_report_duration := 0.0
var _tester_audio_generation := 0
var _last_tester_audio_receipt: Dictionary = {}
var _tester_audio_history: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_weapons = _fresh_weapon_data()
	viewmodel.set("handle_right_mouse", false)
	viewmodel.set("handle_mouse_wheel", false)
	_configure_component_feedback_boundary()
	_capture_retained_component_report_identity()
	if viewmodel.has_signal(&"weapon_changed"):
		viewmodel.connect(&"weapon_changed", _on_viewmodel_weapon_changed)
	if viewmodel.has_signal(&"aiming_changed"):
		viewmodel.connect(&"aiming_changed", _on_viewmodel_aiming_changed)
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.has_signal(&"spawn_reset"):
		player.connect(&"spawn_reset", _on_spawn_reset)
	call_deferred(&"_finish_ready")


func _finish_ready() -> void:
	await get_tree().process_frame
	_capture_product_recoil_baseline(true)
	_ready_for_combat = true
	_sync_hud()
	weapon_state_changed.emit(_mcp_state())


func _input(event: InputEvent) -> void:
	# This normalized raw-event stream is the sole fire-edge authority. Both
	# edges can arrive between physics ticks; preserving them in order prevents
	# InputMap frame flags from stretching a short press into an AUTO interval.
	if event.is_action(&"fire"):
		var fire_pressed := event.is_action_pressed(&"fire")
		var fire_released := event.is_action_released(&"fire")
		if fire_pressed or fire_released:
			_observe_fire_transition(fire_pressed, _input_source_for(event), Time.get_ticks_usec())
		return
	if event.is_action(&"ads"):
		var ads_pressed := event.is_action_pressed(&"ads")
		var ads_released := event.is_action_released(&"ads")
		if ads_pressed or ads_released:
			_observe_ads_transition(ads_pressed, _ads_input_source_for(event))
		return
	if not _ready_for_combat or not gameplay_input_enabled:
		return
	if event.is_action_pressed(&"reload"):
		_begin_reload()
	elif event.is_action_pressed(&"switch_weapon"):
		_switch_weapon(1)
	elif event.is_action_pressed(&"weapon_slot_1"):
		_equip_weapon(&"ak74m")
	elif event.is_action_pressed(&"weapon_slot_2"):
		_equip_weapon(&"saiga12")
	elif event.is_action_pressed(&"switch_fire_mode"):
		_toggle_fire_mode()
	elif event.is_action_pressed(&"inspect_weapon"):
		_begin_inspect()


func _observe_ads_transition(pressed: bool, source: StringName) -> void:
	if pressed == _observed_ads_down:
		return
	_observed_ads_down = pressed
	if not pressed and _ads_rearm_required:
		_ads_rearm_required = false
		_record_ads_edge(source, &"release", false, &"rearmed_after_boundary")
		return
	if not _ready_for_combat or not gameplay_input_enabled or _ads_rearm_required:
		if pressed:
			_ads_rearm_required = true
		_record_ads_edge(source, &"press" if pressed else &"release", false, &"gameplay_disabled")
		return
	_set_ads(pressed)
	_record_ads_edge(source, &"press" if pressed else &"release", true, &"accepted")


func _record_ads_edge(source: StringName, edge: StringName, accepted: bool, reason: StringName) -> void:
	_ads_edge_serial += 1
	_last_ads_receipt = {
		"edge_id": "ads-input-%06d" % _ads_edge_serial,
		"source": source,
		"edge": edge,
		"accepted": accepted,
		"reason": reason,
		"requested_aim": _ads_held,
		"viewmodel_aim_flag": viewmodel.get("aiming") == true,
		"transition_complete": _ads_transition_complete,
		"action_state": _action_state,
		"gameplay_enabled": gameplay_input_enabled,
		"timestamp_seconds": _now(),
	}
	_ads_history.append(_last_ads_receipt.duplicate(true))
	while _ads_history.size() > 24:
		_ads_history.pop_front()


func _process(delta: float) -> void:
	if not _ready_for_combat:
		return
	_last_input_pump_delta_seconds = maxf(delta, 0.0)
	_poll_fire_action_level()
	_drain_fire_edges()
	if not gameplay_input_enabled:
		_sync_hud()
		return
	var now := _now()
	_authorize_auto_continuation_after_input_pump(now)
	_schedule_auto_continuation()
	if _action_state == &"reload" and now >= _action_until:
		_commit_reload()
	elif _action_state == &"inspect" and now >= _action_until:
		_finish_inspect()
	elif _action_state == &"fire" and now >= _action_until:
		_action_state = &"recoil"
	elif _action_state == &"recoil" and now >= _recovery_until:
		_action_state = &"ads" if _ads_held else &"hip"
	elif _action_state == &"dry_fire" and now >= _action_until:
		_action_state = &"ads" if _ads_held else &"hip"
	if hud_result != null and now >= _last_result_until and not hud_result.text.is_empty():
		hud_result.text = ""
	_enforce_product_recoil_baseline_if_settled()
	_sync_hud()


func _physics_process(delta: float) -> void:
	if not _ready_for_combat:
		return
	if gameplay_input_enabled:
		_combat_clock_seconds += maxf(delta, 0.0)
	_poll_fire_action_level()
	_drain_fire_edges()
	if gameplay_input_enabled:
		var now := _now()
		_authorize_auto_continuation_after_input_pump(now)
		_schedule_auto_continuation()


func _poll_fire_action_level() -> void:
	var pressed := Input.is_action_pressed(&"fire")
	if pressed == _observed_fire_down:
		return
	_observe_fire_transition(pressed, &"inputmap_level", Time.get_ticks_usec())


func _authorize_auto_continuation_after_input_pump(now: float) -> void:
	if _active_fire_continuation_authorized or _auto_continuation_confirmation_pending:
		return
	if not _trigger_held or not _observed_fire_down or _active_fire_press_edge_id.is_empty():
		return
	if not Input.is_action_pressed(&"fire"):
		return
	if _current_weapon()["fire_mode"] != FIRE_MODE_AUTO or now < _next_shot_time:
		return
	if _active_fire_press_shot_count == 1 and now < _next_shot_time + AUTO_FIRST_CONTINUATION_RELEASE_GRACE_SECONDS:
		return
	_auto_continuation_confirmation_pending = true
	call_deferred(&"_confirm_auto_continuation", _active_fire_press_edge_id)


func _confirm_auto_continuation(press_edge_id: String) -> void:
	_auto_continuation_confirmation_pending = false
	if press_edge_id.is_empty() or press_edge_id != _active_fire_press_edge_id:
		return
	if not _trigger_held or not _observed_fire_down or not gameplay_input_enabled:
		return
	if not Input.is_action_pressed(&"fire"):
		return
	if _current_weapon()["fire_mode"] != FIRE_MODE_AUTO or _now() < _next_shot_time:
		return
	if _active_fire_press_shot_count == 1 and _now() < _next_shot_time + AUTO_FIRST_CONTINUATION_RELEASE_GRACE_SECONDS:
		return
	_active_fire_continuation_authorized = true
	_schedule_auto_continuation()


func _schedule_auto_continuation() -> void:
	# The raw event observer flips _observed_fire_down before either process loop
	# can drain its queued release. That level is only a veto: the active press
	# generation remains the sole authority that can schedule cadence commits.
	if not _active_fire_continuation_authorized or not _trigger_held or not _observed_fire_down or _active_fire_press_edge_id.is_empty():
		return
	if not Input.is_action_pressed(&"fire"):
		return
	if _current_weapon()["fire_mode"] != FIRE_MODE_AUTO or _now() < _next_shot_time:
		return
	_active_fire_continuation_authorized = true
	if _try_submit_shot().is_empty():
		return
	_next_shot_time = _now() + _fire_interval()


func _observe_fire_transition(pressed: bool, source: StringName, captured_at_usec := 0) -> void:
	if pressed == _observed_fire_down:
		return
	_observed_fire_down = pressed
	if pressed and _story_consumer_owns_primary_input():
		_fire_rearm_required = true
		var magazine := int(_current_weapon()["magazine"])
		_record_input_edge(source, &"press", false, "story_input_owned", "", magazine, magazine, "presentation_consumer", "")
		return
	if not pressed and _fire_rearm_required:
		_fire_rearm_required = false
		return
	if not _ready_for_combat or not gameplay_input_enabled or _fire_rearm_required:
		if pressed:
			_fire_rearm_required = true
		return
	_input_edge_serial += 1
	_fire_edge_queue.append({
		"edge_id": "fire-input-%06d" % _input_edge_serial,
		"pressed": pressed,
		"source": source,
		"captured_at_seconds": _now(),
		"captured_at_usec": captured_at_usec if captured_at_usec > 0 else Time.get_ticks_usec(),
	})


func _story_consumer_owns_primary_input() -> bool:
	var tactical_hud := get_tree().get_first_node_in_group(&"tactical_hud")
	return tactical_hud != null and tactical_hud.get("_hud_enabled") == true and tactical_hud.get("_story_active") == true


func _drain_fire_edges() -> void:
	while not _fire_edge_queue.is_empty():
		var edge: Dictionary = _fire_edge_queue.pop_front()
		var edge_id := String(edge.get("edge_id", ""))
		var source := StringName(edge.get("source", &"mapped_action"))
		if not gameplay_input_enabled:
			var magazine := int(_current_weapon()["magazine"])
			_record_input_edge(source, &"press" if edge.get("pressed", false) else &"release", false, "gameplay_disabled", "", magazine, magazine, "eligibility_changed", edge_id)
			continue
		if edge.get("pressed", false) == true:
			_begin_fire(source, edge_id, int(edge.get("captured_at_usec", 0)))
		else:
			_end_fire(source, "release", edge_id)


func _consume_fire_edge(pressed: bool, source: StringName) -> void:
	# Retained as a deterministic diagnostic seam; it feeds the same queue and
	# cannot bypass the authoritative edge consumer.
	_observe_fire_transition(pressed, source)


func _begin_fire(source := &"mapped_action", edge_id := "", captured_at_usec := 0) -> void:
	var magazine_before := int(_current_weapon()["magazine"])
	if not _can_fire():
		_record_input_edge(source, &"press", false, _fire_rejection_reason(), "", magazine_before, magazine_before, "", edge_id)
		return
	_trigger_held = true
	_active_fire_source = source
	_active_fire_press_edge_id = edge_id
	_active_fire_press_time_usec = captured_at_usec
	_active_fire_press_started_combat_seconds = _now()
	_active_fire_press_shot_count = 0
	_active_fire_continuation_authorized = false
	_auto_continuation_confirmation_pending = false
	var receipt := _try_submit_shot()
	_next_shot_time = _now() + _fire_interval()
	if _current_weapon()["fire_mode"] == FIRE_MODE_SEMI:
		_trigger_held = false
	var magazine_after := int(_current_weapon()["magazine"])
	_record_input_edge(
		source,
		&"press",
		not receipt.is_empty(),
		"accepted" if not receipt.is_empty() else "dry_fire",
		String(receipt.get("shot_id", "")),
		magazine_before,
		magazine_after,
		"",
		edge_id,
	)


func _end_fire(source := &"mapped_action", cancellation_reason := "release", edge_id := "") -> void:
	var was_held := _trigger_held
	_stop_fire_report(StringName(cancellation_reason), false)
	_trigger_held = false
	_active_fire_press_edge_id = ""
	_active_fire_press_time_usec = 0
	_active_fire_press_started_combat_seconds = 0.0
	_active_fire_press_shot_count = 0
	_active_fire_continuation_authorized = false
	_auto_continuation_confirmation_pending = false
	if cancellation_reason == "release":
		var magazine := int(_current_weapon()["magazine"])
		_record_input_edge(source, &"release", was_held or not _observed_fire_down, "released", "", magazine, magazine, "", edge_id)
	_active_fire_source = &"none"


func _can_fire() -> bool:
	return _pending_equipped_id.is_empty() and _action_state in READY_STATES


func _try_submit_shot() -> Dictionary:
	if not _can_fire():
		return {}
	var weapon := _current_weapon()
	if int(weapon["magazine"]) <= 0:
		_present_dry_fire()
		return {}
	_shot_serial += 1
	var shot_id := "run-%06d:player:%s:%06d" % [_run_epoch, String(_equipped_id), _shot_serial]
	if _shot_commits.has(shot_id):
		return {}
	_shot_commits[shot_id] = true
	_active_fire_press_shot_count += 1
	weapon["magazine"] = int(weapon["magazine"]) - 1
	_weapons[_equipped_id] = weapon
	var receipt := _resolve_ballistics(shot_id, weapon)
	var sustained_authorized: bool = (
		weapon["fire_mode"] == FIRE_MODE_AUTO
		and _trigger_held
		and not _active_fire_press_edge_id.is_empty()
		and _active_fire_press_shot_count >= 2
	)
	var playback_class: StringName = &"single_transient"
	if sustained_authorized:
		playback_class = &"single_transient_plus_sustained" if _active_fire_press_shot_count == 2 else &"cadence_transient_plus_sustained"
	receipt["press_edge_id"] = _active_fire_press_edge_id
	receipt["press_shot_ordinal"] = _active_fire_press_shot_count
	receipt["requested_playback_class"] = playback_class
	receipt["sustained_report_authorized"] = sustained_authorized
	_dispatch_impact_receipt(receipt)
	shot_feedback.show_shot(receipt)
	_last_shot = receipt
	_shot_history.append(receipt.duplicate(true))
	if _shot_history.size() > 24:
		_shot_history.pop_front()
	_action_state = &"fire"
	_action_until = _now() + 0.07
	_recovery_until = _now() + float(weapon["recovery_seconds"])
	feedback.call(&"trigger_fire", sustained_authorized)
	_record_report_request(receipt, playback_class, sustained_authorized)
	_trigger_product_recoil(weapon["fire_mode"] == FIRE_MODE_AUTO)
	_present_shot_result(receipt)
	shot_resolved.emit(receipt.duplicate(true))
	weapon_state_changed.emit(_mcp_state())
	return receipt


func _resolve_ballistics(shot_id: String, weapon: Dictionary) -> Dictionary:
	var camera_origin := camera.global_position
	var camera_direction := -camera.global_transform.basis.z.normalized()
	var query := PhysicsRayQueryParameters3D.create(
		camera_origin,
		camera_origin + camera_direction * max_range,
		ballistics_mask,
		_excluded_rids()
	)
	query.collide_with_areas = true
	var camera_hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	var aim_point := camera_origin + camera_direction * max_range
	if not camera_hit.is_empty():
		aim_point = camera_hit["position"]
	var muzzle_origin := _muzzle_origin()
	var muzzle_direction := muzzle_origin.direction_to(aim_point)
	if muzzle_direction.is_zero_approx():
		muzzle_direction = camera_direction
	var muzzle_query := PhysicsRayQueryParameters3D.create(
		muzzle_origin,
		muzzle_origin + muzzle_direction * max_range,
		ballistics_mask,
		_excluded_rids()
	)
	muzzle_query.collide_with_areas = true
	var muzzle_hit := camera.get_world_3d().direct_space_state.intersect_ray(muzzle_query)
	var result := &"miss"
	var collider_path := ""
	var hit_position := muzzle_origin + muzzle_direction * max_range
	var hit_normal := Vector3.ZERO
	var damage_committed := false
	if not muzzle_hit.is_empty():
		var collider := muzzle_hit.get("collider") as Node
		hit_position = muzzle_hit["position"]
		hit_normal = muzzle_hit["normal"]
		collider_path = String(collider.get_path()) if collider != null else ""
		if collider != null and collider.has_method(&"apply_weapon_damage"):
			result = &"hit"
			damage_committed = collider.call(
				&"apply_weapon_damage", float(weapon["damage"]), shot_id, muzzle_origin
			) == true
		else:
			result = &"blocked"
	var viewport_rect := camera.get_viewport().get_visible_rect()
	var reticle_center := viewport_rect.position + viewport_rect.size * 0.5
	var visible_reticle := _visible_reticle_receipt(viewport_rect)
	var visible_reticle_center: Vector2 = visible_reticle.get("center", reticle_center)
	var aim_projection := Vector2(-1.0, -1.0) if camera.is_position_behind(aim_point) else camera.unproject_position(aim_point)
	var hit_projection := Vector2(-1.0, -1.0) if camera.is_position_behind(hit_position) else camera.unproject_position(hit_position)
	var committed_at_usec := Time.get_ticks_usec()
	var committed_frame := Engine.get_process_frames()
	return {
		"shot_id": shot_id,
		"run_epoch": _run_epoch,
		"weapon_id": _equipped_id,
		"timestamp_seconds": _now(),
		"committed_at_usec": committed_at_usec,
		"committed_frame": committed_frame,
		"aim_origin": camera_origin,
		"aim_direction": camera_direction,
		"camera_origin": camera_origin,
		"muzzle_origin": muzzle_origin,
		"direction": muzzle_direction,
		"authoritative_aim_endpoint": aim_point,
		"authoritative_hit_endpoint": hit_position,
		"screen_projection": {
			"viewport_rect": viewport_rect,
			"reticle_center": reticle_center,
			"visible_reticle": visible_reticle,
			"visible_reticle_center": visible_reticle_center,
			"aim_endpoint": aim_projection,
			"hit_endpoint": hit_projection,
			"aim_pixel_delta": aim_projection.distance_to(reticle_center) if aim_projection.x >= 0.0 else -1.0,
			"hit_pixel_delta": hit_projection.distance_to(reticle_center) if hit_projection.x >= 0.0 else -1.0,
			"visible_aim_pixel_delta": aim_projection.distance_to(visible_reticle_center) if aim_projection.x >= 0.0 else -1.0,
			"visible_hit_pixel_delta": hit_projection.distance_to(visible_reticle_center) if hit_projection.x >= 0.0 else -1.0,
			"aim_visible": aim_projection.x >= 0.0,
			"hit_visible": hit_projection.x >= 0.0,
		},
		"result": result,
		"collider_path": collider_path,
		"hit_position": hit_position,
		"hit_normal": hit_normal,
		"damage": float(weapon["damage"]) if damage_committed else 0.0,
		"damage_commit": damage_committed,
		"ammo_commit": 1,
		"presentation_commit": 1,
		"accepted": true,
		"hit": result == &"hit",
		"source_team": &"player",
		"surface_kind": &"character" if result == &"hit" else &"concrete" if result == &"blocked" else &"air",
		"input_source": _active_fire_source,
	}


func _excluded_rids() -> Array[RID]:
	var excluded: Array[RID] = []
	var player := get_tree().get_first_node_in_group(&"player") as CollisionObject3D
	if player != null:
		excluded.append(player.get_rid())
	return excluded


func _muzzle_origin() -> Vector3:
	var muzzle := feedback.get_node_or_null("MuzzleFlash") as Node3D
	return muzzle.global_position if muzzle != null else camera.global_position


func _visible_reticle_receipt(viewport_rect: Rect2) -> Dictionary:
	if hud_reticle == null:
		return {
			"bound": false,
			"center": viewport_rect.position + viewport_rect.size * 0.5,
			"source": &"viewport_center_fallback",
		}
	var rect := hud_reticle.get_global_rect()
	return {
		"bound": true,
		"path": hud_reticle.get_path(),
		"rect": rect,
		"center": rect.get_center(),
		"visible": hud_reticle.visible and hud_reticle.is_visible_in_tree(),
		"alpha": hud_reticle.modulate.a,
		"source": &"hud_reticle_global_rect",
	}


func _present_dry_fire() -> void:
	_cancel_held_fire("dry_fire")
	_action_state = &"dry_fire"
	_action_until = _now() + 0.22
	_recovery_until = _action_until
	if hud_result != null:
		hud_result.text = "DRY"
		hud_result.modulate = Color(1.0, 0.47, 0.24)
	_last_result_until = _now() + 0.45
	var player := feedback.get_node_or_null("InspectAudio") as AudioStreamPlayer
	if player != null:
		player.pitch_scale = 1.22
		player.play(0.05)
	weapon_state_changed.emit(_mcp_state())


func _begin_reload() -> void:
	var weapon := _current_weapon()
	if _action_state == &"reload" or int(weapon["magazine"]) >= int(weapon["capacity"]) or int(weapon["reserve"]) <= 0:
		return
	_cancel_action(&"reload")
	_reload_kind = &"empty" if int(weapon["magazine"]) == 0 else &"tactical"
	_action_state = &"reload"
	_action_until = _now() + float(weapon["empty_reload_seconds"] if _reload_kind == &"empty" else weapon["tactical_reload_seconds"])
	feedback.call(&"trigger_reload")
	# The coupled AK-74M's authored primary tactical clip preserves the support
	# hand on the magazine/fore-end contact chain. Keep the whole component intact
	# and select that supplied clip at the wrapper boundary.
	viewmodel.call(&"play_clip", &"empty_reload" if _reload_kind == &"empty" else &"reload")
	weapon_state_changed.emit(_mcp_state())


func _commit_reload() -> void:
	var weapon := _current_weapon()
	var needed := int(weapon["capacity"]) - int(weapon["magazine"])
	var transferred := mini(needed, int(weapon["reserve"]))
	weapon["magazine"] = int(weapon["magazine"]) + transferred
	weapon["reserve"] = int(weapon["reserve"]) - transferred
	_weapons[_equipped_id] = weapon
	_reload_kind = &"none"
	_action_state = &"ads" if _ads_held else &"hip"
	_request_viewmodel_aim(_ads_held)
	viewmodel.call(&"play_clip", &"idle")
	weapon_state_changed.emit(_mcp_state())


func _set_ads(enabled: bool) -> void:
	_ads_held = enabled
	if _action_state in [&"reload", &"switch", &"inspect"]:
		return
	_request_viewmodel_aim(enabled)
	_action_state = &"ads" if enabled else &"hip"
	weapon_state_changed.emit(_mcp_state())


func _request_viewmodel_aim(enabled: bool, immediate := false) -> void:
	_ads_transition_serial += 1
	_ads_transition_complete = immediate
	viewmodel.call(&"set_aiming", enabled, immediate)
	if immediate:
		_viewmodel_ads_settled = enabled


func _on_viewmodel_aiming_changed(enabled: bool) -> void:
	_viewmodel_ads_settled = enabled
	_ads_transition_complete = enabled == _ads_held
	weapon_state_changed.emit(_mcp_state())


func _toggle_fire_mode() -> void:
	if _action_state in [&"reload", &"switch", &"inspect"]:
		return
	_end_fire()
	var weapon := _current_weapon()
	weapon["fire_mode"] = FIRE_MODE_SEMI if weapon["fire_mode"] == FIRE_MODE_AUTO else FIRE_MODE_AUTO
	_weapons[_equipped_id] = weapon
	weapon_state_changed.emit(_mcp_state())


func _switch_weapon(direction: int) -> void:
	var index := WEAPON_ORDER.find(_equipped_id)
	_equip_weapon(WEAPON_ORDER[posmod(index + direction, WEAPON_ORDER.size())])


func _equip_weapon(weapon_id: StringName) -> void:
	if weapon_id == _equipped_id or not _weapons.has(weapon_id) or not _pending_equipped_id.is_empty():
		return
	_cancel_action(&"switch")
	_pending_equipped_id = weapon_id
	_action_state = &"switch"
	_action_until = _now() + 0.45
	if viewmodel.call(&"equip_weapon_id", weapon_id, false) != true:
		_pending_equipped_id = &""
		_action_state = &"hip"
	weapon_state_changed.emit(_mcp_state())


func _on_viewmodel_weapon_changed(weapon_id: StringName, _weapon_index: int) -> void:
	_cancel_product_recoil()
	_equipped_id = weapon_id
	_capture_product_recoil_baseline(true)
	_pending_equipped_id = &""
	_action_state = &"hip"
	_ads_held = false
	_viewmodel_ads_settled = false
	_ads_transition_complete = true
	weapon_state_changed.emit(_mcp_state())


func _begin_inspect() -> void:
	if _action_state not in [&"hip", &"ads"]:
		return
	_cancel_action(&"inspect")
	_action_state = &"inspect"
	_action_until = _now() + 1.35
	if viewmodel.call(&"play_clip", &"inspect") == true:
		feedback.call(&"trigger_inspect")
		return
	_inspect_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_inspect_tween.tween_property(viewmodel, "rotation_degrees", Vector3(-7.0, -24.0, 4.0), 0.32)
	_inspect_tween.tween_interval(0.58)
	_inspect_tween.tween_property(viewmodel, "rotation_degrees", Vector3.ZERO, 0.36)
	feedback.call(&"trigger_inspect")


func _finish_inspect() -> void:
	viewmodel.rotation_degrees = Vector3.ZERO
	_request_viewmodel_aim(_ads_held, true)
	viewmodel.call(&"play_clip", &"idle")
	_action_state = &"ads" if _ads_held else &"hip"
	weapon_state_changed.emit(_mcp_state())


func _cancel_action(next_state: StringName) -> void:
	_cancel_held_fire(String(next_state))
	_reload_kind = &"none"
	if _inspect_tween != null and _inspect_tween.is_valid():
		_inspect_tween.kill()
	_stop_weapon_feedback_only()
	_cancel_product_recoil()
	viewmodel.rotation_degrees = Vector3.ZERO
	_request_viewmodel_aim(false, true)
	_action_state = next_state


func _on_spawn_reset() -> void:
	_ads_held = false
	_ads_rearm_required = _observed_ads_down
	_cancel_action(&"hip")
	_weapons = _fresh_weapon_data()
	_equipped_id = &"ak74m"
	_pending_equipped_id = &""
	_shot_serial = 0
	_shot_commits.clear()
	_shot_history.clear()
	_last_shot.clear()
	_impact_commits.clear()
	_impact_history.clear()
	reset_shot_presentation(_run_epoch)
	_clear_live_impacts()
	viewmodel.call(&"equip_weapon_id", _equipped_id, true)
	for node: Node in get_tree().get_nodes_in_group(&"controlled_target"):
		if node.has_method(&"reset_target"):
			node.call(&"reset_target")
	weapon_state_changed.emit(_mcp_state())


func _fresh_weapon_data() -> Dictionary:
	return {
		&"ak74m": {
			"display_name": "AK-74M", "capacity": 30, "magazine": 30, "reserve": 120,
			"fire_mode": FIRE_MODE_AUTO, "rounds_per_minute": 650.0, "damage": 28.0,
			"tactical_reload_seconds": 2.15, "empty_reload_seconds": 2.85, "recovery_seconds": 0.16,
		},
		&"saiga12": {
			"display_name": "SAIGA-12", "capacity": 8, "magazine": 8, "reserve": 40,
			"fire_mode": FIRE_MODE_AUTO, "rounds_per_minute": 320.0, "damage": 42.0,
			"tactical_reload_seconds": 2.4, "empty_reload_seconds": 3.05, "recovery_seconds": 0.24,
		},
	}


func _configure_component_feedback_boundary() -> void:
	# The registered component keeps ownership of clips, audio and muzzle flash.
	# Its exported recoil channel is disabled through public properties so the
	# product adapter is the sole writer of the model mount transform. Product
	# Locomotion playback and bus routing belong exclusively to PrototypePlayer.
	# This boundary configures weapon recoil only and never touches the retained
	# WalkAudio/RunAudio players.
	feedback.set("fire_recoil_back_distance", 0.0)
	feedback.set("fire_recoil_pitch_degrees", 0.0)
	feedback.set("fire_recoil_yaw_degrees", 0.0)
	feedback.set("fire_recoil_roll_degrees", 0.0)


func _capture_retained_component_report_identity() -> void:
	var single_player := feedback.get_node_or_null("FireAudio") as AudioStreamPlayer
	if single_player == null or single_player.stream == null:
		return
	# Observation only: the retained component owns both report players and their
	# accepted streams. The product adapter authorizes shot playback and lifecycle
	# cleanup, but must never substitute, derive, or rewrite either source.
	_single_report_source_path = single_player.stream.resource_path
	_bounded_single_report_duration = float(feedback.get("semi_fire_audio_seconds"))


func set_run_epoch(epoch: int, reset_transients := true) -> bool:
	if epoch <= 0 or epoch < _run_epoch:
		_last_run_epoch_receipt = {
			"accepted": false,
			"requested_epoch": epoch,
			"previous_epoch": _run_epoch,
			"failure_reason": &"non_monotonic_run_epoch",
		}
		return false
	var previous_epoch := _run_epoch
	_run_epoch = epoch
	if epoch > previous_epoch:
		_shot_serial = 0
		_shot_commits.clear()
	if reset_transients:
		reset_transient_state_for_restore()
	reset_shot_presentation(_run_epoch)
	_last_run_epoch_receipt = {
		"accepted": true,
		"run_epoch": _run_epoch,
		"previous_epoch": previous_epoch,
		"fresh_namespace": _run_epoch > previous_epoch,
		"transients_reset": reset_transients,
	}
	return true


func reset_shot_presentation(epoch := -1) -> void:
	var effective_epoch := _run_epoch if epoch < 0 else epoch
	shot_feedback.begin_run_epoch(effective_epoch)


func _fire_interval() -> float:
	return 60.0 / float(_current_weapon()["rounds_per_minute"])


func _capture_product_recoil_baseline(force := false) -> bool:
	var mount := viewmodel.get("model_mount") as Node3D
	if mount == null:
		return false
	if force or mount != _product_recoil_mount:
		_product_recoil_mount = mount
		_product_recoil_baseline_position = mount.position
		_product_recoil_baseline_rotation_degrees = mount.rotation_degrees
	return true


func _trigger_product_recoil(auto_fire: bool) -> void:
	# The materialized component retains its authored feedback implementation.
	# Fusepoint owns cadence/lifecycle authority, so cancel the component-local
	# tween before its first frame and coordinate recoil from one stable product
	# baseline instead of promoting a displaced pose to the next shot origin.
	if not _capture_product_recoil_baseline():
		return
	if _product_recoil_tween != null and _product_recoil_tween.is_valid():
		_product_recoil_tween.kill()
	var mount := _product_recoil_mount
	var kick_scale := 0.65 if auto_fire else 1.0
	var start_position := mount.position
	var start_rotation := mount.rotation_degrees
	var kick_position := _product_recoil_baseline_position + Vector3(
		0.0,
		0.0,
		-recoil_back_distance * kick_scale,
	)
	var kick_rotation := _product_recoil_baseline_rotation_degrees + Vector3(
		-recoil_pitch_degrees * kick_scale,
		(randf() * 2.0 - 1.0) * recoil_yaw_degrees * kick_scale,
		(randf() * 2.0 - 1.0) * recoil_roll_degrees * kick_scale,
	)
	_product_recoil_shot_serial += 1
	_product_recoil_phase = &"impulse"
	_product_recoil_recovery_complete = false
	_product_recoil_tween = create_tween()
	_product_recoil_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_product_recoil_tween.tween_method(
		_apply_product_recoil_pose.bind(mount, start_position, start_rotation, kick_position, kick_rotation),
		0.0,
		1.0,
		recoil_out_seconds,
	)
	_product_recoil_tween.tween_callback(_mark_product_recoil_peak)
	_product_recoil_tween.tween_interval(recoil_hold_seconds)
	_product_recoil_tween.tween_callback(_mark_product_recoil_recovery)
	_product_recoil_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_product_recoil_tween.tween_method(
		_apply_product_recoil_pose.bind(mount, kick_position, kick_rotation, _product_recoil_baseline_position, _product_recoil_baseline_rotation_degrees),
		0.0,
		1.0,
		recoil_return_seconds,
	)
	_product_recoil_tween.tween_callback(_finish_product_recoil.bind(mount))


func _apply_product_recoil_pose(weight: float, mount: Node3D, from_position: Vector3, from_rotation: Vector3, to_position: Vector3, to_rotation: Vector3) -> void:
	if not is_instance_valid(mount) or mount != _product_recoil_mount:
		return
	mount.position = from_position.lerp(to_position, weight)
	mount.rotation_degrees = from_rotation.lerp(to_rotation, weight)


func _mark_product_recoil_peak() -> void:
	_product_recoil_peak_serial += 1
	_product_recoil_phase = &"peak_hold"


func _mark_product_recoil_recovery() -> void:
	_product_recoil_phase = &"recovery"


func _finish_product_recoil(mount: Node3D) -> void:
	if is_instance_valid(mount) and mount == _product_recoil_mount:
		mount.position = _product_recoil_baseline_position
		mount.rotation_degrees = _product_recoil_baseline_rotation_degrees
	_product_recoil_phase = &"settled"
	_product_recoil_recovery_complete = true


func _enforce_product_recoil_baseline_if_settled() -> void:
	if not _product_recoil_recovery_complete or _action_state not in [&"idle", &"hip", &"ads"]:
		return
	if is_instance_valid(_product_recoil_mount):
		_product_recoil_mount.position = _product_recoil_baseline_position
		_product_recoil_mount.rotation_degrees = _product_recoil_baseline_rotation_degrees


func _cancel_product_recoil() -> void:
	if _product_recoil_tween != null and _product_recoil_tween.is_valid():
		_product_recoil_tween.kill()
	_product_recoil_tween = null
	if is_instance_valid(_product_recoil_mount):
		_product_recoil_mount.position = _product_recoil_baseline_position
		_product_recoil_mount.rotation_degrees = _product_recoil_baseline_rotation_degrees
	_product_recoil_phase = &"settled"
	_product_recoil_recovery_complete = true


func _product_recoil_state() -> Dictionary:
	var current_position := _product_recoil_mount.position if is_instance_valid(_product_recoil_mount) else Vector3.ZERO
	var current_rotation := _product_recoil_mount.rotation_degrees if is_instance_valid(_product_recoil_mount) else Vector3.ZERO
	return {
		"phase": _product_recoil_phase,
		"shot_serial": _product_recoil_shot_serial,
		"peak_serial": _product_recoil_peak_serial,
		"current_position_offset": current_position - _product_recoil_baseline_position,
		"current_rotation_offset_degrees": current_rotation - _product_recoil_baseline_rotation_degrees,
		"baseline_position_error": current_position.distance_to(_product_recoil_baseline_position),
		"baseline_rotation_error_degrees": current_rotation.distance_to(_product_recoil_baseline_rotation_degrees),
		"recovery_complete": _product_recoil_recovery_complete,
	}


func _current_weapon() -> Dictionary:
	return _weapons[_equipped_id]


func set_gameplay_input_enabled(enabled: bool) -> void:
	gameplay_input_enabled = enabled
	if not enabled:
		_cancel_queued_fire_edges("gameplay_disabled")
		_cancel_held_fire("gameplay_disabled")
		_fire_rearm_required = _observed_fire_down
		_ads_rearm_required = _observed_ads_down
		_ads_held = false
		_cancel_action(&"idle")
	elif _action_state == &"idle":
		_action_state = &"hip"
		_request_viewmodel_aim(false, true)
	# A press observed across a page/pause/death/restore boundary remains armed
	# off until its genuine release event arrives; enabling never samples a
	# physical level and therefore cannot fabricate a transition.


func equip_loadout(weapon_id: StringName) -> bool:
	if not _weapons.has(weapon_id):
		return false
	_cancel_action(&"hip")
	if viewmodel.call(&"equip_weapon_id", weapon_id, true) != true:
		return false
	_equipped_id = weapon_id
	_pending_equipped_id = &""
	_capture_product_recoil_baseline(true)
	weapon_state_changed.emit(_mcp_state())
	return true



func _stop_weapon_feedback_only() -> void:
	# Do not call the component's broad stop_feedback(), because that method also
	# stops WalkAudio/RunAudio and would create a second locomotion control path.
	if feedback.has_method(&"end_fire"):
		feedback.call(&"end_fire")
	if feedback.has_method(&"_stop_reload_mount"):
		feedback.call(&"_stop_reload_mount")
	var muzzle_flash := feedback.get_node_or_null("MuzzleFlash") as Node3D
	if muzzle_flash != null:
		muzzle_flash.visible = false
	for player_name: StringName in [&"FireAudio", &"AutoFireAudio", &"ReloadAudio", &"SwitchAudio", &"AimAudio", &"InspectAudio"]:
		var player := feedback.get_node_or_null(NodePath(player_name)) as AudioStreamPlayer
		if player != null:
			player.stop()


func _sync_hud() -> void:
	var weapon := _current_weapon()
	if hud_weapon != null:
		hud_weapon.text = String(weapon["display_name"])
	if hud_ammo != null:
		hud_ammo.text = "%02d  /  %03d" % [int(weapon["magazine"]), int(weapon["reserve"])]
	if hud_mode != null:
		hud_mode.text = String(weapon["fire_mode"])
	if hud_action != null:
		hud_action.text = String(_action_state).to_upper()
	if hud_reticle != null:
		hud_reticle.modulate.a = 0.0 if _ads_held else 0.9


func _present_shot_result(receipt: Dictionary) -> void:
	if hud_result == null:
		return
	match receipt["result"]:
		&"hit":
			hud_result.text = "HIT"
			hud_result.modulate = Color(1.0, 0.78, 0.24)
		&"blocked":
			hud_result.text = "BLOCKED"
			hud_result.modulate = Color(0.85, 0.9, 0.96)
		_:
			hud_result.text = "MISS"
			hud_result.modulate = Color(0.55, 0.75, 0.86)
	_last_result_until = _now() + 0.34


func deliver_impact_receipt(receipt: Dictionary) -> bool:
	return _dispatch_impact_receipt(receipt)


func _dispatch_impact_receipt(receipt: Dictionary) -> bool:
	var shot_id := String(receipt.get("shot_id", ""))
	var result := StringName(receipt.get("result", &"miss"))
	if shot_id.is_empty() or result == &"miss" or _impact_commits.has(shot_id):
		return false
	if result not in [&"hit", &"blocked"]:
		return false
	var position: Vector3 = receipt.get("hit_position", Vector3.ZERO)
	var normal: Vector3 = receipt.get("hit_normal", Vector3.UP)
	if normal.is_zero_approx():
		normal = Vector3.UP
	var lifetime := 0.34 if result == &"hit" else 0.48
	var variant := &"target_spark" if result == &"hit" else &"surface_chip"
	_impact_commits[shot_id] = true
	var event := {
		"shot_id": shot_id,
		"result": result,
		"position": position,
		"normal": normal,
		"variant": variant,
		"spawn_count": 1,
		"committed_at_seconds": _now(),
		"lifetime_seconds": lifetime,
		"expires_at_seconds": _now() + lifetime,
	}
	_impact_history.append(event)
	while _impact_history.size() > 24:
		_impact_history.pop_front()
	return true


func _spawn_impact(event: Dictionary) -> void:
	var result := StringName(event["result"])
	var root := Node3D.new()
	root.name = "ShotImpact_%s" % String(event["shot_id"]).replace("-", "_")
	root.add_to_group(&"shot_impacts")
	var marker := MeshInstance3D.new()
	marker.name = "TargetSpark" if result == &"hit" else "SurfaceChip"
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.92, 0.55) if result == &"hit" else Color(0.46, 0.88, 1.0)
	material.emission_enabled = true
	material.emission = material.albedo_color
	material.emission_energy_multiplier = 4.2 if result == &"hit" else 1.8
	material.roughness = 0.5 if result == &"hit" else 0.9
	if result == &"hit":
		var sphere := SphereMesh.new()
		sphere.radius = 0.075
		sphere.height = 0.15
		sphere.radial_segments = 12
		sphere.rings = 6
		sphere.material = material
		marker.mesh = sphere
	else:
		var chip := CylinderMesh.new()
		chip.top_radius = 0.095
		chip.bottom_radius = 0.064
		chip.height = 0.008
		chip.radial_segments = 10
		chip.material = material
		marker.mesh = chip
	root.add_child(marker)
	get_tree().current_scene.add_child(root)
	var normal: Vector3 = event["normal"]
	root.global_position = event["position"] + normal * 0.012
	root.global_basis = _basis_from_up(normal)
	var lifetime := float(event["lifetime_seconds"])
	var tween := root.create_tween()
	if result == &"hit":
		root.scale = Vector3.ONE * 0.35
		tween.tween_property(root, "scale", Vector3.ONE * 1.35, lifetime * 0.24).set_trans(Tween.TRANS_QUAD)
		tween.tween_property(root, "scale", Vector3.ONE * 0.08, lifetime * 0.76).set_trans(Tween.TRANS_EXPO)
	else:
		root.scale = Vector3(0.45, 0.2, 0.45)
		tween.tween_property(root, "scale", Vector3(1.0, 0.35, 1.0), lifetime * 0.32).set_trans(Tween.TRANS_QUAD)
		tween.tween_interval(lifetime * 0.5)
		tween.tween_property(root, "scale", Vector3(0.72, 0.08, 0.72), lifetime * 0.18)
	tween.finished.connect(root.queue_free)


func _basis_from_up(normal: Vector3) -> Basis:
	var up := normal.normalized()
	var tangent := Vector3.FORWARD.cross(up)
	if tangent.is_zero_approx():
		tangent = Vector3.RIGHT
	tangent = tangent.normalized()
	return Basis(tangent, up, up.cross(tangent).normalized()).orthonormalized()


func _clear_live_impacts() -> void:
	for node: Node in get_tree().get_nodes_in_group(&"shot_impacts"):
		node.queue_free()


func snapshot_weapon_state() -> Dictionary:
	return {
		"run_epoch": _run_epoch,
		"weapons": _weapons.duplicate(true),
		"equipped_id": _equipped_id,
		"shot_serial": _shot_serial,
		"shot_commits": _shot_commits.duplicate(true),
		"shot_history": _shot_history.duplicate(true),
		"last_shot": _last_shot.duplicate(true),
		"impact_commits": _impact_commits.duplicate(true),
		"impact_history": _impact_history.duplicate(true),
	}


func restore_weapon_state(snapshot: Dictionary, epoch := 0, allow_same_epoch := false) -> Dictionary:
	var epoch_rejected := epoch < _restore_epoch or (epoch == _restore_epoch and not allow_same_epoch)
	if epoch_rejected or not snapshot.has("weapons") or not snapshot.has("equipped_id"):
		_last_restore_receipt = {
			"accepted": false,
			"restore_epoch": epoch,
			"failure_reason": &"non_monotonic_epoch" if epoch_rejected else &"snapshot_schema_invalid",
		}
		return _last_restore_receipt.duplicate(true)
	var serial_before := _shot_serial
	_restore_epoch = epoch
	_transient_reset_complete = false
	_ads_held = false
	_ads_rearm_required = _observed_ads_down
	_cancel_action(&"hip")
	_weapons = snapshot.get("weapons", _fresh_weapon_data()).duplicate(true)
	_equipped_id = StringName(snapshot.get("equipped_id", &"ak74m"))
	_pending_equipped_id = &""
	_shot_serial = maxi(serial_before, int(snapshot.get("shot_serial", 0)))
	reset_transient_state_for_restore()
	var viewmodel_bound: bool = viewmodel.call(&"equip_weapon_id", _equipped_id, true) == true
	_last_restore_receipt = {
		"accepted": _transient_reset_complete and viewmodel_bound,
		"restore_epoch": _restore_epoch,
		"equipped_id": _equipped_id,
		"shot_serial_monotonic": _shot_serial >= serial_before,
		"transient_reset_complete": _transient_reset_complete,
		"viewmodel_bound": viewmodel_bound,
		"failure_reason": &"" if viewmodel_bound else &"viewmodel_binding_failed",
	}
	weapon_state_changed.emit(_mcp_state())
	return _last_restore_receipt.duplicate(true)


func reset_transient_state_for_restore() -> void:
	_stop_tester_audio_fixture(&"checkpoint_restore")
	_cancel_queued_fire_edges("checkpoint_restore")
	_cancel_held_fire("checkpoint_restore")
	_observed_fire_down = false
	_fire_rearm_required = false
	_active_fire_source = &"none"
	_active_fire_press_edge_id = ""
	_active_fire_press_time_usec = 0
	_active_fire_press_started_combat_seconds = 0.0
	_active_fire_press_shot_count = 0
	_active_fire_continuation_authorized = false
	_auto_continuation_confirmation_pending = false
	_shot_commits.clear()
	_shot_history.clear()
	_last_shot.clear()
	_impact_commits.clear()
	_impact_history.clear()
	_last_input_receipt.clear()
	_input_history.clear()
	_last_ads_receipt.clear()
	_ads_history.clear()
	_last_result_until = 0.0
	if hud_result != null:
		hud_result.text = ""
	shot_feedback.reset_feedback()
	_clear_live_impacts()
	_cancel_product_recoil()
	_transient_reset_complete = true


func tester_prepare_audio_stem(stem_id: StringName) -> Dictionary:
	_tester_audio_generation += 1
	var generation := _tester_audio_generation
	var receipt := {
		"fixture_id": "tester-audio-%s-%06d" % [String(stem_id), generation],
		"requested": true,
		"resolved": false,
		"accepted": false,
		"stem_id": stem_id,
		"setup_generation": generation,
		"release_guard": &"OS.is_debug_build",
		"non_release": OS.is_debug_build(),
		"run_epoch": _run_epoch,
		"normal_player_report_owner_count": 2,
		"player_report_owner_state": _player_report_owner_state(),
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return _store_tester_audio_receipt(receipt)
	_stop_tester_audio_fixture(&"new_prepare")
	if stem_id == &"component_report":
		var component_player := feedback.get_node_or_null("FireAudio") as AudioStreamPlayer
		receipt.merge({
			"resolved": component_player != null and component_player.stream != null,
			"accepted": component_player != null and component_player.stream != null and not component_player.playing,
			"branch_id": StringName("audio_stem:%s" % String(stem_id)),
			"source_path": component_player.stream.resource_path if component_player != null and component_player.stream != null else "",
			"owner_path": component_player.get_path() if component_player != null else NodePath(),
			"duration_seconds": component_player.stream.get_length() if component_player != null and component_player.stream != null else 0.0,
			"bounded_product_derivative": false,
			"retained_component_owner": true,
			"prepared_silent": component_player == null or not component_player.playing,
			"normal_fire_path_used": false,
			"normal_player_report_owner_count": 2,
			"player_report_owner_state": _player_report_owner_state(),
			"reset_isolation": {"authoritative_shot_committed": false, "diagnostic_owner_separate": false, "voice_started": false},
			"failure_reason": &"" if component_player != null and component_player.stream != null else &"component_player_unavailable",
		}, true)
	elif stem_id == &"product_adapter_report":
		receipt.merge({
			"resolved": true,
			"accepted": true,
			"branch_id": &"audio_stem:product_adapter_report",
			"source_path": "",
			"owner_path": NodePath(),
			"adapter_absent": true,
			"normal_player_report_owner_count": 2,
			"player_report_owner_state": _player_report_owner_state(),
			"prepared_silent": true,
			"reset_isolation": {"authoritative_shot_committed": false, "voice_started": false},
			"failure_reason": &"",
		}, true)
	else:
		var delegated: Dictionary
		if stem_id == &"capacity_cleanup":
			delegated = shot_feedback.tester_prepare_capacity_cleanup(generation)
		elif stem_id == &"reset":
			delegated = shot_feedback.tester_reset_feedback_fixture(generation)
		else:
			delegated = shot_feedback.tester_prepare_audio_stem(stem_id, generation)
		receipt["resolved"] = delegated.get("resolved", false)
		receipt["accepted"] = delegated.get("accepted", false)
		receipt["branch_id"] = delegated.get("branch_id", StringName("audio_stem:%s" % String(stem_id)))
		receipt["delegated_feedback_receipt"] = delegated
		receipt["source_path"] = delegated.get("source_path", "")
		receipt["owner_path"] = delegated.get("owner_path", "")
		receipt["player_report_owner_state"] = _player_report_owner_state()
		receipt["reset_isolation"] = delegated.get("reset_isolation", {})
		receipt["failure_reason"] = delegated.get("failure_reason", &"")
	return _store_tester_audio_receipt(receipt)


func tester_advance_audio_stem(stem_id: StringName, expected_generation: int) -> Dictionary:
	var prepared := _last_tester_audio_receipt.duplicate(true)
	var receipt := {
		"fixture_id": "tester-audio-%s-advance-%06d" % [String(stem_id), expected_generation],
		"requested": true,
		"resolved": false,
		"accepted": false,
		"stem_id": stem_id,
		"setup_generation": expected_generation,
		"release_guard": &"OS.is_debug_build",
		"non_release": OS.is_debug_build(),
		"run_epoch": _run_epoch,
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return _store_tester_audio_receipt(receipt)
	if int(prepared.get("setup_generation", -1)) != expected_generation or StringName(prepared.get("stem_id", &"")) != stem_id or prepared.get("accepted", false) != true:
		receipt["failure_reason"] = &"prepared_generation_mismatch"
		return _store_tester_audio_receipt(receipt)
	if stem_id == &"component_report":
		var component_player := feedback.get_node_or_null("FireAudio") as AudioStreamPlayer
		if component_player != null and component_player.stream != null:
			feedback.call(&"trigger_fire", false)
			receipt.merge({
				"resolved": true,
				"accepted": component_player.playing,
				"branch_id": prepared.get("branch_id", &""),
				"source_path": component_player.stream.resource_path,
				"owner_path": component_player.get_path(),
				"onset_usec": Time.get_ticks_usec(),
				"onset_frame": Engine.get_process_frames(),
				"physical_eof_seconds": component_player.stream.get_length(),
				"component_timeout_seconds": _bounded_single_report_duration,
				"component_timeout_method": &"_play_audio_with_timeout",
				"retained_component_owner": true,
				"normal_player_report_owner_count": 2,
				"player_report_owner_state": _player_report_owner_state(),
				"reset_isolation": {"authoritative_shot_committed": false, "diagnostic_owner_separate": false},
				"failure_reason": &"" if component_player.playing else &"playback_did_not_start",
			}, true)
	elif stem_id == &"product_adapter_report":
		receipt.merge({
			"resolved": true,
			"accepted": true,
			"branch_id": prepared.get("branch_id", &""),
			"adapter_absent": true,
			"voice_started": false,
			"normal_player_report_owner_count": 2,
			"player_report_owner_state": _player_report_owner_state(),
			"reset_isolation": {"authoritative_shot_committed": false, "voice_started": false},
			"failure_reason": &"",
		}, true)
	else:
		var delegated: Dictionary = shot_feedback.tester_advance_audio_stem(stem_id, expected_generation)
		receipt.merge({
			"resolved": delegated.get("resolved", false),
			"accepted": delegated.get("accepted", false),
			"branch_id": delegated.get("branch_id", &""),
			"source_path": delegated.get("source_path", ""),
			"owner_path": delegated.get("owner_path", ""),
			"delegated_feedback_receipt": delegated,
			"player_report_owner_state": _player_report_owner_state(),
			"reset_isolation": delegated.get("reset_isolation", {}),
			"failure_reason": delegated.get("failure_reason", &""),
		}, true)
	return _store_tester_audio_receipt(receipt)


func _stop_tester_audio_fixture(reason: StringName) -> void:
	var component_player := feedback.get_node_or_null("FireAudio") as AudioStreamPlayer
	if component_player != null:
		component_player.stop()
	if not _last_tester_audio_receipt.is_empty():
		_last_tester_audio_receipt["stop_reason"] = reason
		_last_tester_audio_receipt["stopped"] = true


func _store_tester_audio_receipt(receipt: Dictionary) -> Dictionary:
	_last_tester_audio_receipt = receipt.duplicate(true)
	_tester_audio_history.append(_last_tester_audio_receipt.duplicate(true))
	while _tester_audio_history.size() > 12:
		_tester_audio_history.pop_front()
	return _last_tester_audio_receipt.duplicate(true)


func _visible_rig_audit() -> Dictionary:
	var mesh_paths: Array[String] = []
	var skeleton_paths: Array[String] = []
	var animation_players: Array[String] = []
	var socket_bones: Array[String] = []
	_audit_descendants(viewmodel, mesh_paths, skeleton_paths, animation_players, socket_bones)
	var skeleton := _first_runtime_skeleton(viewmodel)
	var animation_player := viewmodel.get("animation_player") as AnimationPlayer
	var profile: FPSViewmodelProfile = viewmodel.call(&"current_profile") as FPSViewmodelProfile
	var aliases: Dictionary = {}
	for alias: StringName in [&"idle", &"draw", &"walk", &"run", &"fire", &"reload", &"reload_variant", &"empty_reload", &"inspect"]:
		var clip := profile.animation_for(alias) if profile != null else &""
		var available := animation_player != null and not clip.is_empty() and animation_player.has_animation(clip)
		aliases[alias] = {
			"resolved_clip": clip,
			"available": available,
			"length_seconds": animation_player.get_animation(clip).length if available else 0.0,
		}
	var left_hand := _runtime_bone_receipt(skeleton, ["hand_l", "left_hand"])
	var right_hand := _runtime_bone_receipt(skeleton, ["hand_r", "right_hand"])
	var rifle_socket := _runtime_bone_receipt(skeleton, ["rif_"])
	var trigger_socket := _runtime_bone_receipt(skeleton, ["trigger"])
	var left_hand_position: Vector3 = left_hand.get("skeleton_local_position", Vector3.ZERO)
	var right_hand_position: Vector3 = right_hand.get("skeleton_local_position", Vector3.ZERO)
	var rifle_position: Vector3 = rifle_socket.get("skeleton_local_position", Vector3.ZERO)
	var trigger_position: Vector3 = trigger_socket.get("skeleton_local_position", Vector3.ZERO)
	return {
		"mesh_paths": mesh_paths,
		"skeleton_paths": skeleton_paths,
		"animation_players": animation_players,
		"socket_bones": socket_bones,
		"mesh_count": mesh_paths.size(),
		"skeleton_count": skeleton_paths.size(),
		"animation_player_count": animation_players.size(),
		"adapter_owner_path": String(get_path()),
		"component_internal_adaptation": false,
		"intact_component_root": viewmodel.get_node_or_null("SourceAxisAdapter/ModelMount/ActiveWeaponModel") != null,
		"bone_count": skeleton.get_bone_count() if skeleton != null else 0,
		"bone_bindings": {
			"left_hand": left_hand,
			"right_hand": right_hand,
			"rifle_socket": rifle_socket,
			"trigger_socket": trigger_socket,
		},
		"both_hands_bound": left_hand.get("bound", false) == true and right_hand.get("bound", false) == true,
		"rig_contact_evidence": {
			"source": &"runtime_skeleton_pose",
			"synthetic_marker_used": false,
			"support_hand_to_rifle_bone_distance": left_hand_position.distance_to(rifle_position) if left_hand.get("bound", false) and rifle_socket.get("bound", false) else -1.0,
			"firing_hand_to_trigger_bone_distance": right_hand_position.distance_to(trigger_position) if right_hand.get("bound", false) and trigger_socket.get("bound", false) else -1.0,
		},
		"semantic_aliases": aliases,
		"required_aliases_available": profile != null and profile.required_animations_available(animation_player),
	}


func _first_runtime_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root as Skeleton3D
	for child: Node in root.get_children():
		var found := _first_runtime_skeleton(child)
		if found != null:
			return found
	return null


func _runtime_bone_receipt(skeleton: Skeleton3D, tokens: Array[String]) -> Dictionary:
	if skeleton == null:
		return {"bound": false, "name": "", "index": -1}
	for bone_index in skeleton.get_bone_count():
		var bone_name := String(skeleton.get_bone_name(bone_index))
		var lowered := bone_name.to_lower()
		for token in tokens:
			if token in lowered:
				return {
					"bound": true,
					"name": bone_name,
					"index": bone_index,
					"skeleton_local_position": skeleton.get_bone_global_pose(bone_index).origin,
				}
	return {"bound": false, "name": "", "index": -1}


func _audit_descendants(node: Node, mesh_paths: Array[String], skeleton_paths: Array[String], animation_players: Array[String], socket_bones: Array[String]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).is_visible_in_tree():
		mesh_paths.append(String(node.get_path()))
	elif node is Skeleton3D:
		var skeleton := node as Skeleton3D
		skeleton_paths.append(String(skeleton.get_path()))
		for bone_index: int in skeleton.get_bone_count():
			var bone_name := String(skeleton.get_bone_name(bone_index))
			var lowered := bone_name.to_lower()
			if "hand_" in lowered or "rif" in lowered or "pmag" in lowered or "saiga" in lowered or "ak" in lowered:
				socket_bones.append(bone_name)
	elif node is AnimationPlayer:
		animation_players.append(String(node.get_path()))
	for child: Node in node.get_children():
		_audit_descendants(child, mesh_paths, skeleton_paths, animation_players, socket_bones)


func _now() -> float:
	return _combat_clock_seconds


func _input_source_for(event: InputEvent) -> StringName:
	if event is InputEventMouseButton:
		return &"mouse_left"
	if event is InputEventJoypadMotion:
		return &"gamepad_trigger"
	if event is InputEventJoypadButton:
		return &"gamepad_button"
	return &"mapped_action"


func _ads_input_source_for(event: InputEvent) -> StringName:
	if event is InputEventMouseButton:
		return &"mouse_right"
	if event is InputEventJoypadMotion:
		return &"gamepad_left_trigger"
	if event is InputEventJoypadButton:
		return &"gamepad_button"
	return &"mapped_action"


func _fire_rejection_reason() -> String:
	if not gameplay_input_enabled:
		return "gameplay_disabled"
	if not _pending_equipped_id.is_empty():
		return "weapon_switch"
	return "action_%s" % String(_action_state)


func _cancel_held_fire(reason: String) -> void:
	var had_active_press := _trigger_held or _active_fire_source != &"none" or not _active_fire_press_edge_id.is_empty()
	if had_active_press:
		var magazine := int(_current_weapon()["magazine"])
		_record_input_edge(_active_fire_source, &"cancel", false, "cancelled", "", magazine, magazine, reason)
	_stop_fire_report(StringName(reason), true)
	_trigger_held = false
	_active_fire_source = &"none"
	_active_fire_press_edge_id = ""
	_active_fire_press_time_usec = 0
	_active_fire_press_shot_count = 0
	_active_fire_continuation_authorized = false
	_auto_continuation_confirmation_pending = false


func _stop_fire_report(reason: StringName, stop_single_transient: bool) -> void:
	# Product lifecycle authority is centralized here. Ordinary release ends only
	# the sustained bed so the already-committed bounded transient can finish;
	# reload/pause/death/shell/restore boundaries stop both retained players.
	if feedback.has_method(&"end_fire"):
		feedback.call(&"end_fire")
	var single_player := feedback.get_node_or_null("FireAudio") as AudioStreamPlayer
	var auto_player := feedback.get_node_or_null("AutoFireAudio") as AudioStreamPlayer
	if stop_single_transient and single_player != null:
		single_player.stop()
		_single_report_generation += 1
		_single_report_deadline = -1.0
		_single_report_shot_id = ""
	if auto_player != null:
		auto_player.stop()
	_last_report_stop_reason = reason
	_report_serial += 1
	_last_report_receipt = {
		"report_event_id": "run-%06d:report:%06d" % [_run_epoch, _report_serial],
		"kind": &"stopped",
		"stop_reason": reason,
		"press_edge_id": _active_fire_press_edge_id,
		"stop_single_transient": stop_single_transient,
		"single_player_playing": single_player.playing if single_player != null else false,
		"auto_player_playing": auto_player.playing if auto_player != null else false,
		"player_report_owner_state": _player_report_owner_state(),
		"timestamp_seconds": _now(),
	}
	_append_report_receipt(_last_report_receipt)


func _record_report_request(receipt: Dictionary, playback_class: StringName, sustained_authorized: bool) -> void:
	var single_player := feedback.get_node_or_null("FireAudio") as AudioStreamPlayer
	var auto_player := feedback.get_node_or_null("AutoFireAudio") as AudioStreamPlayer
	_report_serial += 1
	_last_report_receipt = {
		"report_event_id": "run-%06d:report:%06d" % [_run_epoch, _report_serial],
		"kind": &"requested",
		"shot_id": receipt.get("shot_id", ""),
		"press_edge_id": receipt.get("press_edge_id", ""),
		"press_shot_ordinal": receipt.get("press_shot_ordinal", 0),
		"requested_playback_class": playback_class,
		"sustained_report_authorized": sustained_authorized,
		"component_timeout_seconds": _bounded_single_report_duration,
		"timeout_owner": &"retained_component_play_audio_with_timeout",
		"product_output_gate_used": false,
		"single_player_playing": single_player.playing if single_player != null else false,
		"auto_player_playing": auto_player.playing if auto_player != null else false,
		"cadence_seconds": _fire_interval(),
		"next_shot_time_seconds": _next_shot_time,
		"player_report_owner_state": _player_report_owner_state(),
		"timestamp_seconds": _now(),
	}
	_append_report_receipt(_last_report_receipt)


func _append_report_receipt(receipt: Dictionary) -> void:
	_report_history.append(receipt.duplicate(true))
	while _report_history.size() > 24:
		_report_history.pop_front()


func _cancel_queued_fire_edges(reason: String) -> void:
	while not _fire_edge_queue.is_empty():
		var edge: Dictionary = _fire_edge_queue.pop_front()
		var magazine := int(_current_weapon()["magazine"])
		_record_input_edge(
			StringName(edge.get("source", &"mapped_action")),
			&"press" if edge.get("pressed", false) else &"release",
			false,
			"cancelled",
			"",
			magazine,
			magazine,
			reason,
			String(edge.get("edge_id", "")),
		)


func _record_input_edge(
	source: StringName,
	edge: StringName,
	accepted: bool,
	reason: String,
	shot_id: String,
	magazine_before: int,
	magazine_after: int,
	cancellation_reason := "",
	edge_id := "",
) -> void:
	if edge_id.is_empty():
		_input_edge_serial += 1
		edge_id = "fire-input-%06d" % _input_edge_serial
	_last_input_receipt = {
		"edge_id": edge_id,
		"source": source,
		"edge": edge,
		"shell_gameplay_enabled": gameplay_input_enabled,
		"accepted": accepted,
		"reason": reason,
		"shot_id": shot_id,
		"magazine_before": magazine_before,
		"magazine_after": magazine_after,
		"cancellation_reason": cancellation_reason,
		"timestamp_seconds": _now(),
	}
	_input_history.append(_last_input_receipt.duplicate(true))
	while _input_history.size() > 32:
		_input_history.pop_front()


func _mcp_state() -> Dictionary:
	var weapon := _current_weapon()
	var audit := _visible_rig_audit()
	var recoil: Dictionary = _product_recoil_state()
	var profile: FPSViewmodelProfile = viewmodel.call(&"current_profile") as FPSViewmodelProfile
	var target_position := viewmodel.position
	var target_scale := viewmodel.scale
	if profile != null:
		target_position = profile.aim_position if _ads_held else profile.hip_position
		target_scale = profile.aim_scale if _ads_held else profile.hip_scale
	return {
		"run_epoch": _run_epoch,
		"fire_scheduler_state": {
			"fire_mode": weapon.get("fire_mode", FIRE_MODE_AUTO),
			"press_generation": _active_fire_press_edge_id,
			"shot_ordinal": _active_fire_press_shot_count,
			"trigger_held": _trigger_held,
			"queued_release_precedence": true,
			"raw_release_vetoes_continuation": true,
			"inputmap_level_vetoes_continuation": true,
			"ballistic_cadence_authorized": _active_fire_continuation_authorized,
			"continuation_confirmation_pending": _auto_continuation_confirmation_pending,
			"cadence_seconds": _fire_interval(),
			"first_continuation_release_grace_seconds": AUTO_FIRST_CONTINUATION_RELEASE_GRACE_SECONDS,
			"next_shot_time_seconds": _next_shot_time,
			"same_frame_catchup_pairs_allowed": false,
			"continuation_gate": &"deferred_held_level_at_cadence",
			"shot_count": _shot_serial,
			"magazine": weapon.get("magazine", 0),
			"last_shot_id": _last_shot.get("shot_id", ""),
			"playback_class": _last_report_receipt.get("requested_playback_class", &"stopped"),
			"sustained_authorized": _last_report_receipt.get("sustained_report_authorized", false),
			"single_player_playing": (_fire_audio_player_state().get("single", {}) as Dictionary).get("playing", false),
			"auto_player_playing": (_fire_audio_player_state().get("sustained", {}) as Dictionary).get("playing", false),
			"active_effect_count": shot_feedback.active_effect_count,
			"effect_cleanup_count": shot_feedback.snapshot().get("effect_cleanup_count", 0),
			"duplicate_cleanup_callback_count": shot_feedback.snapshot().get("duplicate_cleanup_callback_count", 0),
			"player_state": _action_state,
			"single_report_source_path": _single_report_source_path,
			"single_report_duration_seconds": _bounded_single_report_duration,
			"single_report_component_owner": &"retained_component_fire_audio",
			"player_report_owner_state": _player_report_owner_state(),
			"product_pcm_prefix_derivative_used": false,
			"tester_audio_summary": {
				"stem_id": _last_tester_audio_receipt.get("stem_id", &""),
				"setup_generation": _last_tester_audio_receipt.get("setup_generation", 0),
				"resolved": _last_tester_audio_receipt.get("resolved", false),
				"accepted": _last_tester_audio_receipt.get("accepted", false),
				"prepared_silent": _last_tester_audio_receipt.get("prepared_silent", false),
				"source_path": _last_tester_audio_receipt.get("source_path", ""),
				"owner_path": _last_tester_audio_receipt.get("owner_path", NodePath()),
				"onset_usec": _last_tester_audio_receipt.get("onset_usec", 0),
				"physical_eof_seconds": _last_tester_audio_receipt.get("physical_eof_seconds", 0.0),
				"failure_reason": _last_tester_audio_receipt.get("failure_reason", &""),
			},
			"recoil_phase": recoil.get("phase", &"unavailable"),
			"recoil_recovery_complete": recoil.get("recovery_complete", true),
			"recoil_position_error": recoil.get("baseline_position_error", 0.0),
			"recoil_rotation_error_degrees": recoil.get("baseline_rotation_error_degrees", 0.0),
		},
		# Keep patrol-critical hold/release fields before large nested audit data so
		# bounded runtime digests cannot truncate them away.
		"trigger_held": _trigger_held,
		"fire_action_down": _observed_fire_down,
		"fire_rearm_required": _fire_rearm_required,
		"active_fire_press_edge_id": _active_fire_press_edge_id,
		"active_fire_press_shot_count": _active_fire_press_shot_count,
		"report_authority": &"press_scoped_second_commit_sustained",
		"single_report_boundary": {
			"generation": _single_report_generation,
			"shot_id": _single_report_shot_id,
			"deadline_seconds": _single_report_deadline,
			"owner": &"retained_component_fire_audio",
			"component_timeout_bound": true,
			"source_stream_path": _single_report_source_path,
			"bounded_stream_duration_seconds": _bounded_single_report_duration,
			"source_identity_policy": &"retained_component_stream_unchanged",
			"adapter_source_substitution_used": false,
			"product_pcm_prefix_derivative_used": false,
		},
		"tester_audio_generation": _tester_audio_generation,
		"last_tester_audio_receipt": _last_tester_audio_receipt,
		"tester_audio_history": _tester_audio_history,
		"last_report_stop_reason": _last_report_stop_reason,
		"last_report_receipt": _last_report_receipt,
		"fire_audio_players": _fire_audio_player_state(),
		"last_run_epoch_receipt": _last_run_epoch_receipt,
		"active_weapon_id": String(_equipped_id),
		"active_profile_id": String(viewmodel.call(&"current_weapon_id")),
		"active_state": String(_action_state),
		"equipped_id": _equipped_id,
		"pending_equipped_id": _pending_equipped_id,
		"action_state": _action_state,
		"reload_kind": _reload_kind,
		"ads": _ads_held,
		"ads_input_authority": &"weapon_controller_raw_input_events",
		"ads_action_down": _observed_ads_down,
		"ads_rearm_required": _ads_rearm_required,
		"ads_edge_count": _ads_edge_serial,
		"last_ads_receipt": _last_ads_receipt,
		"last_shot_spatial": {
			"shot_id": _last_shot.get("shot_id", ""),
			"result": _last_shot.get("result", &"none"),
			"aim_origin": _last_shot.get("aim_origin", Vector3.ZERO),
			"aim_direction": _last_shot.get("aim_direction", Vector3.ZERO),
			"authoritative_aim_endpoint": _last_shot.get("authoritative_aim_endpoint", Vector3.ZERO),
			"authoritative_hit_endpoint": _last_shot.get("authoritative_hit_endpoint", Vector3.ZERO),
			"screen_projection": _last_shot.get("screen_projection", {}),
			"committed_frame": _last_shot.get("committed_frame", -1),
			"committed_at_usec": _last_shot.get("committed_at_usec", -1),
		},
		"viewmodel_requested_aim": _ads_held,
		"viewmodel_aim_flag": viewmodel.get("aiming") == true,
		"viewmodel_settled_aim": _viewmodel_ads_settled,
		"viewmodel_aim_transition_complete": _ads_transition_complete,
		"viewmodel_aim_transition_serial": _ads_transition_serial,
		"viewmodel_position": viewmodel.position,
		"viewmodel_scale": viewmodel.scale,
		"viewmodel_target_position": target_position,
		"viewmodel_target_scale": target_scale,
		"viewmodel_position_error": viewmodel.position.distance_to(target_position),
		# Compatibility alias for bounded Tester report expressions retained from
		# earlier loops. Rotation recovery is measured against the authored product
		# recoil baseline, never by indexing a missing Dictionary field.
		"viewmodel_rotation_error": float(recoil.get("baseline_rotation_error_degrees", 0.0)),
		"recoil_phase": recoil.get("phase", &"unavailable"),
		"recoil_shot_serial": recoil.get("shot_serial", 0),
		"recoil_peak_serial": recoil.get("peak_serial", 0),
		"recoil_current_position_offset": recoil.get("current_position_offset", Vector3.ZERO),
		"recoil_current_rotation_offset_degrees": recoil.get("current_rotation_offset_degrees", Vector3.ZERO),
		"recoil_baseline_position_error": recoil.get("baseline_position_error", 0.0),
		"recoil_baseline_rotation_error_degrees": recoil.get("baseline_rotation_error_degrees", 0.0),
		"recoil_recovery_complete": recoil.get("recovery_complete", true),
		"viewmodel_profile_authority": {
			"owner": viewmodel.get_path(),
			"product_mount_override_present": false,
			"source_axis_untouched": true,
			"profile_resource_untouched": true,
		},
		"fire_mode": weapon["fire_mode"],
		"rounds_per_minute": weapon["rounds_per_minute"],
		"magazine": weapon["magazine"],
		"reserve": weapon["reserve"],
		"ak74m_state": _weapons[&"ak74m"],
		"saiga12_state": _weapons[&"saiga12"],
		"queued_fire_edge_count": _fire_edge_queue.size(),
		"combat_clock_seconds": _combat_clock_seconds,
		"last_input_pump_delta_seconds": _last_input_pump_delta_seconds,
		"fire_edge_authority": &"normalized_raw_input_events",
		"active_fire_source": _active_fire_source,
		"active_fire_press_time_usec": _active_fire_press_time_usec,
		"report_history": _report_history,
		"last_input_receipt": _last_input_receipt,
		"input_history": _input_history,
		"shot_count": _shot_serial,
		"unique_commit_count": _shot_commits.size(),
		"shot_feedback": shot_feedback.snapshot(),
		"last_shot": _last_shot,
		"shot_history": _shot_history,
		"impact_unique_commit_count": _impact_commits.size(),
		"impact_history": _impact_history,
		"camera_origin": camera.global_position,
		"camera_forward": -camera.global_transform.basis.z,
		"muzzle_origin": _muzzle_origin(),
		"optic_origin": camera.global_position,
		"optic_forward": -camera.global_transform.basis.z,
		"viewmodel_direct_camera_child": viewmodel.get_parent() == camera,
		"viewmodel_weapon_id": viewmodel.call(&"current_weapon_id"),
		"viewmodel_clip": viewmodel.get("current_clip"),
		"viewmodel_switching": viewmodel.get("switching"),
		"visible_rig": audit,
		"ready_for_combat": _ready_for_combat,
		"gameplay_input_enabled": gameplay_input_enabled,
		"restore_epoch": _restore_epoch,
		"transient_reset_complete": _transient_reset_complete,
		"last_restore_receipt": _last_restore_receipt,
	}


func _fire_audio_player_state() -> Dictionary:
	var single_player := feedback.get_node_or_null("FireAudio") as AudioStreamPlayer
	var auto_player := feedback.get_node_or_null("AutoFireAudio") as AudioStreamPlayer
	return {
		"single": {
			"path": String(single_player.get_path()) if single_player != null else "",
			"playing": single_player.playing if single_player != null else false,
			"stream_path": single_player.stream.resource_path if single_player != null and single_player.stream != null else "",
			"source_stream_path": _single_report_source_path,
			"playback_stream_class": single_player.stream.get_class() if single_player != null and single_player.stream != null else "",
			"playback_stream_length": single_player.stream.get_length() if single_player != null and single_player.stream != null else 0.0,
			"component_timeout_seconds": _bounded_single_report_duration,
			"component_timeout_method": &"_play_audio_with_timeout",
			"product_output_gate_used": false,
			"retained_stream_unchanged": single_player != null and single_player.stream != null and single_player.stream.resource_path == _single_report_source_path,
			"adapter_source_substitution_used": false,
		},
		"sustained": {
			"path": String(auto_player.get_path()) if auto_player != null else "",
			"playing": auto_player.playing if auto_player != null else false,
			"stream_path": auto_player.stream.resource_path if auto_player != null and auto_player.stream != null else "",
		},
	}


func _player_report_owner_state() -> Dictionary:
	var state := _fire_audio_player_state()
	var single: Dictionary = state.get("single", {})
	var sustained: Dictionary = state.get("sustained", {})
	var active_count := 0
	if single.get("playing", false) == true:
		active_count += 1
	if sustained.get("playing", false) == true:
		active_count += 1
	return {
		"owner_count": 2,
		"active_owner_count": active_count,
		"single": single,
		"sustained": sustained,
		"retained_component_owner": true,
		"product_adapter_report_owner_present": false,
	}
