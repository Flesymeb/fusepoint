class_name FusepointTerminalPresentationController
extends Node3D

## Bounded observer of MissionController's immutable terminal event. This node
## never changes countdown, objective, damage, score, or terminal truth.

signal presentation_started(event: Dictionary)
signal presentation_completed(event_id: String, result: StringName)
signal branch_receipt_updated(receipt: Dictionary)

const FAMILY_ID := &"bomb_terminal_sequence"
const SUCCESS_DURATION := 6.2
const FAILURE_MEDIA_START := 1.5
const FAILURE_FALLBACK_DURATION := 6.8
const BRANCH_RECEIPT_LIMIT := 4
const DETONATION_EFFECT_SCENE := preload("res://scenes/bomb_terminal_effect.tscn")
const CAMERA_EFFECT_DISTANCE := 3.8
const PROJECTION_MARGIN := 72.0
const DEATH_VIDEO_PATH := "res://assets/cinematics/fusepoint_bomb_death.ogv"
const DEATH_VIDEO_SHA256 := "4769ef6fa5bd45a78f5ca1d8a9d6fcf1b5381ee7fbc180a2aef8b3a8b5b84c4a"
const DEATH_VIDEO_SOURCE_SHA256 := "5572ff028041ee3d805bb9d9a6d870b9b8dbaeae11aadc9bd8bb413e811c289f"
const DEATH_VIDEO_RECEIPT_PATH := "res://assets/cinematics/fusepoint_bomb_death.receipt.json"

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
@onready var death_video: VideoStreamPlayer = $TerminalOverlay/DeathVideo
@onready var media_layer: Control = $TerminalOverlay/MediaFallback
@onready var media_treatment: ColorRect = $TerminalOverlay/MediaFallback/Treatment
@onready var media_top_rail: ColorRect = $TerminalOverlay/MediaFallback/TopRail
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
var presentation_origin := Vector3.ZERO
var projection_rebound := false
var projection_rebound_reason := &"none"
var completion_count := 0
var duplicate_event_count := 0
var skip_available := false

var _observed_event_ids: Dictionary = {}
var _effect_nodes: Array[Node] = []
var _completed_current := false
var _expansion_started := false
var _debris_started := false
var _dust_started := false
var _media_started := false
var _flash_tween: Tween
var _edge_tween: Tween
var _camera_tween: Tween
var _tactical_hud: Node
var _applied_reduced_motion := false
var _applied_screen_shake := true
var _restore_epoch := 0
var _active_branch_receipt: Dictionary = {}
var _retained_branch_receipts: Array[Dictionary] = []
var _phase_timestamps: Dictionary = {}
var _failure_camera_position := Vector3.ZERO
var _failure_camera_rotation := Vector3.ZERO
var _failure_camera_bound := false
var _camera_fall_distance := 0.0
var _camera_fall_tilt_degrees := Vector3.ZERO
var _video_play_requested := false
var _video_started := false
var _video_failed := false
var _video_finished := false
var _video_completion_reason := &"none"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	mission.mission_event_committed.connect(_on_mission_event)
	_tactical_hud = get_tree().get_first_node_in_group(&"tactical_hud")
	victory_avatar.visible = false
	death_video.finished.connect(_on_death_video_finished)
	_clear_overlay()


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
		_complete_presentation(&"media_skipped")
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
	var projection_binding := _resolve_presentation_origin(origin)
	presentation_origin = projection_binding.get("presentation_origin", origin)
	projection_rebound = projection_binding.get("rebound", false)
	projection_rebound_reason = StringName(projection_binding.get("reason", &"none"))
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
		"authoritative_world_origin": world_origin,
		"presentation_origin": presentation_origin,
		"projection_binding": projection_binding,
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
	_bind_failure_camera()
	flash_overlay.color = Color(1.0, 0.92, 0.68, _flash_scale() * 0.72)
	red_edge.modulate = Color(1.0, 1.0, 1.0, _red_scale() * 0.36)
	_flash_tween = create_tween()
	_flash_tween.tween_property(flash_overlay, "color:a", _flash_scale() * 0.2, 0.12).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_flash_tween.tween_property(flash_overlay, "color:a", 0.0, 0.38).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_edge_tween = create_tween()
	_edge_tween.tween_property(red_edge, "modulate:a", 0.12 * _red_scale(), 0.65).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_edge_tween.tween_property(red_edge, "modulate:a", 0.0, 0.85)
	blast_audio.global_position = world_origin
	tail_audio.global_position = world_origin
	blast_audio.volume_db = -1.5 + linear_to_db(maxf(0.01, _volume_scale()))
	tail_audio.volume_db = -5.0 + linear_to_db(maxf(0.01, _volume_scale()))
	if blast_audio.stream != null:
		blast_audio.play()
	if tail_audio.stream != null:
		tail_audio.play()
	media_title.text = "BASE IMPACT — SIGNAL LOST"
	media_copy.text = "ROCKET MAINTENANCE BAY DESTROYED\nAEGIS TELEMETRY ARCHIVE RECOVERED"
	media_skip.text = "[ENTER / E]  SKIP AFTER IMPACT"


func _bind_failure_camera() -> void:
	if camera == null:
		return
	_failure_camera_position = camera.position
	_failure_camera_rotation = camera.rotation
	_failure_camera_bound = true
	var motion_scale := _motion_scale()
	var impulse_scale := motion_scale if _applied_screen_shake else 0.0
	var impulse_position := _failure_camera_position + Vector3(0.035, -0.025, 0.025) * impulse_scale
	var impulse_rotation := _failure_camera_rotation + Vector3(
		deg_to_rad(2.2), deg_to_rad(-1.2), deg_to_rad(3.2)
	) * impulse_scale
	_camera_fall_distance = 0.36 * motion_scale
	_camera_fall_tilt_degrees = Vector3(8.0, 0.0, 5.5) * motion_scale
	var fall_position := _failure_camera_position + Vector3(0.0, -_camera_fall_distance, 0.035 * motion_scale)
	var fall_rotation := _failure_camera_rotation + Vector3(
		deg_to_rad(_camera_fall_tilt_degrees.x),
		0.0,
		deg_to_rad(_camera_fall_tilt_degrees.z)
	)
	_camera_tween = create_tween()
	_camera_tween.tween_property(camera, "position", impulse_position, 0.08).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_camera_tween.parallel().tween_property(camera, "rotation", impulse_rotation, 0.08).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	_camera_tween.tween_property(camera, "position", fall_position, 0.48).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_camera_tween.parallel().tween_property(camera, "rotation", fall_rotation, 0.48).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _restore_failure_camera() -> void:
	if _camera_tween != null and _camera_tween.is_valid():
		_camera_tween.kill()
	if _failure_camera_bound and camera != null:
		camera.position = _failure_camera_position
		camera.rotation = _failure_camera_rotation
	_failure_camera_bound = false
	_camera_fall_distance = 0.0
	_camera_fall_tilt_degrees = Vector3.ZERO


func _begin_death_video() -> void:
	if death_video.stream == null:
		_begin_video_fallback(&"stream_missing")
		return
	_set_phase(&"terminal_death_video")
	# The world stack has completed its 0–1.5 s role. Hide its remaining one-shot
	# particles before the decoder fade so a near-camera dust mote cannot contaminate
	# the full-bleed cinematic entry frame.
	for effect_node: Node in _effect_nodes:
		if is_instance_valid(effect_node) and effect_node is Node3D:
			(effect_node as Node3D).visible = false
	_video_play_requested = true
	death_video.visible = true
	death_video.modulate.a = 0.0
	death_video.paused = false
	death_video.play()
	media_layer.visible = true
	media_layer.modulate.a = 1.0
	media_treatment.visible = false
	media_top_rail.visible = false
	media_title.visible = false
	media_copy.visible = false
	media_skip.visible = true
	media_skip.text = "[ENTER / E]  SKIP CINEMATIC"
	skip_available = true
	create_tween().tween_property(death_video, "modulate:a", 1.0, 0.32)


func _begin_video_fallback(reason: StringName) -> void:
	_video_failed = true
	_video_completion_reason = reason
	death_video.stop()
	death_video.visible = false
	_set_phase(&"terminal_media_fallback")
	media_layer.visible = true
	media_layer.modulate.a = 0.0
	media_treatment.visible = true
	media_top_rail.visible = true
	media_title.visible = true
	media_copy.visible = true
	media_skip.visible = true
	media_skip.text = "[ENTER / E]  CONTINUE"
	skip_available = true
	create_tween().tween_property(media_layer, "modulate:a", 1.0, 0.32)


func _on_death_video_finished() -> void:
	if not active or branch != &"failure" or not _video_play_requested:
		return
	_video_finished = true
	_complete_presentation(&"video_finished")


func _tick_failure() -> void:
	if not _expansion_started and elapsed_seconds >= 0.18:
		_expansion_started = true
		_set_phase(&"fire_sparks_expansion")
	if not _debris_started and elapsed_seconds >= 0.52:
		_debris_started = true
		_set_phase(&"debris_pressure_wave")
	if not _dust_started and elapsed_seconds >= 0.96:
		_dust_started = true
		_set_phase(&"dust_camera_down")
	if not _media_started and elapsed_seconds >= FAILURE_MEDIA_START:
		_media_started = true
		_begin_death_video()
	if _video_play_requested and not _video_started and not _video_failed:
		if death_video.is_playing():
			_video_started = true
			_refresh_active_receipt()
		elif elapsed_seconds >= FAILURE_MEDIA_START + 0.75:
			_begin_video_fallback(&"playback_did_not_start")
	if _video_failed and elapsed_seconds >= FAILURE_FALLBACK_DURATION:
		_complete_presentation(&"fallback_completed")


func _tick_success() -> void:
	if elapsed_seconds >= 2.8 and not _media_started:
		_media_started = true
		_set_phase(&"victory_media_fallback")
		media_layer.visible = true
		media_layer.modulate.a = 0.0
		create_tween().tween_property(media_layer, "modulate:a", 0.72, 0.55)
		skip_available = true
	if elapsed_seconds >= SUCCESS_DURATION:
		_complete_presentation(&"success_duration_completed")


func _complete_presentation(reason: StringName = &"presentation_completed") -> void:
	if not active or _completed_current:
		return
	_completed_current = true
	_video_completion_reason = reason
	active = false
	_set_phase(&"completed")
	completion_count += 1
	_refresh_active_receipt()
	presentation_completed.emit(current_event_id, &"bomb_defused" if branch == &"success" else &"bomb_detonated")
	call_deferred(&"_retain_active_receipt", &"presentation_completed")


func tester_complete_active_presentation() -> Dictionary:
	var receipt := {
		"requested": true,
		"resolved": false,
		"accepted": false,
		"non_release": OS.is_debug_build(),
		"event_id": current_event_id,
		"branch": branch,
	}
	if not OS.is_debug_build():
		receipt["failure_reason"] = &"release_build_forbidden"
		return receipt
	if not active or _completed_current or current_event_id.is_empty():
		receipt["failure_reason"] = &"terminal_presentation_not_active"
		return receipt
	_complete_presentation(&"tester_branch_inspection")
	receipt["resolved"] = true
	receipt["accepted"] = _completed_current
	receipt["completion_reason"] = &"tester_branch_inspection"
	receipt["failure_reason"] = &"" if _completed_current else &"completion_rejected"
	return receipt


func reset_presentation(clear_event_cache := true, restore_camera := true) -> void:
	if not _active_branch_receipt.is_empty() and _active_branch_receipt.get("completed", false) != true:
		_refresh_active_receipt()
		_active_branch_receipt["reset_before_completion"] = true
		_retain_active_receipt(&"lifecycle_reset")
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	if _edge_tween != null and _edge_tween.is_valid():
		_edge_tween.kill()
	if restore_camera:
		_restore_failure_camera()
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
	presentation_origin = Vector3.ZERO
	projection_rebound = false
	projection_rebound_reason = &"none"
	skip_available = false
	_completed_current = false
	_expansion_started = false
	_debris_started = false
	_dust_started = false
	_media_started = false
	_video_play_requested = false
	_video_started = false
	_video_failed = false
	_video_finished = false
	_video_completion_reason = &"none"
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
	death_video.stop()
	death_video.paused = false
	death_video.visible = false
	death_video.modulate.a = 0.0
	media_layer.visible = false
	media_layer.modulate.a = 1.0
	media_treatment.visible = true
	media_top_rail.visible = true
	media_title.visible = true
	media_copy.visible = true
	media_skip.visible = true


func _spawn_explosion_layers(origin: Vector3) -> void:
	var effect := DETONATION_EFFECT_SCENE.instantiate() as FusepointBombTerminalEffect
	if effect == null:
		return
	effect_root.add_child(effect)
	effect.add_to_group(&"bomb_terminal_sequence")
	effect.play(current_event_id, origin, presentation_origin, _particle_scale())
	_effect_nodes.append(effect)


func _resolve_presentation_origin(origin: Vector3) -> Dictionary:
	var viewport_rect := camera.get_viewport().get_visible_rect()
	var safe_rect := viewport_rect.grow(-PROJECTION_MARGIN)
	var behind := camera.is_position_behind(origin)
	var screen_point := Vector2(-1.0, -1.0) if behind else camera.unproject_position(origin)
	var in_safe_frame := not behind and safe_rect.has_point(screen_point)
	var occluded := false
	if in_safe_frame:
		var query := PhysicsRayQueryParameters3D.create(camera.global_position, origin)
		if player is CollisionObject3D:
			query.exclude = [(player as CollisionObject3D).get_rid()]
		query.collide_with_areas = false
		var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
		occluded = not hit.is_empty() and (hit.get("position", origin) as Vector3).distance_to(origin) > 0.8
	var rebound := behind or not in_safe_frame or occluded
	var rebound_origin := camera.global_position - camera.global_basis.z * CAMERA_EFFECT_DISTANCE - Vector3.UP * 0.45
	return {
		"authoritative_world_origin": origin,
		"presentation_origin": rebound_origin if rebound else origin,
		"rebound": rebound,
		"reason": &"behind_camera" if behind else &"outside_safe_frame" if not in_safe_frame else &"occluded" if occluded else &"authoritative_origin_visible",
		"screen_point": screen_point,
		"safe_rect": safe_rect,
		"camera_path": String(camera.get_path()),
		"camera_position": camera.global_position,
		"camera_forward": -camera.global_basis.z,
		"distance_meters": camera.global_position.distance_to(origin),
	}


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
		"presentation_origin": presentation_origin,
		"projection_rebound": projection_rebound,
		"projection_rebound_reason": projection_rebound_reason,
		"health_zero": float(player.get("health")) <= 0.0 if player != null else false,
		"player_terminal_locked": player.get("terminal_locked") if player != null else false,
		"effect_layer_count": _effect_layer_receipts().size(),
		"media_visible": media_layer.visible,
		"video_visible": death_video.visible,
		"video_playing": death_video.is_playing(),
		"video_stream_position": death_video.stream_position,
		"video_stream_length": death_video.get_stream_length() if death_video.stream != null else 0.0,
		"video_started": _video_started,
		"video_finished": _video_finished,
		"video_failed": _video_failed,
		"video_completion_reason": _video_completion_reason,
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
		if node.has_method(&"layer_receipts"):
			layers.append_array(node.call(&"layer_receipts"))
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
		"blast": {"bus": blast_audio.bus, "playing": blast_audio.playing, "stream_bound": blast_audio.stream != null, "stream_path": blast_audio.stream.resource_path if blast_audio.stream != null else "", "spatial": true, "unit_size": blast_audio.unit_size, "max_distance": blast_audio.max_distance, "volume_db": blast_audio.volume_db, "generated": false},
		"tail": {"bus": tail_audio.bus, "playing": tail_audio.playing, "stream_bound": tail_audio.stream != null, "stream_path": tail_audio.stream.resource_path if tail_audio.stream != null else "", "spatial": true, "unit_size": tail_audio.unit_size, "max_distance": tail_audio.max_distance, "volume_db": tail_audio.volume_db, "generated": false},
	}
	_active_branch_receipt["camera"] = {
		"position": camera.global_position if camera != null else Vector3.ZERO,
		"forward": -camera.global_basis.z if camera != null else Vector3.FORWARD,
		"authoritative_world_origin": world_origin,
		"presentation_origin": presentation_origin,
		"projection_rebound": projection_rebound,
		"projection_rebound_reason": projection_rebound_reason,
		"presentation_screen_point": camera.unproject_position(presentation_origin) if camera != null and not camera.is_position_behind(presentation_origin) else Vector2(-1.0, -1.0),
		"victory": victory_sequence.snapshot(),
		"failure_camera_bound": _failure_camera_bound,
		"fall_distance_meters": _camera_fall_distance,
		"fall_tilt_degrees": _camera_fall_tilt_degrees,
		"authored_local_position": _failure_camera_position,
		"authored_local_rotation": _failure_camera_rotation,
	}
	_active_branch_receipt["media"] = {
		"visible": death_video.visible or media_layer.visible,
		"video_node_path": String(death_video.get_path()),
		"video_path": DEATH_VIDEO_PATH,
		"video_sha256": DEATH_VIDEO_SHA256,
		"source_sha256": DEATH_VIDEO_SOURCE_SHA256,
		"receipt_path": DEATH_VIDEO_RECEIPT_PATH,
		"stream_bound": death_video.stream != null,
		"stream_resource_path": death_video.stream.resource_path if death_video.stream != null else "",
		"play_requested": _video_play_requested,
		"playing": death_video.is_playing(),
		"paused": death_video.paused,
		"stream_position": death_video.stream_position,
		"stream_length": death_video.get_stream_length() if death_video.stream != null else 0.0,
		"volume_db": death_video.volume_db,
		"fade_seconds": 0.32,
		"skip_available": skip_available,
		"fallback": _video_failed,
		"finished": _video_finished,
		"completion_reason": _video_completion_reason,
	}
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
		"video_playing": death_video.is_playing(),
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
	_restore_failure_camera()
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
		"world_origin": world_origin,
		"presentation_origin": presentation_origin,
		"projection_rebound": projection_rebound,
		"projection_rebound_reason": projection_rebound_reason,
		"completion_count": completion_count,
		"duplicate_event_count": duplicate_event_count,
		"effect_layer_count": _effect_layer_receipts().size(),
		"health_zero": state.get("health_zero", false),
		"player_terminal_locked": state.get("player_terminal_locked", false),
		"media_visible": media_layer.visible,
		"video_visible": death_video.visible,
		"video_playing": death_video.is_playing(),
		"skip_available": skip_available,
		"active_branch_receipt": _active_branch_receipt.duplicate(true),
		"retained_branch_receipt_count": _retained_branch_receipts.size(),
		"retained_branch_receipts": _retained_branch_receipts.duplicate(true),
		"restore_epoch": _restore_epoch,
	}
