class_name FusepointMissionFeedbackController
extends CanvasLayer

## Presentation-only, idempotent observer of immutable MissionController events.
## This node never submits objective, checkpoint, score, damage, or terminal state.

signal mission_cue_presented(receipt: Dictionary)

const CACHE_LIMIT := 128
const WARNING_THRESHOLDS: Array[int] = [30, 15, 10, 5]
const VOICE_RECEIPT_LIMIT := 64

@export var mission_path: NodePath
@export_range(0.2, 4.0, 0.1) var default_cue_seconds := 1.8

@onready var cue_root: Control = %CueRoot
@onready var cue_panel: PanelContainer = %CuePanel
@onready var accent: ColorRect = %Accent
@onready var badge: Label = %Badge
@onready var title: Label = %Title
@onready var detail: Label = %Detail
@onready var pulse: ColorRect = %Pulse

var presented_event_count := 0
var duplicate_event_count := 0
var concurrency_cull_count := 0
var active_cue_count := 0
var active_lifetime_remaining := 0.0
var last_event: Dictionary = {}
var last_cue: Dictionary = {}

var _mission: Node
var _observed_ids: Dictionary = {}
var _observed_order: Array[String] = []
var _warning_thresholds_seen: Dictionary = {}
var _variant_use_counts := {&"capture": 0, &"route": 0, &"defusal": 0, &"warning": 0, &"terminal": 0}
var _last_sequence := 0
var _cue_tween: Tween
var _audio_player: AudioStreamPlayer
var _audio_players: Dictionary = {}
var _audio_streams: Dictionary = {}
var _audio_durations: Dictionary = {}
var _active_voice_lifetimes: Dictionary = {}
var _voice_receipts: Array[Dictionary] = []
var _retained_voice_receipts: Array[Dictionary] = []
var _footstep_emitters: Dictionary = {}
var _enemy_step_elapsed: Dictionary = {}
var _player_step_elapsed := 0.0
var _player_step_side := 0
var _player_was_grounded := true
var _paused_last_frame := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_audio_mix()
	_audio_player = _audio_players.get(&"route") as AudioStreamPlayer
	cue_root.visible = false
	cue_root.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_mission = get_node_or_null(mission_path) if not mission_path.is_empty() else null
	if _mission != null and _mission.has_signal(&"mission_event_committed"):
		_mission.connect(&"mission_event_committed", present_event)
	call_deferred(&"_bind_player_lifecycle")


func _process(delta: float) -> void:
	if get_tree().paused:
		if not _paused_last_frame:
			reset_feedback(false)
		_paused_last_frame = true
		return
	if _paused_last_frame:
		_paused_last_frame = false
		_resume_mission_bed("lifecycle-pause-resume")
	active_lifetime_remaining = maxf(0.0, active_lifetime_remaining - delta)
	if active_lifetime_remaining <= 0.0:
		active_cue_count = 0
	for role: StringName in _active_voice_lifetimes.keys():
		if float(_active_voice_lifetimes[role]) >= 0.0:
			_active_voice_lifetimes[role] = maxf(0.0, float(_active_voice_lifetimes[role]) - delta)
	_observe_footsteps(delta)


func present_event(event: Dictionary) -> bool:
	var event_id := String(event.get("event_id", ""))
	var kind := StringName(event.get("kind", &""))
	var sequence := int(event.get("sequence", 0))
	if event_id.is_empty() or kind.is_empty():
		return false
	if kind == &"deployment_started" and (sequence <= _last_sequence or sequence == 1):
		reset_feedback(true)
	if _observed_ids.has(event_id):
		duplicate_event_count += 1
		return false
	if kind == &"checkpoint_restored":
		_clear_active_cue()
	var cue := _cue_for_event(kind, event)
	_last_sequence = maxi(_last_sequence, sequence)
	if cue.is_empty():
		return false
	if kind == &"deployment_started":
		_start_mission_bed(event_id)
	elif kind == &"terminal_submitted":
		_stop_mission_bed()
		_stop_spatial_voices()
		_archive_voice_receipts(&"terminal_submitted")
	_remember_event(event_id)
	if active_cue_count > 0:
		concurrency_cull_count += 1
		_clear_active_cue()
	presented_event_count += 1
	var family := StringName(cue.get("family", &"route"))
	_variant_use_counts[family] = int(_variant_use_counts.get(family, 0)) + 1
	cue["event_id"] = event_id
	_show_cue(cue)
	last_event = event.duplicate(true)
	last_cue = {
		"event_id": event_id,
		"event_kind": kind,
		"family": family,
		"roles": cue.get("roles", []),
		"badge": cue.get("badge", ""),
		"title": cue.get("title", ""),
		"detail": cue.get("detail", ""),
		"priority": cue.get("priority", 0),
		"lifetime_seconds": cue.get("lifetime", default_cue_seconds),
		"concurrency": {"active": active_cue_count, "limit": 1, "culled_total": concurrency_cull_count},
		"duplicate_count": duplicate_event_count,
		"presentation_only": true,
	}
	mission_cue_presented.emit(last_cue.duplicate(true))
	return true


func reset_feedback(clear_history := false) -> void:
	_archive_voice_receipts(&"feedback_reset")
	_clear_active_cue()
	_warning_thresholds_seen.clear()
	last_event.clear()
	last_cue.clear()
	if clear_history:
		_observed_ids.clear()
		_observed_order.clear()
		_last_sequence = 0
	for player: AudioStreamPlayer in _audio_players.values():
		player.stop()
	_stop_spatial_voices()
	_active_voice_lifetimes.clear()
	_enemy_step_elapsed.clear()
	_player_step_elapsed = 0.0


func _bind_player_lifecycle() -> void:
	var player := get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	if player.has_signal(&"spawn_reset") and not player.is_connected(&"spawn_reset", _on_player_spawn_reset):
		player.connect(&"spawn_reset", _on_player_spawn_reset)
	if player.has_signal(&"player_died") and not player.is_connected(&"player_died", _on_player_died):
		player.connect(&"player_died", _on_player_died)


func _on_player_spawn_reset() -> void:
	var player := get_tree().get_first_node_in_group(&"player")
	var receipt: Dictionary = player.get("_last_deployment_reset_receipt") if player != null else {}
	reset_feedback(true)
	_start_mission_bed(String(receipt.get("event_id", "deployment-reset")))


func _on_player_died(_event: Dictionary) -> void:
	reset_feedback(false)


func _stop_spatial_voices() -> void:
	for emitter: AudioStreamPlayer3D in _footstep_emitters.values():
		if is_instance_valid(emitter):
			emitter.stop()


func snapshot() -> Dictionary:
	return {
		"family_id": &"mission_state_feedback",
		"presented_event_count": presented_event_count,
		"duplicate_event_count": duplicate_event_count,
		"cached_event_count": _observed_ids.size(),
		"active_cue_count": active_cue_count,
		"active_lifetime_remaining": active_lifetime_remaining,
		"concurrency_limit": 1,
		"concurrency_cull_count": concurrency_cull_count,
		"last_event": last_event,
		"last_cue": last_cue,
		"variant_use_counts": _variant_use_counts,
		"runtime_variant_count": _variant_use_counts.size(),
		"max_single_variant_share": _max_variant_share(),
		"variant_roles": [&"capture", &"route", &"defusal", &"warning", &"terminal"],
		"audio_roles": _audio_role_snapshot(),
		"audio_role_count": _audio_streams.size(),
		"voice_receipts": _voice_receipts,
		"voice_receipt_count": _voice_receipts.size(),
		"retained_voice_receipts": _retained_voice_receipts,
		"retained_voice_receipt_count": _retained_voice_receipts.size(),
		"audio_concurrency_limits": {"mission_family": 1, "footstep_emitters_per_actor": 1, "retained_receipts": VOICE_RECEIPT_LIMIT},
		"semantic_role_contract": {
			"objective": [&"capture", &"route"],
			"bomb": [&"defusal", &"warning", &"terminal"],
			"dialogue": [&"dialogue"],
			"ambience": [&"ambience"],
			"music": [&"music"],
			"footstep": [&"player_walk", &"player_sprint", &"player_crouch", &"player_land", &"enemy_step"],
			"combat_external_bus": &"Combat",
		},
		"independent_buses": [&"Mission", &"Dialogue", &"Ambience", &"Music", &"Foley"],
		"authoritative_calls": [],
		"presentation_only": true,
	}


func _cue_for_event(kind: StringName, event: Dictionary) -> Dictionary:
	var payload: Dictionary = event.get("payload", {})
	match kind:
		&"deployment_started":
			return _cue(&"route", "ROUTE", "DEPLOYMENT LIVE", "RETAKE ALPHA · RECOVER TWO KEYS", Color(0.12, 0.86, 1.0), [&"route_guidance", &"deployment_audio"], 2, 2.2)
		&"capture_started":
			return _cue(&"capture", "CAP", "CAPTURE LINK", "%s UPLINK IN PROGRESS" % _objective_name(payload), Color(0.12, 0.86, 1.0), [&"capture_start_pulse", &"capture_audio"], 2, 1.5)
		&"capture_contested":
			return _cue(&"capture", "HOLD", "CAPTURE CONTESTED", "CLEAR THE RIFT FRONT FROM THE RADIUS", Color(1.0, 0.55, 0.08), [&"contest_pulse", &"contest_alarm"], 3, 1.4)
		&"capture_interrupted":
			return _cue(&"capture", "PAUSE", "CAPTURE INTERRUPTED", String(payload.get("reason", &"pressure")).replace("_", " ").to_upper(), Color(1.0, 0.48, 0.08), [&"capture_interrupt_pulse", &"interrupt_audio"], 3, 1.4)
		&"capture_completed":
			return _cue(&"capture", "SEC", "%s SECURED" % _objective_name(payload), "AEGIS CONTROL ESTABLISHED", Color(0.18, 0.94, 0.82), [&"capture_complete_pulse", &"secure_chime"], 4, 2.0)
		&"key_committed":
			return _cue(&"route", "KEY", "DEFUSAL KEY COMMITTED", "%d / 2 KEYS AUTHORIZED" % int(payload.get("key_count", 0)), Color(1.0, 0.82, 0.16), [&"key_commit_flash", &"key_chime"], 4, 2.0)
		&"route_unlocked":
			return _cue(&"route", "OPEN", "ROUTE UNLOCKED", String(payload.get("route_id", &"")).replace("_", " → ").to_upper(), Color(1.0, 0.78, 0.12), [&"route_unlock_sweep", &"route_chime"], 4, 2.0)
		&"checkpoint_restored":
			return _cue(&"route", "REST", "CHECKPOINT RESTORED", "TRANSIENT COMBAT CUES RESET", Color(0.32, 0.82, 1.0), [&"restore_sweep", &"restore_chime"], 5, 1.8)
		&"defusal_started":
			return _cue(&"defusal", "EOD", "DEFUSAL STAGE ACTIVE", String(payload.get("stage_id", &"")).replace("_", " ").to_upper(), Color(0.18, 0.9, 1.0), [&"defusal_active_pulse", &"defusal_loop_edge"], 5, 1.6)
		&"defusal_interrupted":
			return _cue(&"defusal", "STOP", "DEFUSAL INTERRUPTED", String(payload.get("reason", &"interference")).replace("_", " ").to_upper(), Color(1.0, 0.25, 0.08), [&"defusal_interrupt_flash", &"interrupt_alarm"], 6, 1.8)
		&"defusal_completed":
			return _cue(&"defusal", "DONE", "DEFUSAL STAGE COMPLETE", String(payload.get("stage_id", &"")).replace("_", " ").to_upper(), Color(0.16, 0.96, 0.78), [&"defusal_complete_sweep", &"stage_chime"], 6, 2.0)
		&"timer_tick":
			var remaining := int(ceil(float(event.get("remaining_time", 0.0))))
			if remaining not in WARNING_THRESHOLDS or _warning_thresholds_seen.has(remaining):
				return {}
			_warning_thresholds_seen[remaining] = true
			var critical := remaining <= 10
			return _cue(&"warning", "WARN", "FINAL COUNTDOWN", "%02d SECONDS TO DETONATION" % remaining, Color(1.0, 0.12, 0.04) if critical else Color(1.0, 0.55, 0.06), [&"countdown_edge_pulse", &"warning_alarm"], 7, 1.3)
		&"terminal_submitted":
			var success := StringName(payload.get("result", &"")) == &"bomb_defused"
			return _cue(&"terminal", "SAFE" if success else "FAIL", "BOMB DEFUSED" if success else "DETONATION COMMITTED", "ROCKET BAY PRESERVED" if success else "BASE FAILURE SEQUENCE", Color(0.16, 1.0, 0.78) if success else Color(1.0, 0.08, 0.025), [&"terminal_success_sweep" if success else &"terminal_failure_flash", &"terminal_chime" if success else &"terminal_alarm"], 10, 2.8)
	return {}


func _cue(family: StringName, badge_text: String, title_text: String, detail_text: String, color: Color, roles: Array[StringName], priority: int, lifetime: float) -> Dictionary:
	return {"family": family, "badge": badge_text, "title": title_text, "detail": detail_text, "color": color, "roles": roles, "priority": priority, "lifetime": lifetime}


func _show_cue(cue: Dictionary) -> void:
	var color: Color = cue.get("color", Color.WHITE)
	badge.text = String(cue.get("badge", "STATE"))
	title.text = String(cue.get("title", "MISSION UPDATE"))
	detail.text = String(cue.get("detail", ""))
	badge.modulate = color
	accent.color = color
	pulse.color = Color(color.r, color.g, color.b, 0.72)
	var panel_style := cue_panel.get_theme_stylebox("panel") as StyleBoxFlat
	if panel_style != null:
		panel_style.border_color = Color(color.r, color.g, color.b, 0.72)
	cue_root.visible = true
	cue_root.modulate = Color(1.0, 1.0, 1.0, 0.0)
	pulse.scale.x = 0.05
	active_cue_count = 1
	active_lifetime_remaining = float(cue.get("lifetime", default_cue_seconds))
	_play_audio(StringName(cue.get("family", &"route")), int(cue.get("priority", 1)), String(cue.get("event_id", "")))
	_cue_tween = create_tween().set_parallel(true)
	_cue_tween.set_pause_mode(Tween.TWEEN_PAUSE_BOUND)
	_cue_tween.tween_property(cue_root, "modulate", Color.WHITE, 0.12)
	_cue_tween.tween_property(pulse, "scale:x", 1.0, 0.26).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_cue_tween.tween_property(cue_root, "modulate", Color(1.0, 1.0, 1.0, 0.0), 0.32).set_delay(maxf(0.2, active_lifetime_remaining - 0.32))
	_cue_tween.finished.connect(_clear_active_cue)


func _clear_active_cue() -> void:
	if _cue_tween != null and _cue_tween.is_valid():
		_cue_tween.kill()
	_cue_tween = null
	active_cue_count = 0
	active_lifetime_remaining = 0.0
	if cue_root != null:
		cue_root.visible = false
		cue_root.modulate = Color(1.0, 1.0, 1.0, 0.0)


func _remember_event(event_id: String) -> void:
	_observed_ids[event_id] = true
	_observed_order.append(event_id)
	while _observed_order.size() > CACHE_LIMIT:
		_observed_ids.erase(_observed_order.pop_front())


func _objective_name(payload: Dictionary) -> String:
	return String(payload.get("objective_id", &"point")).to_upper()


func _play_audio(family: StringName, priority: int, event_id: String) -> void:
	_play_role(family, priority, event_id)


func _build_audio_mix() -> void:
	var profiles := {
		&"capture": [0.24, 410.0, 0.25, 0.10, &"Mission", false],
		&"route": [0.30, 640.0, 0.23, 0.04, &"Mission", false],
		&"defusal": [0.38, 286.0, 0.24, 0.13, &"Mission", false],
		&"warning": [0.42, 168.0, 0.31, 0.11, &"Mission", false],
		&"terminal": [0.62, 782.0, 0.27, 0.07, &"Mission", false],
		&"dialogue": [1.35, 228.0, 0.18, 0.12, &"Dialogue", false],
		&"ambience": [2.2, 74.0, 0.08, 0.20, &"Ambience", true],
		&"music": [2.8, 94.0, 0.10, 0.015, &"Music", true],
		&"player_walk": [0.16, 108.0, 0.12, 0.48, &"Foley", false],
		&"player_sprint": [0.19, 86.0, 0.15, 0.58, &"Foley", false],
		&"player_crouch": [0.13, 142.0, 0.08, 0.30, &"Foley", false],
		&"player_land": [0.28, 72.0, 0.18, 0.62, &"Foley", false],
		&"enemy_step": [0.18, 96.0, 0.13, 0.50, &"Foley", false],
	}
	for role: StringName in profiles:
		var profile: Array = profiles[role]
		var duration := float(profile[0])
		var stream := _synth_cue(duration, float(profile[1]), float(profile[2]), float(profile[3]), profile[5] == true, role)
		_audio_streams[role] = stream
		_audio_durations[role] = duration
		if role not in [&"player_walk", &"player_sprint", &"player_crouch", &"player_land", &"enemy_step"]:
			var player := AudioStreamPlayer.new()
			player.name = "%sVoice" % String(role).to_pascal_case()
			player.stream = stream
			player.bus = StringName(profile[4])
			player.volume_db = -4.0 if role == &"dialogue" else -12.0 if role in [&"ambience", &"music"] else -7.0
			add_child(player)
			_audio_players[role] = player


func _play_role(role: StringName, priority: int, source_id: String) -> void:
	var player := _audio_players.get(role) as AudioStreamPlayer
	if player == null or not _audio_streams.has(role):
		return
	player.stream = _audio_streams[role]
	player.volume_db = (-4.0 if role == &"dialogue" else -7.0) + minf(float(priority), 8.0) * 0.25
	player.pitch_scale = 0.92 if role == &"warning" else 1.0
	player.play()
	_active_voice_lifetimes[role] = -1.0 if role in [&"ambience", &"music"] else float(_audio_durations.get(role, 0.0))
	_append_voice_receipt({
		"event_id": source_id,
		"run_epoch": int(_mission.get("run_epoch")) if _mission != null else 0,
		"role": role,
		"bus": player.bus,
		"voice_path": String(player.get_path()),
		"stream_bound": player.stream != null,
		"decoded": player.stream is AudioStreamWAV and (player.stream as AudioStreamWAV).data.size() > 0,
		"playing": player.playing,
		"onset_usec": Time.get_ticks_usec(),
		"onset_frame": Engine.get_process_frames(),
		"lifetime_seconds": float(_audio_durations.get(role, 0.0)),
		"attenuation": &"non_spatial",
		"emitter_context": {"spatial": false, "owner": get_path()},
		"concurrency": {"active": 1 if player.playing else 0, "limit": 1, "family": role},
		"cleanup_observed": false,
		"cleanup_usec": 0,
		"priority": priority,
	})


func _start_mission_bed(event_id: String) -> void:
	_play_role(&"ambience", 1, event_id)
	_play_role(&"music", 1, event_id)
	_play_role(&"dialogue", 6, event_id)


func _resume_mission_bed(event_id: String) -> void:
	_play_role(&"ambience", 1, event_id)
	_play_role(&"music", 1, event_id)


func _stop_mission_bed() -> void:
	for role in [&"ambience", &"music", &"dialogue"]:
		var player := _audio_players.get(role) as AudioStreamPlayer
		if player != null:
			player.stop()
		_active_voice_lifetimes[role] = 0.0


func _observe_footsteps(delta: float) -> void:
	var player := get_tree().get_first_node_in_group(&"player") as CharacterBody3D
	if player != null:
		var grounded := player.is_on_floor()
		var horizontal_speed := Vector2(player.velocity.x, player.velocity.z).length()
		var stance := StringName(player.get("_stance"))
		var locomotion := StringName(player.get("_locomotion_mode"))
		if grounded and not _player_was_grounded:
			_emit_footstep(player, &"player_land", 0.0, &"landing")
		_player_was_grounded = grounded
		_player_step_elapsed = maxf(0.0, _player_step_elapsed - delta)
		if grounded and horizontal_speed > 0.35 and _player_step_elapsed <= 0.0:
			var role := &"player_crouch" if stance in [&"crouching", &"prone"] else &"player_sprint" if locomotion == &"sprint" else &"player_walk"
			var cadence := 0.58 if role == &"player_crouch" else 0.29 if role == &"player_sprint" else 0.43
			_emit_footstep(player, role, cadence, &"left" if _player_step_side % 2 == 0 else &"right")
			_player_step_side += 1
			_player_step_elapsed = cadence
	for node: Node in get_tree().get_nodes_in_group(&"fps_enemy"):
		var enemy := node as CharacterBody3D
		if enemy == null or enemy.get("mission_active") != true or not enemy.is_on_floor():
			continue
		var actor_id := String(enemy.get("stable_id"))
		var remaining := maxf(0.0, float(_enemy_step_elapsed.get(actor_id, 0.0)) - delta)
		_enemy_step_elapsed[actor_id] = remaining
		if Vector2(enemy.velocity.x, enemy.velocity.z).length() > 0.55 and remaining <= 0.0:
			_emit_footstep(enemy, &"enemy_step", 0.46, &"alternating")
			_enemy_step_elapsed[actor_id] = 0.46


func _emit_footstep(actor: CharacterBody3D, role: StringName, cadence: float, side: StringName) -> void:
	var actor_key := String(actor.get_path())
	var emitter := _footstep_emitters.get(actor_key) as AudioStreamPlayer3D
	if emitter == null or not is_instance_valid(emitter):
		emitter = AudioStreamPlayer3D.new()
		emitter.name = "FusepointFootstepEmitter"
		emitter.bus = &"Foley"
		emitter.unit_size = 4.0
		emitter.max_distance = 24.0
		actor.add_child(emitter)
		_footstep_emitters[actor_key] = emitter
	var surface := _surface_at(actor)
	emitter.stream = _audio_streams.get(role)
	emitter.volume_db = -9.0 if role == &"enemy_step" else -7.0
	emitter.pitch_scale = (1.08 if surface == &"metal" else 0.94) * (1.025 if side == &"right" else 0.985)
	emitter.play()
	_append_voice_receipt({
		"event_id": "step-%d" % Time.get_ticks_usec(),
		"run_epoch": int(_mission.get("run_epoch")) if _mission != null else 0,
		"role": role,
		"bus": emitter.bus,
		"voice_path": String(emitter.get_path()),
		"stream_bound": emitter.stream != null,
		"playing": emitter.playing,
		"decoded": emitter.stream is AudioStreamWAV and (emitter.stream as AudioStreamWAV).data.size() > 0,
		"onset_usec": Time.get_ticks_usec(),
		"onset_frame": Engine.get_process_frames(),
		"actor_id": String(actor.get("stable_id")) if actor.is_in_group(&"fps_enemy") else "player",
		"emitter_transform": actor.global_transform,
		"surface": surface,
		"side": side,
		"cadence_seconds": cadence,
		"grounded": actor.is_on_floor(),
		"attenuation": {"unit_size": emitter.unit_size, "max_distance": emitter.max_distance},
		"emitter_context": {"spatial": true, "owner": actor.get_path()},
		"concurrency": {"active": 1 if emitter.playing else 0, "limit": 1, "family": actor_key},
		"cleanup_observed": false,
		"cleanup_usec": 0,
		"lifetime_seconds": float(_audio_durations.get(role, 0.0)),
	})


func _surface_at(actor: CharacterBody3D) -> StringName:
	var query := PhysicsRayQueryParameters3D.create(actor.global_position + Vector3.UP * 0.25, actor.global_position + Vector3.DOWN * 1.4)
	query.collide_with_areas = false
	query.exclude = [actor.get_rid()]
	var hit := actor.get_world_3d().direct_space_state.intersect_ray(query)
	var path := String((hit.get("collider") as Node).get_path()).to_lower() if hit.get("collider") is Node else ""
	return &"metal" if "metal" in path or "container" in path or "catwalk" in path else &"concrete"


func _append_voice_receipt(receipt: Dictionary) -> void:
	_voice_receipts.append(receipt)
	while _voice_receipts.size() > VOICE_RECEIPT_LIMIT:
		_voice_receipts.pop_front()


func _archive_voice_receipts(reason: StringName) -> void:
	for receipt: Dictionary in _voice_receipts:
		var archived := receipt.duplicate(true)
		archived["cleanup_reason"] = reason
		archived["cleanup_observed"] = true
		archived["cleanup_usec"] = Time.get_ticks_usec()
		_retained_voice_receipts.append(archived)
	while _retained_voice_receipts.size() > VOICE_RECEIPT_LIMIT:
		_retained_voice_receipts.pop_front()
	_voice_receipts.clear()


func _audio_role_snapshot() -> Dictionary:
	var roles: Dictionary = {}
	for role: StringName in _audio_streams:
		var player := _audio_players.get(role) as AudioStreamPlayer
		roles[role] = {
			"stream_bound": _audio_streams[role] != null,
			"decoded": _audio_streams[role] is AudioStreamWAV and (_audio_streams[role] as AudioStreamWAV).data.size() > 0,
			"non_silent": float(_audio_durations.get(role, 0.0)) > 0.0,
			"bus": player.bus if player != null else &"Foley",
			"playing": player.playing if player != null else _recent_role_playing(role),
			"lifetime_remaining": float(_active_voice_lifetimes.get(role, 0.0)),
			"fallback_behavior": &"candidate_owned_pcm",
		}
	return roles


func _recent_role_playing(role: StringName) -> bool:
	var expected_stream: AudioStream = _audio_streams.get(role)
	for emitter: AudioStreamPlayer3D in _footstep_emitters.values():
		if is_instance_valid(emitter) and emitter.playing and emitter.stream == expected_stream:
			return true
	return false


func _synth_cue(duration: float, frequency: float, tone_gain: float, noise_gain: float, looped := false, role := &"cue") -> AudioStreamWAV:
	const MIX_RATE := 22050
	var sample_count := int(MIX_RATE * duration)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	for sample_index in sample_count:
		var t := float(sample_index) / float(MIX_RATE)
		var progress := float(sample_index) / float(sample_count)
		var decay := 0.72 + 0.28 * sin(PI * progress) if looped else pow(1.0 - progress, 1.8)
		var modulation := 1.0 + 0.04 * sin(TAU * (2.0 + float(String(role).length() % 5)) * t)
		var overtone := sin(TAU * frequency * 1.5 * modulation * t) * tone_gain * 0.35
		var tone := sin(TAU * frequency * modulation * t) * tone_gain + overtone
		if role == &"dialogue":
			var speech_gate := 1.0 if sin(TAU * 7.0 * t) * 0.5 + 0.5 >= 0.38 else 0.0
			tone *= 0.25 + 0.75 * speech_gate
		var noise_seed := float(((sample_index * 1103515245 + 12345) >> 16) & 0x7fff) / 32767.0
		var value := clampf((tone + (noise_seed * 2.0 - 1.0) * noise_gain) * decay, -1.0, 1.0)
		var pcm := int(value * 32767.0)
		if pcm < 0:
			pcm += 65536
		bytes[sample_index * 2] = pcm & 0xff
		bytes[sample_index * 2 + 1] = (pcm >> 8) & 0xff
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = bytes
	if looped:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = sample_count
	return stream


func _max_variant_share() -> float:
	var total := 0
	var maximum := 0
	for family in _variant_use_counts:
		var count := int(_variant_use_counts[family])
		total += count
		maximum = maxi(maximum, count)
	return 0.0 if total <= 0 else float(maximum) / float(total)


func _mcp_state() -> Dictionary:
	return snapshot()
