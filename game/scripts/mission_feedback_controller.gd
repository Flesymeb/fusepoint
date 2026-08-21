class_name FusepointMissionFeedbackController
extends CanvasLayer

## Presentation-only, idempotent observer of immutable MissionController events.
## This node never submits objective, checkpoint, score, damage, or terminal state.

signal mission_cue_presented(receipt: Dictionary)

const CACHE_LIMIT := 128
const WARNING_THRESHOLDS: Array[int] = [30, 15, 10, 5]

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
var _audio_streams: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_audio_player = AudioStreamPlayer.new()
	_audio_player.name = "MissionCueAudio"
	add_child(_audio_player)
	cue_root.visible = false
	cue_root.modulate = Color(1.0, 1.0, 1.0, 0.0)
	_mission = get_node_or_null(mission_path) if not mission_path.is_empty() else null
	if _mission != null and _mission.has_signal(&"mission_event_committed"):
		_mission.connect(&"mission_event_committed", present_event)


func _process(delta: float) -> void:
	active_lifetime_remaining = maxf(0.0, active_lifetime_remaining - delta)
	if active_lifetime_remaining <= 0.0:
		active_cue_count = 0


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
	_remember_event(event_id)
	if active_cue_count > 0:
		concurrency_cull_count += 1
		_clear_active_cue()
	presented_event_count += 1
	var family := StringName(cue.get("family", &"route"))
	_variant_use_counts[family] = int(_variant_use_counts.get(family, 0)) + 1
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
	_clear_active_cue()
	_warning_thresholds_seen.clear()
	last_event.clear()
	last_cue.clear()
	if clear_history:
		_observed_ids.clear()
		_observed_order.clear()
		_last_sequence = 0
	if _audio_player != null:
		_audio_player.stop()


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
	_play_audio(StringName(cue.get("family", &"route")), int(cue.get("priority", 1)))
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


func _play_audio(family: StringName, priority: int) -> void:
	if not _audio_streams.has(family):
		var profile: Array = {
			&"capture": [420.0, 0.2, 0.08],
			&"route": [620.0, 0.26, 0.05],
			&"defusal": [310.0, 0.22, 0.10],
			&"warning": [176.0, 0.30, 0.12],
			&"terminal": [760.0, 0.28, 0.08],
		}.get(family, [440.0, 0.2, 0.08])
		_audio_streams[family] = _synth_cue(0.18 if family != &"terminal" else 0.32, float(profile[0]), float(profile[1]), float(profile[2]))
	_audio_player.stream = _audio_streams[family]
	_audio_player.volume_db = -9.0 + minf(float(priority), 8.0) * 0.35
	_audio_player.pitch_scale = 0.92 if family == &"warning" else 1.0
	_audio_player.play()


func _synth_cue(duration: float, frequency: float, tone_gain: float, noise_gain: float) -> AudioStreamWAV:
	const MIX_RATE := 22050
	var sample_count := int(MIX_RATE * duration)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	for sample_index in sample_count:
		var t := float(sample_index) / float(MIX_RATE)
		var progress := float(sample_index) / float(sample_count)
		var decay := pow(1.0 - progress, 1.8)
		var overtone := sin(TAU * frequency * 1.5 * t) * tone_gain * 0.35
		var tone := sin(TAU * frequency * t) * tone_gain + overtone
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
