class_name FusepointTerminalPresentationController
extends Node3D

## Bounded observer of MissionController's immutable terminal event. This node
## never changes countdown, objective, damage, score, or terminal truth.

signal presentation_started(event: Dictionary)
signal presentation_completed(event_id: String, result: StringName)
signal branch_receipt_updated(receipt: Dictionary)

const FAMILY_ID := &"bomb_terminal_sequence"
const SUCCESS_DURATION := 6.2
const FAILURE_DURATION := 5.8
const FAILURE_MEDIA_START := 1.5
const BRANCH_RECEIPT_LIMIT := 4

@export var mission_path: NodePath
@export var player_path: NodePath
@export var weapon_path: NodePath
@export var roster_path: NodePath
@export var bomb_path: NodePath
@export var camera_path: NodePath
@export var damage_feedback_path: NodePath
@export var settings_store_path: NodePath

@onready var mission: Node = get_node(mission_path)
@onready var player: CharacterBody3D = get_node(player_path) as CharacterBody3D
@onready var weapon: Node = get_node(weapon_path)
@onready var roster: Node = get_node(roster_path)
@onready var bomb: Node3D = get_node(bomb_path) as Node3D
@onready var camera: Camera3D = get_node(camera_path) as Camera3D
@onready var damage_feedback: FPSPlayerDamageFeedback = get_node(damage_feedback_path) as FPSPlayerDamageFeedback
@onready var settings_store: Node = get_node(settings_store_path)
@onready var effect_root: Node3D = $EffectRoot
@onready var victory_avatar: EnemyHumanoidActor = $VictoryAvatar
@onready var victory_sequence: VictorySequence = $VictorySequence
@onready var flash_overlay: ColorRect = $TerminalOverlay/Flash
@onready var red_edge: Panel = $TerminalOverlay/RedEdge
@onready var media_layer: Control = $TerminalOverlay/MediaFallback
@onready var media_title: Label = $TerminalOverlay/MediaFallback/Title
@onready var media_copy: Label = $TerminalOverlay/MediaFallback/Copy
@onready var media_skip: Label = $TerminalOverlay/MediaFallback/Skip
@onready var blast_audio: AudioStreamPlayer3D = $BlastAudio
@onready var tail_audio: AudioStreamPlayer3D = $TailAudio

var active := false
var branch := &"none"
var phase := &"idle"
var elapsed_seconds := 0.0
var current_event_id := ""
var world_origin := Vector3.ZERO
var completion_count := 0
var duplicate_event_count := 0
var skip_available := false

var _observed_event_ids: Dictionary = {}
var _effect_nodes: Array[Node] = []
var _completed_current := false
var _expansion_started := false
var _media_started := false
var _flash_tween: Tween
var _edge_tween: Tween
var _tactical_hud: Node
var _applied_reduced_motion := false
var _applied_screen_shake := true
var _restore_epoch := 0
var _active_branch_receipt: Dictionary = {}
var _retained_branch_receipts: Array[Dictionary] = []
var _phase_timestamps: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	mission.mission_event_committed.connect(_on_mission_event)
	_tactical_hud = get_tree().get_first_node_in_group(&"tactical_hud")
	victory_avatar.visible = false
	_clear_overlay()
	# No approved decoded terminal impact source is bound in this candidate.
	# Keep the retained spatial players silent instead of creating oscillator/
	# noise placeholders at runtime.
	blast_audio.stream = null
	tail_audio.stream = null


func _process(delta: float) -> void:
	if not active:
		return
	elapsed_seconds += maxf(delta, 0.0)
	if branch == &"failure":
		_tick_failure()
	else:
		_tick_success()


func _unhandled_input(event: InputEvent) -> void:
	if not active or not skip_available:
		return
	if event.is_action_pressed(&"menu_accept") or event.is_action_pressed(&"interact"):
		_complete_presentation()
		get_viewport().set_input_as_handled()


func _on_mission_event(event: Dictionary) -> void:
	if StringName(event.get("kind", &"")) != &"terminal_submitted":
		return
	var event_id := String(event.get("event_id", ""))
	if event_id.is_empty():
		return
	if _observed_event_ids.has(event_id):
		duplicate_event_count += 1
		return
	_observed_event_ids[event_id] = true
	var payload: Dictionary = event.get("payload", {})
	_start_presentation(event_id, StringName(payload.get("result", &"bomb_detonated")), payload.get("world_origin", bomb.global_position), event)


func _start_presentation(event_id: String, result: StringName, origin: Vector3, event: Dictionary) -> void:
	reset_presentation(false, false)
	active = true
	_completed_current = false
	current_event_id = event_id
	branch = &"success" if result == &"bomb_defused" else &"failure"
	phase = &"native_victory" if branch == &"success" else &"flash_impulse"
	elapsed_seconds = 0.0
	world_origin = origin
	_phase_timestamps.clear()
	_phase_timestamps[phase] = _phase_stamp()
	var payload: Dictionary = event.get("payload", {})
	_active_branch_receipt = {
		"family_id": &"bomb_terminal_effects",
		"run_epoch": int(event.get("run_epoch", mission.get("run_epoch"))),
		"terminal_event_id": event_id,
		"immutable_identity": "run-%06d:%s" % [int(event.get("run_epoch", mission.get("run_epoch"))), event_id],
		"result": result,
		"branch": branch,
		"authority_event": event.duplicate(true),
		"authority_committed_usec": int(event.get("committed_at_usec", Time.get_ticks_usec())),
		"authority_committed_frame": int(event.get("committed_frame", Engine.get_process_frames())),
		"terminal_commit_count": int(mission.get("terminal_commit_count")),
		"terminal_duplicate_submit_count": int(mission.get("terminal_duplicate_submit_count")),
		"health_zero_at_start": float(player.get("health")) <= 0.0,
		"health_at_start": player.get("health"),
		"bomb_state": mission.get("bomb_state"),
		"combat_locks": _combat_lock_snapshot(),
		"result_payload": payload.get("result_snapshot", {}),
		"presentation_started_usec": Time.get_ticks_usec(),
		"presentation_started_frame": Engine.get_process_frames(),
		"phase_timestamps": _phase_timestamps.duplicate(true),
		"effect_layers": [],
		"audio": {},
		"completed": false,
		"presentation_only": true,
		"authoritative_calls": [],
	}
	weapon.call(&"set_gameplay_input_enabled", false)
	roster.process_mode = Node.PROCESS_MODE_DISABLED
	if _tactical_hud != null and _tactical_hud.has_method(&"set_hud_enabled"):
		_tactical_hud.call(&"set_hud_enabled", false)
	var viewmodel := camera.get_node_or_null("FPSViewmodelSwitcher") as Node3D
	if viewmodel != null:
		viewmodel.visible = false
	if branch == &"success":
		_begin_success()
	else:
		_begin_failure()
	_refresh_active_receipt()
	presentation_started.emit(event.duplicate(true))
	branch_receipt_updated.emit(_active_branch_receipt.duplicate(true))


func _begin_success() -> void:
	victory_avatar.global_transform = player.global_transform
	victory_avatar.global_position = _victory_ground_position()
	victory_avatar.visible = true
	media_title.text = "ALL CLEAR — ROCKET BAY PRESERVED"
	media_copy.text = "AEGIS EOD SIGNAL RESTORED\nBASE ALARM CLEARING  •  DEVICE SAFE"
	media_skip.text = "[ENTER / E]  SKIP PRESENTATION"
	if not victory_sequence.begin(camera, victory_avatar, "DEVICE SAFE  •  %02d:%02d REMAINING" % [int(mission.remaining_time) / 60, int(mission.remaining_time) % 60]):
		phase = &"victory_fallback"


func _victory_ground_position() -> Vector3:
	var player_forward := -player.global_basis.z
	player_forward.y = 0.0
	player_forward = player_forward.normalized()
	var stance_position := player.global_position + player_forward * 2.0
	var origin := stance_position + Vector3.UP * 1.0
	var excluded: Array[RID] = []
	if player is CollisionObject3D:
		excluded.append((player as CollisionObject3D).get_rid())
	var query := PhysicsRayQueryParameters3D.create(origin, stance_position - Vector3.UP * 3.0, 0xFFFFFFFF, excluded)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.get("position", stance_position - Vector3.UP * 0.86) if not hit.is_empty() else stance_position - Vector3.UP * 0.86


func _begin_failure() -> void:
	_spawn_explosion_layers(world_origin)
	flash_overlay.color = Color(1.0, 0.96, 0.82, _flash_scale() * 0.92)
	red_edge.modulate = Color(1.0, 1.0, 1.0, _red_scale() * 0.78)
	_flash_tween = create_tween()
	_flash_tween.tween_property(flash_overlay, "color:a", 0.0, 0.12).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_edge_tween = create_tween()
	_edge_tween.tween_property(red_edge, "modulate:a", 0.18 * _red_scale(), 0.65).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_edge_tween.tween_property(red_edge, "modulate:a", 0.0, 0.85)
	blast_audio.global_position = world_origin
	tail_audio.global_position = world_origin
	blast_audio.volume_db = linear_to_db(maxf(0.01, _volume_scale()))
	tail_audio.volume_db = linear_to_db(maxf(0.01, _volume_scale())) - 3.0
	if blast_audio.stream != null:
		blast_audio.play()
	if tail_audio.stream != null:
		tail_audio.play()
	media_title.text = "BASE IMPACT — SIGNAL LOST"
	media_copy.text = "ROCKET MAINTENANCE BAY DESTROYED\nAEGIS TELEMETRY ARCHIVE RECOVERED"
	media_skip.text = "[ENTER / E]  SKIP AFTER IMPACT"


func _tick_failure() -> void:
	if not _expansion_started and elapsed_seconds >= 0.12:
		_expansion_started = true
		_set_phase(&"expansion_camera_down")
	if not _media_started and elapsed_seconds >= FAILURE_MEDIA_START:
		_media_started = true
		_set_phase(&"terminal_media_fallback")
		media_layer.visible = true
		media_layer.modulate.a = 0.0
		create_tween().tween_property(media_layer, "modulate:a", 1.0, 0.42)
		skip_available = true
	if elapsed_seconds >= FAILURE_DURATION:
		_complete_presentation()


func _tick_success() -> void:
	if elapsed_seconds >= 2.8 and not _media_started:
		_media_started = true
		_set_phase(&"victory_media_fallback")
		media_layer.visible = true
		media_layer.modulate.a = 0.0
		create_tween().tween_property(media_layer, "modulate:a", 0.72, 0.55)
		skip_available = true
	if elapsed_seconds >= SUCCESS_DURATION:
		_complete_presentation()


func _complete_presentation() -> void:
	if not active or _completed_current:
		return
	_completed_current = true
	active = false
	_set_phase(&"completed")
	completion_count += 1
	_refresh_active_receipt()
	presentation_completed.emit(current_event_id, &"bomb_defused" if branch == &"success" else &"bomb_detonated")
	call_deferred(&"_retain_active_receipt", &"presentation_completed")


func reset_presentation(clear_event_cache := true, restore_camera := true) -> void:
	if not _active_branch_receipt.is_empty() and _active_branch_receipt.get("completed", false) != true:
		_refresh_active_receipt()
		_active_branch_receipt["reset_before_completion"] = true
		_retain_active_receipt(&"lifecycle_reset")
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	if _edge_tween != null and _edge_tween.is_valid():
		_edge_tween.kill()
	for node: Node in _effect_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_effect_nodes.clear()
	for child: Node in effect_root.get_children():
		child.queue_free()
	blast_audio.stop()
	tail_audio.stop()
	victory_sequence.reset_sequence(restore_camera)
	victory_avatar.visible = false
	if _tactical_hud != null and _tactical_hud.has_method(&"set_hud_enabled"):
		_tactical_hud.call(&"set_hud_enabled", true)
	var viewmodel := camera.get_node_or_null("FPSViewmodelSwitcher") as Node3D
	if viewmodel != null:
		viewmodel.visible = true
	_clear_overlay()
	active = false
	branch = &"none"
	phase = &"idle"
	elapsed_seconds = 0.0
	current_event_id = ""
	world_origin = Vector3.ZERO
	skip_available = false
	_completed_current = false
	_expansion_started = false
	_media_started = false
	if clear_event_cache:
		_observed_event_ids.clear()


func reset_for_restore(epoch: int) -> void:
	_restore_epoch = maxi(_restore_epoch, epoch)
	reset_presentation(true, true)


func apply_accessibility_settings(values: Dictionary) -> void:
	_applied_reduced_motion = values.get("reduced_camera_motion", false) == true
	_applied_screen_shake = values.get("screen_shake", true) == true


func _clear_overlay() -> void:
	flash_overlay.color.a = 0.0
	red_edge.modulate.a = 0.0
	media_layer.visible = false
	media_layer.modulate.a = 1.0


func _spawn_explosion_layers(origin: Vector3) -> void:
	var flash := _mesh_node("FlashCore", _sphere_mesh(0.5, _additive_material(Color(1.0, 0.87, 0.5, 0.96), 11.0)))
	_add_world_layer(flash, origin)
	flash.scale = Vector3.ONE * 0.08
	var flash_tween := flash.create_tween().set_parallel(true)
	flash_tween.tween_property(flash, "scale", Vector3.ONE * 4.8, 0.18).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	flash_tween.tween_property(flash, "transparency", 1.0, 0.26)
	var flash_cleanup := flash.create_tween()
	flash_cleanup.tween_interval(0.28)
	flash_cleanup.tween_callback(flash.queue_free)

	# Overlapping asymmetric lobes read as a turbulent fuel/pressure bloom instead
	# of a diagnostic primitive while retaining a bounded, deterministic lifetime.
	for lobe_index in 7:
		var angle := float(lobe_index) * TAU / 7.0 + 0.17
		var lift := 0.18 + float(lobe_index % 3) * 0.22
		var radial := 0.22 + float(lobe_index % 2) * 0.16
		var lobe_color := Color(1.0, 0.14 + float(lobe_index % 3) * 0.1, 0.012, 0.26)
		var fireball := _mesh_node("FireLobe_%02d" % lobe_index, _sphere_mesh(0.38 + float(lobe_index % 3) * 0.08, _additive_material(lobe_color, 2.1)))
		var start_offset := Vector3(cos(angle) * radial, lift, sin(angle) * radial)
		_add_world_layer(fireball, origin + start_offset)
		fireball.scale = Vector3.ONE * 0.05
		var destination := fireball.global_position + Vector3(cos(angle) * 1.9, 0.72 + float(lobe_index % 2) * 0.48, sin(angle) * 1.9)
		var target_scale := Vector3(1.25 + float(lobe_index % 2) * 0.35, 1.1 + float(lobe_index % 3) * 0.24, 1.25 + float((lobe_index + 1) % 2) * 0.35)
		var fire_tween := fireball.create_tween().set_parallel(true)
		fire_tween.tween_property(fireball, "global_position", destination, 0.72).set_delay(0.1).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		fire_tween.tween_property(fireball, "scale", target_scale, 0.58).set_delay(0.1).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		fire_tween.tween_property(fireball, "transparency", 1.0, 0.95).set_delay(0.35)

	var wave_mesh := CylinderMesh.new()
	wave_mesh.top_radius = 1.0
	wave_mesh.bottom_radius = 1.0
	wave_mesh.height = 0.035
	wave_mesh.radial_segments = 48
	wave_mesh.material = _additive_material(Color(1.0, 0.34, 0.08, 0.12), 1.8)
	var wave := _mesh_node("PressureWave", wave_mesh)
	_add_world_layer(wave, origin + Vector3.UP * 0.08)
	wave.scale = Vector3.ONE * 0.05
	var wave_tween := wave.create_tween().set_parallel(true)
	wave_tween.tween_property(wave, "scale", Vector3(9.0, 1.0, 9.0), 0.72).set_delay(0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	wave_tween.tween_property(wave, "transparency", 1.0, 0.72).set_delay(0.12)

	for spark_index in int(14.0 * _particle_scale()):
		var angle := float(spark_index) * TAU / 14.0
		var direction := Vector3(cos(angle), 0.3 + 0.08 * float(spark_index % 3), sin(angle)).normalized()
		var spark_mesh := BoxMesh.new()
		spark_mesh.size = Vector3(0.025, 0.025, 0.42)
		spark_mesh.material = _additive_material(Color(1.0, 0.68, 0.14, 0.92), 5.0)
		var spark := _mesh_node("Spark_%02d" % spark_index, spark_mesh)
		_add_world_layer(spark, origin + Vector3.UP * 0.32)
		spark.look_at(spark.global_position + direction, Vector3.UP)
		var spark_tween := spark.create_tween().set_parallel(true)
		spark_tween.tween_property(spark, "global_position", spark.global_position + direction * (4.0 + float(spark_index % 4)), 0.58).set_delay(0.12)
		spark_tween.tween_property(spark, "transparency", 1.0, 0.58).set_delay(0.22)

	for debris_index in int(9.0 * _particle_scale()):
		var debris_mesh := BoxMesh.new()
		debris_mesh.size = Vector3(0.08, 0.06, 0.12) * (1.0 + float(debris_index % 3) * 0.25)
		debris_mesh.material = _alpha_material(Color(0.18, 0.14, 0.11, 0.94))
		var debris := _mesh_node("Debris_%02d" % debris_index, debris_mesh)
		_add_world_layer(debris, origin + Vector3.UP * 0.28)
		var angle := float(debris_index) * TAU / 9.0 + 0.21
		var destination := debris.global_position + Vector3(cos(angle) * 3.4, 1.0 + float(debris_index % 3) * 0.35, sin(angle) * 3.4)
		var debris_tween := debris.create_tween().set_parallel(true)
		debris_tween.tween_property(debris, "global_position", destination, 0.62).set_delay(0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		debris_tween.tween_property(debris, "rotation", Vector3(2.5, 3.2, 1.8), 0.72).set_delay(0.14)
		debris_tween.tween_property(debris, "transparency", 1.0, 0.65).set_delay(0.72)

	for dust_index in int(5.0 * _particle_scale()):
		var dust := _mesh_node("Dust_%02d" % dust_index, _sphere_mesh(0.7, _alpha_material(Color(0.25, 0.2, 0.15, 0.28))))
		var angle := float(dust_index) * TAU / 5.0
		_add_world_layer(dust, origin + Vector3(cos(angle), 0.22, sin(angle)) * 0.45)
		dust.scale = Vector3.ONE * 0.2
		var dust_tween := dust.create_tween().set_parallel(true)
		dust_tween.tween_property(dust, "scale", Vector3(5.0, 2.1, 5.0), 1.45).set_delay(0.28)
		dust_tween.tween_property(dust, "transparency", 1.0, 1.15).set_delay(0.72)

	var light := OmniLight3D.new()
	light.name = "ExplosionLight"
	light.light_color = Color(1.0, 0.32, 0.06)
	light.light_energy = 9.0
	light.omni_range = 13.0
	light.shadow_enabled = false
	_add_world_layer(light, origin + Vector3.UP * 0.8)
	var light_tween := light.create_tween()
	light_tween.tween_property(light, "light_energy", 2.4, 0.18)
	light_tween.tween_property(light, "light_energy", 0.0, 1.0)


func _add_world_layer(node: Node3D, position: Vector3) -> void:
	effect_root.add_child(node)
	node.global_position = position
	node.set_meta(&"terminal_event_id", current_event_id)
	node.set_meta(&"spawned_usec", Time.get_ticks_usec())
	node.set_meta(&"spawned_phase", phase)
	node.add_to_group(&"bomb_terminal_sequence")
	_effect_nodes.append(node)


func _mesh_node(node_name: String, mesh: Mesh) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	return node


func _sphere_mesh(radius: float, material: Material) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 18
	mesh.rings = 9
	mesh.material = material
	return mesh


func _additive_material(color: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b)
	material.emission_energy_multiplier = energy
	return material


func _alpha_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.roughness = 0.92
	return material


func _settings() -> Dictionary:
	return settings_store.call(&"snapshot") if settings_store != null and settings_store.has_method(&"snapshot") else {}


func _motion_scale() -> float:
	return 0.35 if _applied_reduced_motion else 1.0


func _flash_scale() -> float:
	return 0.42 if _settings().get("reduced_camera_motion", false) == true else 1.0


func _red_scale() -> float:
	return 0.55 if _settings().get("reduced_camera_motion", false) == true else 1.0


func _particle_scale() -> float:
	return 0.55 if _settings().get("reduced_camera_motion", false) == true else 1.0


func _volume_scale() -> float:
	return float(_settings().get("master_volume", 0.85))


func snapshot() -> Dictionary:
	var victory_state := victory_sequence.snapshot()
	return {
		"family_id": FAMILY_ID,
		"active": active,
		"branch": branch,
		"phase": phase,
		"elapsed_seconds": elapsed_seconds,
		"current_event_id": current_event_id,
		"world_origin": world_origin,
		"health_zero": float(player.get("health")) <= 0.0 if player != null else false,
		"player_terminal_locked": player.get("terminal_locked") if player != null else false,
		"effect_layer_count": _effect_layer_receipts().size(),
		"media_visible": media_layer.visible,
		"skip_available": skip_available,
		"completion_count": completion_count,
		"duplicate_event_count": duplicate_event_count,
		"camera_position": camera.global_position if camera != null else Vector3.ZERO,
		"victory_avatar_visible": victory_avatar.visible,
		"victory_phase": String(victory_state.get("phase", &"idle")),
		"victory_phase_serial": victory_state.get("phase_serial", 0),
		"victory_pullback_weight": victory_state.get("pullback_weight", 0.0),
		"victory_orbit_weight": victory_state.get("orbit_weight", 0.0),
		"victory_camera_transform": victory_state.get("camera_transform", Transform3D.IDENTITY),
		"victory_animation": victory_state.get("avatar_animation", {}),
		"restore_epoch": _restore_epoch,
		"reduced_camera_motion": _applied_reduced_motion,
		"screen_shake_enabled": _applied_screen_shake,
		"active_branch_receipt": _active_branch_receipt.duplicate(true),
		"retained_branch_receipts": _retained_branch_receipts.duplicate(true),
		"retained_branch_receipt_count": _retained_branch_receipts.size(),
		"retained_branch_receipt_limit": BRANCH_RECEIPT_LIMIT,
	}


func _set_phase(next_phase: StringName) -> void:
	if phase == next_phase:
		return
	phase = next_phase
	_phase_timestamps[next_phase] = _phase_stamp()
	_refresh_active_receipt()
	if not _active_branch_receipt.is_empty():
		branch_receipt_updated.emit(_active_branch_receipt.duplicate(true))


func _phase_stamp() -> Dictionary:
	return {
		"elapsed_seconds": elapsed_seconds,
		"observed_usec": Time.get_ticks_usec(),
		"observed_frame": Engine.get_process_frames(),
	}


func _combat_lock_snapshot() -> Dictionary:
	return {
		"player_terminal_locked": player.get("terminal_locked") if player != null else false,
		"player_gameplay_input_enabled": player.get("gameplay_input_enabled") if player != null else true,
		"player_collision_layer": player.collision_layer if player != null else -1,
		"weapon_gameplay_input_enabled": weapon.get("gameplay_input_enabled") if weapon != null else true,
		"enemy_process_mode": roster.process_mode if roster != null else -1,
	}


func _effect_layer_receipts() -> Array[Dictionary]:
	var layers: Array[Dictionary] = []
	for node: Node in _effect_nodes:
		if not is_instance_valid(node):
			continue
		layers.append({
			"name": node.name,
			"spawned_usec": int(node.get_meta(&"spawned_usec", 0)),
			"spawned_phase": StringName(node.get_meta(&"spawned_phase", &"unknown")),
			"world_origin": (node as Node3D).global_position if node is Node3D else Vector3.ZERO,
			"visible": (node as Node3D).visible if node is Node3D else true,
			"cleanup_pending": true,
		})
	return layers


func _refresh_active_receipt() -> void:
	if _active_branch_receipt.is_empty():
		return
	_active_branch_receipt["phase"] = phase
	_active_branch_receipt["elapsed_seconds"] = elapsed_seconds
	_active_branch_receipt["phase_timestamps"] = _phase_timestamps.duplicate(true)
	_active_branch_receipt["health_zero"] = float(player.get("health")) <= 0.0 if player != null else false
	_active_branch_receipt["health"] = player.get("health") if player != null else -1
	_active_branch_receipt["combat_locks"] = _combat_lock_snapshot()
	_active_branch_receipt["effect_layers"] = _effect_layer_receipts()
	_active_branch_receipt["effect_layer_count"] = (_active_branch_receipt["effect_layers"] as Array).size()
	_active_branch_receipt["audio"] = {
		"blast": {"bus": blast_audio.bus, "playing": blast_audio.playing, "stream_bound": blast_audio.stream != null, "spatial": true, "unit_size": blast_audio.unit_size, "max_distance": blast_audio.max_distance},
		"tail": {"bus": tail_audio.bus, "playing": tail_audio.playing, "stream_bound": tail_audio.stream != null, "spatial": true, "unit_size": tail_audio.unit_size, "max_distance": tail_audio.max_distance},
	}
	_active_branch_receipt["camera"] = {
		"position": camera.global_position if camera != null else Vector3.ZERO,
		"victory": victory_sequence.snapshot(),
	}
	_active_branch_receipt["media"] = {"visible": media_layer.visible, "skip_available": skip_available, "fallback": true}
	_active_branch_receipt["duplicate_event_count"] = duplicate_event_count
	_active_branch_receipt["completion_count"] = completion_count


func _retain_active_receipt(reason: StringName) -> void:
	if _active_branch_receipt.is_empty():
		return
	_refresh_active_receipt()
	var shell := get_tree().get_first_node_in_group(&"product_shell")
	var shell_state: Dictionary = shell.call(&"_mcp_state") if shell != null and shell.has_method(&"_mcp_state") else {}
	_active_branch_receipt["completed"] = reason == &"presentation_completed"
	_active_branch_receipt["retained_reason"] = reason
	_active_branch_receipt["retained_usec"] = Time.get_ticks_usec()
	_active_branch_receipt["result_transition"] = {
		"app_state": shell_state.get("app_state", &"unknown"),
		"result_entry_count": shell_state.get("result_entry_count", 0),
		"observed_terminal_results": shell_state.get("observed_terminal_results", {}),
		"focused_control": shell_state.get("focused_control", ""),
		"actions": [&"replay", &"home"],
	}
	_active_branch_receipt["cleanup"] = {
		"live_effect_count": _effect_layer_receipts().size(),
		"blast_playing": blast_audio.playing,
		"tail_playing": tail_audio.playing,
	}
	_retained_branch_receipts.append(_active_branch_receipt.duplicate(true))
	while _retained_branch_receipts.size() > BRANCH_RECEIPT_LIMIT:
		_retained_branch_receipts.pop_front()
	_cleanup_completed_presentation()
	_retained_branch_receipts[_retained_branch_receipts.size() - 1]["cleanup_after_result"] = {
		"live_effect_count": 0,
		"blast_playing": blast_audio.playing,
		"tail_playing": tail_audio.playing,
		"media_visible": media_layer.visible,
		"victory_avatar_visible": victory_avatar.visible,
		"observed_usec": Time.get_ticks_usec(),
	}
	branch_receipt_updated.emit((_retained_branch_receipts[_retained_branch_receipts.size() - 1] as Dictionary).duplicate(true))
	_active_branch_receipt.clear()


func _cleanup_completed_presentation() -> void:
	for node: Node in _effect_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_effect_nodes.clear()
	for child: Node in effect_root.get_children():
		child.queue_free()
	blast_audio.stop()
	tail_audio.stop()
	victory_sequence.reset_sequence(true)
	victory_avatar.visible = false
	_clear_overlay()


func _mcp_state() -> Dictionary:
	var state := snapshot()
	return {
		"family_id": FAMILY_ID,
		"active": active,
		"branch": branch,
		"phase": phase,
		"elapsed_seconds": elapsed_seconds,
		"current_event_id": current_event_id,
		"completion_count": completion_count,
		"duplicate_event_count": duplicate_event_count,
		"effect_layer_count": _effect_layer_receipts().size(),
		"health_zero": state.get("health_zero", false),
		"player_terminal_locked": state.get("player_terminal_locked", false),
		"media_visible": media_layer.visible,
		"skip_available": skip_available,
		"active_branch_receipt": _active_branch_receipt.duplicate(true),
		"retained_branch_receipt_count": _retained_branch_receipts.size(),
		"retained_branch_receipts": _retained_branch_receipts.duplicate(true),
		"restore_epoch": _restore_epoch,
	}
