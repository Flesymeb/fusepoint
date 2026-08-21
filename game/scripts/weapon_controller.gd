class_name FusepointWeaponController
extends Node

signal shot_resolved(receipt: Dictionary)
signal weapon_state_changed(state: Dictionary)

const WEAPON_ORDER: Array[StringName] = [&"ak74m", &"saiga12"]
const FIRE_MODE_SEMI := &"SEMI"
const FIRE_MODE_AUTO := &"AUTO"
const READY_STATES: Array[StringName] = [&"hip", &"ads", &"fire", &"recoil"]

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
var _input_edge_serial := 0
var _last_input_receipt: Dictionary = {}
var _input_history: Array[Dictionary] = []
var _combat_clock_seconds := 0.0
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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_weapons = _fresh_weapon_data()
	viewmodel.set("handle_right_mouse", false)
	viewmodel.set("handle_mouse_wheel", false)
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


func _process(_delta: float) -> void:
	if not _ready_for_combat:
		return
	_drain_fire_edges()
	if not gameplay_input_enabled:
		_sync_hud()
		return
	var now := _now()
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
	# AUTO cadence is evaluated once after the render-frame input pump. A raw
	# release queued for this frame therefore cancels before a repeat can commit,
	# even when several physics ticks occurred between rendered frames.
	var scheduled_shots := 0
	while _trigger_held and not _active_fire_press_edge_id.is_empty() and _current_weapon()["fire_mode"] == FIRE_MODE_AUTO and _now() >= _next_shot_time and scheduled_shots < 8:
		if _try_submit_shot().is_empty():
			break
		_next_shot_time += _fire_interval()
		scheduled_shots += 1
	_sync_movement_feedback()
	_sync_hud()


func _physics_process(delta: float) -> void:
	if not _ready_for_combat:
		return
	if gameplay_input_enabled:
		_combat_clock_seconds += maxf(delta, 0.0)
	_drain_fire_edges()
	if not gameplay_input_enabled:
		return


func _observe_fire_transition(pressed: bool, source: StringName, captured_at_usec := 0) -> void:
	if pressed == _observed_fire_down:
		return
	_observed_fire_down = pressed
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
	_trigger_held = false
	_active_fire_press_edge_id = ""
	_active_fire_press_time_usec = 0
	if feedback.has_method(&"end_fire"):
		feedback.call(&"end_fire")
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
	var shot_id := "%s-%06d" % [String(_equipped_id), _shot_serial]
	if _shot_commits.has(shot_id):
		return {}
	_shot_commits[shot_id] = true
	weapon["magazine"] = int(weapon["magazine"]) - 1
	_weapons[_equipped_id] = weapon
	var receipt := _resolve_ballistics(shot_id, weapon)
	_dispatch_impact_receipt(receipt)
	shot_feedback.show_shot(receipt)
	_last_shot = receipt
	_shot_history.append(receipt.duplicate(true))
	if _shot_history.size() > 24:
		_shot_history.pop_front()
	_action_state = &"fire"
	_action_until = _now() + 0.07
	_recovery_until = _now() + float(weapon["recovery_seconds"])
	feedback.call(&"trigger_fire", weapon["fire_mode"] == FIRE_MODE_AUTO)
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
	return {
		"shot_id": shot_id,
		"weapon_id": _equipped_id,
		"timestamp_seconds": _now(),
		"camera_origin": camera_origin,
		"muzzle_origin": muzzle_origin,
		"direction": muzzle_direction,
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
	viewmodel.call(&"play_clip", &"empty_reload" if _reload_kind == &"empty" else &"reload_variant")
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
	_capture_product_recoil_baseline(true)
	_equipped_id = weapon_id
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
	if feedback.has_method(&"stop_feedback"):
		feedback.call(&"stop_feedback")
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
	if feedback.has_method(&"_stop_fire_recoil"):
		feedback.call(&"_stop_fire_recoil")
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
		-float(feedback.get("fire_recoil_back_distance")) * kick_scale,
	)
	var kick_rotation := _product_recoil_baseline_rotation_degrees + Vector3(
		-float(feedback.get("fire_recoil_pitch_degrees")) * kick_scale,
		(randf() * 2.0 - 1.0) * float(feedback.get("fire_recoil_yaw_degrees")) * kick_scale,
		(randf() * 2.0 - 1.0) * float(feedback.get("fire_recoil_roll_degrees")) * kick_scale,
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
		float(feedback.get("fire_recoil_out_seconds")),
	)
	_product_recoil_tween.tween_callback(_mark_product_recoil_peak)
	_product_recoil_tween.tween_interval(float(feedback.get("fire_recoil_hold_seconds")))
	_product_recoil_tween.tween_callback(_mark_product_recoil_recovery)
	_product_recoil_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_product_recoil_tween.tween_method(
		_apply_product_recoil_pose.bind(mount, kick_position, kick_rotation, _product_recoil_baseline_position, _product_recoil_baseline_rotation_degrees),
		0.0,
		1.0,
		float(feedback.get("fire_recoil_return_seconds")),
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
	_equip_weapon(weapon_id)
	return true


func _sync_movement_feedback() -> void:
	if _action_state in [&"reload", &"switch", &"inspect", &"fire"]:
		return
	var player := get_tree().get_first_node_in_group(&"player") as CharacterBody3D
	if player == null:
		return
	var speed := Vector2(player.velocity.x, player.velocity.z).length()
	if speed > 5.5:
		feedback.call(&"start_run")
	elif speed > 0.3:
		feedback.call(&"start_walk")
	else:
		feedback.call(&"stop_movement")


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
	_cancel_queued_fire_edges("checkpoint_restore")
	_cancel_held_fire("checkpoint_restore")
	_observed_fire_down = false
	_fire_rearm_required = false
	_active_fire_source = &"none"
	_active_fire_press_edge_id = ""
	_active_fire_press_time_usec = 0
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


func _visible_rig_audit() -> Dictionary:
	var mesh_paths: Array[String] = []
	var skeleton_paths: Array[String] = []
	var animation_players: Array[String] = []
	var socket_bones: Array[String] = []
	_audit_descendants(viewmodel, mesh_paths, skeleton_paths, animation_players, socket_bones)
	return {
		"mesh_paths": mesh_paths,
		"skeleton_paths": skeleton_paths,
		"animation_players": animation_players,
		"socket_bones": socket_bones,
		"mesh_count": mesh_paths.size(),
		"skeleton_count": skeleton_paths.size(),
		"animation_player_count": animation_players.size(),
	}


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
	if not _trigger_held and _active_fire_source == &"none":
		return
	var magazine := int(_current_weapon()["magazine"])
	_record_input_edge(_active_fire_source, &"cancel", false, "cancelled", "", magazine, magazine, reason)
	_trigger_held = false
	_active_fire_source = &"none"
	_active_fire_press_edge_id = ""
	_active_fire_press_time_usec = 0
	if feedback.has_method(&"end_fire"):
		feedback.call(&"end_fire")


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
		"recoil_phase": recoil.get("phase", &"unavailable"),
		"recoil_shot_serial": recoil.get("shot_serial", 0),
		"recoil_peak_serial": recoil.get("peak_serial", 0),
		"recoil_current_position_offset": recoil.get("current_position_offset", Vector3.ZERO),
		"recoil_current_rotation_offset_degrees": recoil.get("current_rotation_offset_degrees", Vector3.ZERO),
		"recoil_baseline_position_error": recoil.get("baseline_position_error", 0.0),
		"recoil_baseline_rotation_error_degrees": recoil.get("baseline_rotation_error_degrees", 0.0),
		"recoil_recovery_complete": recoil.get("recovery_complete", true),
		"fire_mode": weapon["fire_mode"],
		"rounds_per_minute": weapon["rounds_per_minute"],
		"magazine": weapon["magazine"],
		"reserve": weapon["reserve"],
		"ak74m_state": _weapons[&"ak74m"],
		"saiga12_state": _weapons[&"saiga12"],
		"trigger_held": _trigger_held,
		"fire_action_down": _observed_fire_down,
		"fire_rearm_required": _fire_rearm_required,
		"queued_fire_edge_count": _fire_edge_queue.size(),
		"combat_clock_seconds": _combat_clock_seconds,
		"fire_edge_authority": &"normalized_raw_input_events",
		"active_fire_source": _active_fire_source,
		"active_fire_press_edge_id": _active_fire_press_edge_id,
		"active_fire_press_time_usec": _active_fire_press_time_usec,
		"last_input_receipt": _last_input_receipt,
		"input_history": _input_history,
		"shot_count": _shot_serial,
		"unique_commit_count": _shot_commits.size(),
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
