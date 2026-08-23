class_name FusepointMissionFeedbackController
extends CanvasLayer

## Presentation-only, idempotent observer of immutable MissionController events.
## This node never submits objective, checkpoint, score, damage, or terminal state.

signal mission_cue_presented(receipt: Dictionary)

const CACHE_LIMIT := 128
const WARNING_THRESHOLDS: Array[int] = [30, 15, 10, 5]
const VOICE_RECEIPT_LIMIT := 64
const FOOTSTEP_ROLES: Array[StringName] = [&"enemy_step"]
const HUD_EVENT_ROW_KINDS: Array[StringName] = [
	&"deployment_started", &"capture_started", &"capture_contested",
	&"capture_completed", &"key_committed", &"route_unlocked",
	&"checkpoint_restored",
]
const CONCRETE_FOOTSTEPS: Array[AudioStream] = [
	preload("res://assets/audio/foley/cogito_stone/footstep_stone-01.ogg"),
	preload("res://assets/audio/foley/cogito_stone/footstep_stone-02.ogg"),
	preload("res://assets/audio/foley/cogito_stone/footstep_stone-03.ogg"),
	preload("res://assets/audio/foley/cogito_stone/footstep_stone-04.ogg"),
]
const METAL_FOOTSTEPS: Array[AudioStream] = [
	preload("res://assets/audio/foley/kenney_hard/footstep00.ogg"),
	preload("res://assets/audio/foley/kenney_hard/footstep01.ogg"),
	preload("res://assets/audio/foley/kenney_hard/footstep02.ogg"),
	preload("res://assets/audio/foley/kenney_hard/footstep03.ogg"),
	preload("res://assets/audio/foley/kenney_hard/footstep04.ogg"),
]
const FOOTSTEP_STREAM_PATHS := {
	&"player_walk": "res://assets/audio/foley/cogito_stone/",
	&"player_sprint": "res://assets/audio/foley/cogito_stone/",
	&"player_crouch": "res://assets/audio/foley/cogito_stone/",
	&"player_land": "res://assets/audio/foley/cogito_stone/",
	&"enemy_step": "res://assets/audio/foley/cogito_stone/",
}

@export var mission_path: NodePath
@export_range(0.2, 4.0, 0.1) var default_cue_seconds := 1.8

@onready var cue_root: Control = %CueRoot
@onready var cue_panel: MarginContainer = %CuePanel
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
var _latest_footstep_by_actor_role: Dictionary = {}
var _retained_player_footstep_owner: Dictionary = {}
var _enemy_locomotion_active: Dictionary = {}
var _enemy_idle_elapsed: Dictionary = {}
var _enemy_step_remaining: Dictionary = {}
var _enemy_step_variant: Dictionary = {}
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
		_stop_spatial_voices(&"terminal_submitted")
		_archive_voice_receipts(&"terminal_submitted")
	_remember_event(event_id)
	if kind in HUD_EVENT_ROW_KINDS:
		# TacticalHUD owns the one bounded right-side event lane. Retain this
		# observer for mission lifecycle/audio ownership, but never create a second
		# broad visual notice for the same authoritative event.
		presented_event_count += 1
		last_event = event.duplicate(true)
		last_cue = {
			"event_id": event_id,
			"event_kind": kind,
			"family": StringName(cue.get("family", &"route")),
			"roles": [&"delegated_tactical_hud_event_row"],
			"visual_owner": &"TacticalHUD/CombatFeed",
			"visual_suppressed_here": true,
			"concurrency": {"active": 0, "limit": 1, "culled_total": concurrency_cull_count},
			"duplicate_count": duplicate_event_count,
			"presentation_only": true,
		}
		mission_cue_presented.emit(last_cue.duplicate(true))
		return true
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
	_stop_spatial_voices(&"feedback_reset")
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
	_active_voice_lifetimes.clear()
	_enemy_locomotion_active.clear()
	_enemy_idle_elapsed.clear()
	_enemy_step_remaining.clear()
	_enemy_step_variant.clear()
	_retained_player_footstep_owner.clear()


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


func _stop_spatial_voices(reason: StringName) -> void:
	for actor_key: String in _footstep_emitters.keys():
		_stop_enemy_locomotion_stream(actor_key, reason)


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
		"footstep_receipts": _footstep_receipts(),
		"footstep_ownership": _footstep_ownership_snapshot(),
		"retained_player_footstep_owner": _retained_player_footstep_owner.duplicate(true),
		"latest_footstep_by_actor_role": _latest_footstep_by_actor_role.duplicate(true),
		"audio_concurrency_limits": {
			"mission_family": 1,
			"player_mission_emitters": 0,
			"enemy_footstep_emitters_per_actor": 1,
			"retained_receipts": VOICE_RECEIPT_LIMIT,
		},
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
	# Mission/UI presentation has no approved decoded source in this candidate.
	# Fail silent instead of manufacturing oscillator/noise placeholders.  The
	# retained viewmodel remains the sole player-Foley owner; this controller
	# only provisions the decoded spatial step used by enemy actors.
	var profiles := {
		&"enemy_step": [0.18, 96.0, 0.13, 0.50, &"Foley", false],
	}
	for role: StringName in profiles:
		var profile: Array = profiles[role]
		var duration := float(profile[0])
		var stream: AudioStream = CONCRETE_FOOTSTEPS[0]
		if stream.get_length() > 0.0:
			duration = stream.get_length()
		_audio_streams[role] = stream
		_audio_durations[role] = duration


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
		"decoded": _stream_is_decoded(player.stream),
		"stream_path": _stream_path_for_role(role),
		"playing": player.playing,
		"onset_usec": Time.get_ticks_usec(),
		"onset_frame": Engine.get_process_frames(),
		"lifetime_seconds": float(_audio_durations.get(&"enemy_step", 0.0)),
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
		_observe_retained_player_footsteps(player)
	var seen_actor_keys: Dictionary = {}
	for node: Node in get_tree().get_nodes_in_group(&"fps_enemy"):
		var enemy := node as CharacterBody3D
		if enemy == null:
			continue
		var actor_key := String(enemy.get_path())
		seen_actor_keys[actor_key] = true
		_ensure_enemy_footstep_emitter(enemy)
		var grounded := enemy.is_on_floor()
		var speed := Vector2(enemy.velocity.x, enemy.velocity.z).length()
		var mission_active: bool = enemy.get("mission_active") == true
		var was_active: bool = _enemy_locomotion_active.get(actor_key, false) == true
		if was_active:
			if not mission_active or not grounded:
				_stop_enemy_locomotion_stream(actor_key, &"mission_inactive" if not mission_active else &"lost_grounding")
			elif speed <= 0.18:
				var idle_elapsed := float(_enemy_idle_elapsed.get(actor_key, 0.0)) + delta
				_enemy_idle_elapsed[actor_key] = idle_elapsed
				if idle_elapsed >= 0.24:
					_stop_enemy_locomotion_stream(actor_key, &"stable_idle")
			else:
				_enemy_idle_elapsed[actor_key] = 0.0
				var remaining := float(_enemy_step_remaining.get(actor_key, 0.0)) - delta
				_enemy_step_remaining[actor_key] = remaining
				if remaining <= 0.0:
					_play_enemy_contact(enemy)
		elif mission_active and grounded and speed > 0.62:
			_start_enemy_locomotion_stream(enemy)
			_enemy_locomotion_active[actor_key] = true
			_enemy_idle_elapsed[actor_key] = 0.0
	for actor_key: String in _footstep_emitters.keys():
		if not seen_actor_keys.has(actor_key):
			_stop_enemy_locomotion_stream(actor_key, &"actor_removed")
			_footstep_emitters.erase(actor_key)
			_enemy_locomotion_active.erase(actor_key)
			_enemy_idle_elapsed.erase(actor_key)
			_enemy_step_remaining.erase(actor_key)
			_enemy_step_variant.erase(actor_key)


func _start_enemy_locomotion_stream(actor: CharacterBody3D) -> void:
	# Player movement Foley belongs to the retained viewmodel component. Mission
	# feedback may observe it but can only create spatial emitters for enemies.
	if not actor.is_in_group(&"fps_enemy"):
		return
	var actor_key := String(actor.get_path())
	var emitter := _ensure_enemy_footstep_emitter(actor)
	if emitter == null:
		return
	_enemy_step_remaining[actor_key] = 0.0
	_play_enemy_contact(actor)


func _ensure_enemy_footstep_emitter(actor: CharacterBody3D) -> AudioStreamPlayer3D:
	if actor == null or not actor.is_in_group(&"fps_enemy"):
		return null
	var actor_key := String(actor.get_path())
	var emitter := _footstep_emitters.get(actor_key) as AudioStreamPlayer3D
	if emitter == null or not is_instance_valid(emitter):
		emitter = AudioStreamPlayer3D.new()
		emitter.name = "FusepointFootstepEmitter"
		emitter.bus = &"Foley"
		emitter.unit_size = 4.0
		emitter.max_distance = 24.0
		emitter.stream = CONCRETE_FOOTSTEPS[0]
		actor.add_child(emitter)
		_footstep_emitters[actor_key] = emitter
	return emitter


func _play_enemy_contact(actor: CharacterBody3D) -> void:
	var actor_key := String(actor.get_path())
	var emitter := _footstep_emitters.get(actor_key) as AudioStreamPlayer3D
	if emitter == null or not is_instance_valid(emitter):
		return
	var surface := _surface_at(actor)
	var family := METAL_FOOTSTEPS if surface == &"metal" else CONCRETE_FOOTSTEPS
	if family.is_empty():
		return
	var variant := int(_enemy_step_variant.get(actor_key, 0))
	if emitter.playing:
		emitter.stop()
	emitter.stream = family[variant % family.size()]
	_enemy_step_variant[actor_key] = variant + 1
	emitter.volume_db = -6.0
	emitter.pitch_scale = 1.04 if surface == &"metal" else 0.96
	emitter.play()
	var speed := Vector2(actor.velocity.x, actor.velocity.z).length()
	var cadence_seconds := 0.38 if speed > 4.2 else 0.48
	_enemy_step_remaining[actor_key] = cadence_seconds
	var listener := get_viewport().get_camera_3d()
	var listener_distance := actor.global_position.distance_to(listener.global_position) if listener != null else 0.0
	var distance_attenuation_db := -20.0 * log(maxf(1.0, listener_distance / emitter.unit_size)) / log(10.0)
	var mix := _bus_stage_snapshot(emitter.bus, emitter.volume_db, distance_attenuation_db)
	var footstep_receipt := {
		"event_id": "contact-%d" % Time.get_ticks_usec(),
		"run_epoch": int(_mission.get("run_epoch")) if _mission != null else 0,
		"role": &"enemy_step",
		"bus": emitter.bus,
		"voice_path": String(emitter.get_path()),
		"stream_path": emitter.stream.resource_path,
		"stream_bound": emitter.stream != null,
		"playing": emitter.playing,
		"decoded": _stream_is_decoded(emitter.stream),
		"loop_enabled": false,
		"continuous_stream": false,
		"transition": &"ground_contact",
		"onset_usec": Time.get_ticks_usec(),
		"onset_frame": Engine.get_process_frames(),
		"actor_id": String(actor.get("stable_id")),
		"emitter_transform": actor.global_transform,
		"surface": surface,
		"cadence_seconds": cadence_seconds,
		"grounded": actor.is_on_floor(),
		"contact_state": &"grounded_moving",
		"attenuation": {"unit_size": emitter.unit_size, "max_distance": emitter.max_distance, "listener_distance": listener_distance, "estimated_db": distance_attenuation_db},
		"mix_stages": mix,
		"emitter_context": {"spatial": true, "owner": actor.get_path(), "owner_count": 1},
		"concurrency": {"active": 1 if emitter.playing else 0, "limit": 1, "family": actor_key},
		"cleanup_observed": false,
		"cleanup_usec": 0,
		"lifetime_seconds": emitter.stream.get_length(),
	}
	_append_voice_receipt(footstep_receipt)
	var receipt_key := "%s:%s" % [String(footstep_receipt["actor_id"]), "enemy_step"]
	_latest_footstep_by_actor_role[receipt_key] = footstep_receipt.duplicate(true)


func _stop_enemy_locomotion_stream(actor_key: String, reason: StringName) -> void:
	var emitter := _footstep_emitters.get(actor_key) as AudioStreamPlayer3D
	if emitter == null or not is_instance_valid(emitter):
		_enemy_locomotion_active[actor_key] = false
		return
	var was_playing := emitter.playing
	if was_playing:
		emitter.stop()
		_append_voice_receipt({
			"event_id": "locomotion-exit-%d" % Time.get_ticks_usec(),
			"role": &"enemy_step",
			"voice_path": String(emitter.get_path()),
			"stream_path": _stream_path_for_role(&"enemy_step"),
			"playing": false,
			"continuous_stream": false,
			"transition": &"locomotion_exit",
			"cleanup_observed": true,
			"cleanup_reason": reason,
			"cleanup_usec": Time.get_ticks_usec(),
			"cleanup_frame": Engine.get_process_frames(),
			"emitter_context": {"spatial": true, "owner": actor_key, "owner_count": 1},
		})
	_enemy_locomotion_active[actor_key] = false
	_enemy_idle_elapsed[actor_key] = 0.0
	_enemy_step_remaining[actor_key] = 0.0


func _observe_retained_player_footsteps(player: CharacterBody3D) -> void:
	var feedback := player.get_node_or_null("Head/Camera3D/FPSViewmodelSwitcher/FPSViewmodelFeedback")
	var walk: AudioStreamPlayer
	var run: AudioStreamPlayer
	if feedback != null:
		walk = feedback.get_node_or_null("WalkAudio") as AudioStreamPlayer
		run = feedback.get_node_or_null("RunAudio") as AudioStreamPlayer
	_retained_player_footstep_owner = {
		"actor_id": "player",
		"owner_kind": &"retained_viewmodel_component",
		"owner_path": String(feedback.get_path()) if feedback != null else "",
		"mission_emitter_count": 0,
		"playback_owner_count": 1 if feedback != null and walk != null and run != null else 0,
		"grounded": player.is_on_floor(),
		"locomotion": StringName(player.get("_locomotion_mode")),
		"stance": StringName(player.get("_stance")),
		"walk": {
			"path": String(walk.get_path()) if walk != null else "",
			"playing": walk.playing if walk != null else false,
			"stream_bound": walk != null and walk.stream != null,
			"bus": walk.bus if walk != null else StringName(),
			"continuous_owner": false,
			"stream_path": walk.stream.resource_path if walk != null and walk.stream != null else "",
			"duration_seconds": walk.stream.get_length() if walk != null and walk.stream != null else 0.0,
			"volume_db": walk.volume_db if walk != null else 0.0,
			"pitch_scale": walk.pitch_scale if walk != null else 1.0,
			"mix_stages": _bus_stage_snapshot(walk.bus, walk.volume_db) if walk != null else {},
		},
		"run": {
			"path": String(run.get_path()) if run != null else "",
			"playing": run.playing if run != null else false,
			"stream_bound": run != null and run.stream != null,
			"bus": run.bus if run != null else StringName(),
			"continuous_owner": false,
			"stream_path": run.stream.resource_path if run != null and run.stream != null else "",
			"duration_seconds": run.stream.get_length() if run != null and run.stream != null else 0.0,
			"volume_db": run.volume_db if run != null else 0.0,
			"pitch_scale": run.pitch_scale if run != null else 1.0,
			"mix_stages": _bus_stage_snapshot(run.bus, run.volume_db) if run != null else {},
		},
	}


func _bus_stage_snapshot(bus: StringName, owner_volume_db: float, spatial_attenuation_db := 0.0) -> Dictionary:
	var bus_index := AudioServer.get_bus_index(bus)
	var bus_db := AudioServer.get_bus_volume_db(bus_index) if bus_index >= 0 else 0.0
	var master_index := AudioServer.get_bus_index(&"Master")
	var master_db := AudioServer.get_bus_volume_db(master_index) if master_index >= 0 else 0.0
	return {
		"owner_volume_db": owner_volume_db,
		"spatial_attenuation_db": spatial_attenuation_db,
		"bus": bus,
		"bus_volume_db": bus_db,
		"bus_muted": AudioServer.is_bus_mute(bus_index) if bus_index >= 0 else false,
		"bus_solo": AudioServer.is_bus_solo(bus_index) if bus_index >= 0 else false,
		"bus_effect_count": AudioServer.get_bus_effect_count(bus_index) if bus_index >= 0 else 0,
		"master_volume_db": master_db,
		"master_muted": AudioServer.is_bus_mute(master_index) if master_index >= 0 else false,
		"effective_listener_gain_db": owner_volume_db + spatial_attenuation_db + bus_db + master_db,
	}


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
			"decoded": _stream_is_decoded(_audio_streams[role]),
			"stream_path": _stream_path_for_role(role),
			"non_silent": float(_audio_durations.get(role, 0.0)) > 0.0,
			"bus": player.bus if player != null else &"Foley",
			"playing": player.playing if player != null else _recent_role_playing(role),
			"lifetime_remaining": float(_active_voice_lifetimes.get(role, 0.0)),
			"fallback_behavior": &"decoded_contact_sample",
		}
	return roles


func _stream_is_decoded(stream: AudioStream) -> bool:
	if stream is AudioStreamWAV:
		return (stream as AudioStreamWAV).data.size() > 0
	if stream is AudioStreamMP3:
		return (stream as AudioStreamMP3).data.size() > 0
	return stream != null


func _stream_path_for_role(role: StringName) -> String:
	return String(FOOTSTEP_STREAM_PATHS.get(role, ""))


func _footstep_receipts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for receipt: Dictionary in _retained_voice_receipts + _voice_receipts:
		if StringName(receipt.get("role", &"")) in FOOTSTEP_ROLES:
			result.append(receipt.duplicate(true))
	return result


func _footstep_ownership_snapshot() -> Dictionary:
	var owners := {"player": _retained_player_footstep_owner.duplicate(true)}
	for actor_key: String in _footstep_emitters:
		var emitter := _footstep_emitters.get(actor_key) as AudioStreamPlayer3D
		owners[actor_key] = {
			"emitter_path": String(emitter.get_path()) if is_instance_valid(emitter) else "",
			"emitter_count": 1 if is_instance_valid(emitter) else 0,
			"bus": emitter.bus if is_instance_valid(emitter) else &"Foley",
			"stream_path": _stream_path_for_role(&"enemy_step"),
			"playing": emitter.playing if is_instance_valid(emitter) else false,
			"locomotion_active": _enemy_locomotion_active.get(actor_key, false) == true,
			"continuous_stream": false,
			"duration_seconds": emitter.stream.get_length() if is_instance_valid(emitter) and emitter.stream != null else 0.0,
			"mix_stages": _bus_stage_snapshot(emitter.bus, emitter.volume_db) if is_instance_valid(emitter) else {},
		}
	return owners


func _recent_role_playing(role: StringName) -> bool:
	if role != &"enemy_step":
		return false
	for emitter: AudioStreamPlayer3D in _footstep_emitters.values():
		if is_instance_valid(emitter) and emitter.playing:
			return true
	return false


func _max_variant_share() -> float:
	var total := 0
	var maximum := 0
	for family in _variant_use_counts:
		var count := int(_variant_use_counts[family])
		total += count
		maximum = maxi(maximum, count)
	return 0.0 if total <= 0 else float(maximum) / float(total)


func _mcp_state() -> Dictionary:
	var full := snapshot()
	var footsteps: Array = full.get("footstep_receipts", [])
	return {
		"family_id": &"mission_state_feedback",
		"presented_event_count": presented_event_count,
		"duplicate_event_count": duplicate_event_count,
		"active_cue_count": active_cue_count,
		"footstep_receipt_count": footsteps.size(),
		"latest_footstep_receipt": footsteps.back() if not footsteps.is_empty() else {},
		"footstep_ownership": full.get("footstep_ownership", {}),
		"latest_footstep_by_actor_role": full.get("latest_footstep_by_actor_role", {}),
		"last_event": last_event,
		"last_cue": last_cue,
		"audio_roles": full.get("audio_roles", {}),
		"audio_concurrency_limits": full.get("audio_concurrency_limits", {}),
		"retained_voice_receipt_count": _retained_voice_receipts.size(),
		"presentation_only": true,
		"authoritative_calls": [],
	}
