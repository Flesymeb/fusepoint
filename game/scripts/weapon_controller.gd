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
var _fire_action_down := false
var _active_fire_source := &"none"
var _input_edge_serial := 0
var _last_input_receipt: Dictionary = {}
var _input_history: Array[Dictionary] = []


func _ready() -> void:
	_weapons = _fresh_weapon_data()
	viewmodel.set("handle_right_mouse", false)
	viewmodel.set("handle_mouse_wheel", false)
	if viewmodel.has_signal(&"weapon_changed"):
		viewmodel.connect(&"weapon_changed", _on_viewmodel_weapon_changed)
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.has_signal(&"spawn_reset"):
		player.connect(&"spawn_reset", _on_spawn_reset)
	call_deferred(&"_finish_ready")


func _finish_ready() -> void:
	await get_tree().process_frame
	_ready_for_combat = true
	_fire_action_down = Input.is_action_pressed(&"fire")
	_sync_hud()
	weapon_state_changed.emit(_mcp_state())


func _input(event: InputEvent) -> void:
	# Gameplay fire is consumed before GUI and unhandled-input routing. Polling in
	# _process mirrors the same latch so analog actions and injected InputMap
	# actions cannot be starved, while this raw path preserves an immediate edge.
	if not _ready_for_combat or not gameplay_input_enabled:
		return
	if event.is_action_pressed(&"fire"):
		_consume_fire_edge(true, _input_source_for(event))
	elif event.is_action_released(&"fire"):
		_consume_fire_edge(false, _input_source_for(event))


func _unhandled_input(event: InputEvent) -> void:
	if not _ready_for_combat or not gameplay_input_enabled:
		return
	if event.is_action_pressed(&"ads"):
		_set_ads(true)
	elif event.is_action_released(&"ads"):
		_set_ads(false)
	elif event.is_action_pressed(&"reload"):
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


func _process(_delta: float) -> void:
	if not _ready_for_combat:
		return
	if not gameplay_input_enabled:
		_sync_hud()
		return
	_poll_fire_action()
	var now := _now()
	if _trigger_held and _current_weapon()["fire_mode"] == FIRE_MODE_AUTO and now >= _next_shot_time:
		_try_submit_shot()
		_next_shot_time = now + _fire_interval()
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
	_sync_movement_feedback()
	_sync_hud()


func _poll_fire_action() -> void:
	var pressed := Input.is_action_pressed(&"fire")
	if pressed != _fire_action_down:
		_consume_fire_edge(pressed, _polled_fire_source())


func _consume_fire_edge(pressed: bool, source: StringName) -> void:
	if pressed == _fire_action_down:
		return
	_fire_action_down = pressed
	if pressed:
		_begin_fire(source)
	else:
		_end_fire(source)


func _begin_fire(source := &"action_poll") -> void:
	var magazine_before := int(_current_weapon()["magazine"])
	if not _can_fire():
		_record_input_edge(source, &"press", false, _fire_rejection_reason(), "", magazine_before, magazine_before)
		return
	_trigger_held = true
	_active_fire_source = source
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
	)


func _end_fire(source := &"action_poll", cancellation_reason := "release") -> void:
	var was_held := _trigger_held
	_trigger_held = false
	if feedback.has_method(&"end_fire"):
		feedback.call(&"end_fire")
	if cancellation_reason == "release":
		var magazine := int(_current_weapon()["magazine"])
		_record_input_edge(source, &"release", was_held or _fire_action_down == false, "released", "", magazine, magazine)
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
	_last_shot = receipt
	_shot_history.append(receipt.duplicate(true))
	if _shot_history.size() > 24:
		_shot_history.pop_front()
	_action_state = &"fire"
	_action_until = _now() + 0.07
	_recovery_until = _now() + float(weapon["recovery_seconds"])
	feedback.call(&"trigger_fire", weapon["fire_mode"] == FIRE_MODE_AUTO)
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
	viewmodel.call(&"play_clip", &"idle")
	weapon_state_changed.emit(_mcp_state())


func _set_ads(enabled: bool) -> void:
	_ads_held = enabled
	if _action_state in [&"reload", &"switch", &"inspect"]:
		return
	viewmodel.call(&"set_aiming", enabled)
	_action_state = &"ads" if enabled else &"hip"
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
	_equipped_id = weapon_id
	_pending_equipped_id = &""
	_action_state = &"hip"
	_ads_held = false
	weapon_state_changed.emit(_mcp_state())


func _begin_inspect() -> void:
	if _action_state not in [&"hip", &"ads"]:
		return
	_cancel_action(&"inspect")
	_action_state = &"inspect"
	_action_until = _now() + 1.35
	viewmodel.call(&"set_aiming", false, true)
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
	viewmodel.call(&"set_aiming", _ads_held, true)
	viewmodel.call(&"play_clip", &"idle")
	_action_state = &"ads" if _ads_held else &"hip"
	weapon_state_changed.emit(_mcp_state())


func _cancel_action(next_state: StringName) -> void:
	_cancel_held_fire(String(next_state))
	_reload_kind = &"none"
	if _inspect_tween != null and _inspect_tween.is_valid():
		_inspect_tween.kill()
	viewmodel.rotation_degrees = Vector3.ZERO
	viewmodel.call(&"set_aiming", false, true)
	_action_state = next_state


func _on_spawn_reset() -> void:
	_cancel_action(&"hip")
	_weapons = _fresh_weapon_data()
	_equipped_id = &"ak74m"
	_pending_equipped_id = &""
	_ads_held = false
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


func _current_weapon() -> Dictionary:
	return _weapons[_equipped_id]


func set_gameplay_input_enabled(enabled: bool) -> void:
	gameplay_input_enabled = enabled
	if not enabled:
		_cancel_held_fire("gameplay_disabled")
		_ads_held = false
		_cancel_action(&"idle")
	elif _action_state == &"idle":
		_action_state = &"hip"
		viewmodel.call(&"set_aiming", false, true)
	# Latch the physical level on every handoff. A trigger held across a page,
	# pause, death, or restore must be released before it can create a new edge.
	_fire_action_down = Input.is_action_pressed(&"fire")


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
	_spawn_impact(event)
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


func restore_weapon_state(snapshot: Dictionary) -> void:
	var serial_before := _shot_serial
	var shot_commits_before := _shot_commits.duplicate(true)
	var shot_history_before := _shot_history.duplicate(true)
	var last_shot_before := _last_shot.duplicate(true)
	var impact_commits_before := _impact_commits.duplicate(true)
	var impact_history_before := _impact_history.duplicate(true)
	_cancel_action(&"hip")
	_weapons = snapshot.get("weapons", _fresh_weapon_data()).duplicate(true)
	_equipped_id = StringName(snapshot.get("equipped_id", &"ak74m"))
	_pending_equipped_id = &""
	_ads_held = false
	_shot_serial = maxi(serial_before, int(snapshot.get("shot_serial", 0)))
	_shot_commits = shot_commits_before
	_shot_history.assign(shot_history_before)
	_last_shot = last_shot_before
	_impact_commits = impact_commits_before
	_impact_history.assign(impact_history_before)
	_clear_live_impacts()
	viewmodel.call(&"equip_weapon_id", _equipped_id, true)
	weapon_state_changed.emit(_mcp_state())


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
	return Time.get_ticks_msec() / 1000.0


func _input_source_for(event: InputEvent) -> StringName:
	if event is InputEventMouseButton:
		return &"mouse_left"
	if event is InputEventJoypadMotion:
		return &"gamepad_trigger"
	if event is InputEventJoypadButton:
		return &"gamepad_button"
	return &"mapped_action"


func _polled_fire_source() -> StringName:
	return &"gamepad_trigger" if Input.get_action_strength(&"fire") > 0.3 and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) else &"mouse_left"


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
	if feedback.has_method(&"end_fire"):
		feedback.call(&"end_fire")


func _record_input_edge(
	source: StringName,
	edge: StringName,
	accepted: bool,
	reason: String,
	shot_id: String,
	magazine_before: int,
	magazine_after: int,
	cancellation_reason := "",
) -> void:
	_input_edge_serial += 1
	_last_input_receipt = {
		"edge_id": "fire-input-%06d" % _input_edge_serial,
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
	return {
		"equipped_id": _equipped_id,
		"pending_equipped_id": _pending_equipped_id,
		"action_state": _action_state,
		"reload_kind": _reload_kind,
		"ads": _ads_held,
		"fire_mode": weapon["fire_mode"],
		"rounds_per_minute": weapon["rounds_per_minute"],
		"magazine": weapon["magazine"],
		"reserve": weapon["reserve"],
		"ak74m_state": _weapons[&"ak74m"],
		"saiga12_state": _weapons[&"saiga12"],
		"trigger_held": _trigger_held,
		"fire_action_down": _fire_action_down,
		"active_fire_source": _active_fire_source,
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
	}
