class_name FPSShotFeedback3D
extends Node3D

## Idempotent presentation-only observer for immutable player/enemy shot events.
## Ammo, hit resolution, damage and score are committed before this listener runs.

signal shot_presented(event: Dictionary)
signal trace_spawned(event: Dictionary, effect: Node3D)
signal impact_spawned(event: Dictionary, effect: Node3D)

const AUDIO_RECEIPT_LIMIT := 64
const SHOT_AUDIO: AudioStream = preload("res://systems/weapons/viewmodels/ak74/audio/sfx_fire_single.wav")
const CHARACTER_IMPACT_AUDIO: AudioStream = preload("res://assets/audio/combat/deathpunch.wav")
const METAL_IMPACT_AUDIO: AudioStream = preload("res://assets/audio/combat/metal_twang.wav")
const CONCRETE_IMPACT_AUDIO: AudioStream = preload("res://assets/audio/combat/hammer_fall.wav")
const NEAR_MISS_AUDIO: AudioStream = preload("res://assets/audio/combat/weapon_whoosh.wav")

@export_node_path("FPSHitscanWeapon") var hitscan_weapon_path: NodePath
@export_range(0.02, 0.5, 0.01) var muzzle_seconds := 0.075
@export_range(0.03, 0.5, 0.01) var tracer_seconds := 0.11
@export_range(0.05, 1.0, 0.01) var impact_seconds := 0.38
@export_range(4, 64, 1) var max_active_effects := 28
@export_range(8, 128, 1) var event_cache_limit := 48
@export_range(1.0, 8.0, 0.1) var max_tracer_length := 2.6
@export var player_tracer_color := Color(1.0, 0.76, 0.28, 0.86)
@export var enemy_tracer_color := Color(1.0, 0.16, 0.035, 0.94)

var active_effect_count := 0
var presented_event_count := 0
var duplicate_event_count := 0
var last_event: Dictionary = {}
var current_run_epoch := 0
var lifetime_presented_event_count := 0
var lifetime_duplicate_event_count := 0

var _hitscan: FPSHitscanWeapon
var _observed_ids: Dictionary = {}
var _observed_order: Array[String] = []
var _active_effect_tokens: Array[int] = []
var _effect_records: Dictionary = {}
var _retired_effect_tokens: Dictionary = {}
var _retired_effect_order: Array[int] = []
var _effect_serial := 0
var _effect_cleanup_count := 0
var _duplicate_cleanup_callback_count := 0
var _invalidated_retirement_callback_count := 0
var _effect_cleanup_history: Array[Dictionary] = []
var _shot_audio: AudioStream = SHOT_AUDIO
var _character_impact_audio: AudioStream = CHARACTER_IMPACT_AUDIO
var _metal_impact_audio: AudioStream = METAL_IMPACT_AUDIO
var _concrete_impact_audio: AudioStream = CONCRETE_IMPACT_AUDIO
var _near_miss_audio: AudioStream = NEAR_MISS_AUDIO
var _last_presentation: Dictionary = {}
var _variant_use_counts := {0: 0, 1: 0, 2: 0, 3: 0}
var _culled_effect_count := 0
var _local_impact_suppression_count := 0
var _player_report_suppression_count := 0
var _audio_receipts: Array[Dictionary] = []
var _audio_cleanup_count := 0


func _ready() -> void:
	_hitscan = get_node_or_null(hitscan_weapon_path) as FPSHitscanWeapon if not hitscan_weapon_path.is_empty() else null
	if _hitscan != null:
		_hitscan.shot_resolved.connect(show_shot)


func show_shot(event: Dictionary) -> bool:
	var accepted := bool(event.get("accepted", false)) or int(event.get("ammo_commit", 0)) == 1
	var shot_id := String(event.get("shot_id", ""))
	if not accepted or shot_id.is_empty():
		return false
	var event_identity := _event_identity(event, shot_id)
	if _observed_ids.has(event_identity):
		duplicate_event_count += 1
		lifetime_duplicate_event_count += 1
		return false
	_remember_event(event_identity)
	presented_event_count += 1
	lifetime_presented_event_count += 1

	var from: Vector3 = event.get("muzzle_origin", event.get("origin", global_position))
	var direction: Vector3 = event.get("direction", Vector3.FORWARD)
	if direction.is_zero_approx():
		direction = Vector3.FORWARD
	var to: Vector3 = event.get("hit_position", from + direction.normalized() * float(event.get("range_meters", 24.0)))
	var source_team := StringName(event.get("source_team", &"player"))
	var tracer_color := enemy_tracer_color if source_team == &"enemy" else player_tracer_color
	var result := StringName(event.get("result", &"hit" if bool(event.get("hit", false)) else &"miss"))
	var surface := StringName(event.get("surface_kind", &"character" if result == &"hit" else &"air"))
	var local_player_hit := _is_local_player_hit(event, source_team, result, surface)
	var variant_index := (presented_event_count - 1) % 4
	_variant_use_counts[variant_index] = int(_variant_use_counts.get(variant_index, 0)) + 1
	var trace_clip := _clip_trace_endpoint_for_camera(from, to, local_player_hit)
	var trace_to: Vector3 = trace_clip.get("endpoint", to)
	var roles: Array[StringName] = [&"compact_muzzle", &"near_miss" if result == &"miss" else &"bounded_tracer"]
	var player_report_suppressed := source_team == &"player"
	if player_report_suppressed:
		_player_report_suppression_count += 1
	else:
		roles.append(&"spatial_report_audio")
	_spawn_muzzle(from, direction, tracer_color, event, variant_index)
	_spawn_tracer(from, trace_to, tracer_color, event, result, variant_index)
	var world_impact_suppressed := false
	var suppression_reason := &""
	if local_player_hit:
		world_impact_suppressed = true
		suppression_reason = &"local_player_camera_near_plane"
		_local_impact_suppression_count += 1
		roles.append(&"local_player_directional_damage")
		roles.append(&"local_player_body_or_armor_audio")
	elif result in [&"hit", &"blocked"]:
		_spawn_impact(to, event)
		roles.append(&"character_hit" if surface == &"character" else &"metal_sparks" if surface == &"metal" else &"concrete_dust")
		roles.append(&"surface_impact_audio")
	_spawn_audio(from, to, result, surface, source_team, local_player_hit, event_identity)
	_last_presentation = {
		"shot_id": shot_id,
		"event_identity": event_identity,
		"run_epoch": int(event.get("run_epoch", current_run_epoch)),
		"source_actor": String(event.get("actor_id", event.get("source_path", ""))),
		"source_weapon": String(event.get("weapon_id", "")),
		"result": result,
		"surface": surface,
		"target_path": String(event.get("target_path", "")),
		"ammo_commit": int(event.get("ammo_commit", 0)),
		"damage_applied": event.get("applied", false) == true,
		"occlusion_outcome": result,
		"muzzle_position": from,
		"hit_position": to,
		"trace_endpoint": trace_to,
		"trace_camera_clip": trace_clip,
		"local_player_hit": local_player_hit,
		"world_impact_suppressed": world_impact_suppressed,
		"suppression_reason": suppression_reason,
		"player_report_suppressed": player_report_suppressed,
		"report_audio_owner": &"weapon_component_fire_audio" if player_report_suppressed else &"enemy_spatial_feedback",
		"roles": roles,
		"variant_index": variant_index,
		"effect_lifetimes": {"muzzle": muzzle_seconds, "tracer": tracer_seconds, "impact": 0.0 if world_impact_suppressed else impact_seconds},
		"concurrency": {"active": active_effect_count, "limit": max_active_effects, "culled_total": _culled_effect_count},
		"presentation_count": presented_event_count,
		"duplicate_count": duplicate_event_count,
		"authority_frame": int(event.get("committed_frame", Engine.get_process_frames())),
		"authority_usec": int(event.get("committed_at_usec", event.get("timestamp_usec", Time.get_ticks_usec()))),
		"observed_frame": Engine.get_process_frames(),
		"observed_usec": Time.get_ticks_usec(),
		"presentation_only": true,
	}
	_last_presentation["latency_frames"] = maxi(int(_last_presentation["observed_frame"]) - int(_last_presentation["authority_frame"]), 0)
	_last_presentation["within_two_rendered_frames"] = int(_last_presentation["latency_frames"]) <= 2
	last_event = event.duplicate(true)
	last_event["presentation"] = _last_presentation.duplicate(true)
	shot_presented.emit(event.duplicate(true))
	return true


func begin_run_epoch(epoch: int) -> void:
	current_run_epoch = maxi(epoch, 0)
	reset_feedback(current_run_epoch)


func reset_feedback(epoch := -1) -> void:
	if epoch >= 0:
		current_run_epoch = epoch
	for token: int in _active_effect_tokens.duplicate():
		_retire_effect_token(token, &"reset")
	_active_effect_tokens.clear()
	_effect_records.clear()
	active_effect_count = 0
	_observed_ids.clear()
	_observed_order.clear()
	last_event.clear()
	_last_presentation.clear()
	presented_event_count = 0
	duplicate_event_count = 0
	_variant_use_counts = {0: 0, 1: 0, 2: 0, 3: 0}
	_culled_effect_count = 0
	_local_impact_suppression_count = 0
	_player_report_suppression_count = 0


func snapshot() -> Dictionary:
	return {
		"family_id": &"enemy_shot_feedback_vfx",
		"run_epoch": current_run_epoch,
		"presented_event_count": presented_event_count,
		"duplicate_event_count": duplicate_event_count,
		"lifetime_presented_event_count": lifetime_presented_event_count,
		"lifetime_duplicate_event_count": lifetime_duplicate_event_count,
		"active_effect_count": active_effect_count,
		"cached_event_count": _observed_ids.size(),
		"last_event": last_event,
		"last_presentation": _last_presentation,
		"active_effects": _active_effect_snapshot(),
		"max_active_effects": max_active_effects,
		"max_tracer_length": max_tracer_length,
		"runtime_variant_count": 4,
		"variant_use_counts": _variant_use_counts,
		"max_single_variant_share": _max_variant_share(),
		"culled_effect_count": _culled_effect_count,
		"local_impact_suppression_count": _local_impact_suppression_count,
		"player_report_suppression_count": _player_report_suppression_count,
		"player_report_audio_created": false,
		"enemy_report_audio_owner": &"spatial_report_audio",
		"audio_receipts": _audio_receipts.duplicate(true),
		"audio_receipt_limit": AUDIO_RECEIPT_LIMIT,
		"active_audio_voice_count": _active_audio_voice_count(),
		"decoded_audio_voice_count": _decoded_audio_voice_count(),
		"audio_cleanup_count": _audio_cleanup_count,
		"effect_cleanup_count": _effect_cleanup_count,
		"duplicate_cleanup_callback_count": _duplicate_cleanup_callback_count,
		"invalidated_retirement_callback_count": _invalidated_retirement_callback_count,
		"effect_cleanup_history": _effect_cleanup_history.duplicate(true),
		"retirement_authority": &"token_scoped_cancellable_owner",
		"variant_roles": [&"compact_muzzle", &"bounded_tracer", &"near_miss", &"character_hit", &"metal_sparks", &"concrete_dust"],
	}


func _remember_event(shot_id: String) -> void:
	_observed_ids[shot_id] = true
	_observed_order.append(shot_id)
	while _observed_order.size() > event_cache_limit:
		_observed_ids.erase(_observed_order.pop_front())


func _event_identity(event: Dictionary, shot_id: String) -> String:
	var event_epoch := int(event.get("run_epoch", current_run_epoch))
	return "run-%06d:%s" % [event_epoch, shot_id]


func _spawn_muzzle(position: Vector3, direction: Vector3, color: Color, event: Dictionary, variant_index: int) -> void:
	var root := Node3D.new()
	root.name = "Muzzle_%s" % _safe_id(event)
	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.038 + 0.004 * float(variant_index)
	core_mesh.height = 0.08 + 0.01 * float(variant_index % 2)
	core_mesh.radial_segments = 10
	core_mesh.rings = 5
	core_mesh.material = _energy_material(Color(1.0, 0.87, 0.5, 0.96), 7.5)
	core.mesh = core_mesh
	root.add_child(core)
	var flame := MeshInstance3D.new()
	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.008
	flame_mesh.bottom_radius = 0.035
	flame_mesh.height = 0.15 + 0.025 * float(variant_index)
	flame_mesh.radial_segments = 8
	flame_mesh.material = _energy_material(color, 5.2)
	flame.mesh = flame_mesh
	flame.basis = _basis_from_up(direction)
	flame.position = direction.normalized() * 0.07
	root.add_child(flame)
	var retirement_token := _add_effect(root, &"compact_muzzle", muzzle_seconds)
	root.global_position = position + direction.normalized() * 0.035
	root.scale = Vector3.ONE * 0.7
	var tween := root.create_tween().set_parallel(true)
	tween.tween_property(root, "scale", Vector3.ONE, muzzle_seconds)
	_bind_effect_retirement(retirement_token, tween, &"finished", &"tween_finished")


func _spawn_tracer(from: Vector3, to: Vector3, color: Color, event: Dictionary, result: StringName, variant_index: int) -> void:
	var delta := to - from
	var distance := delta.length()
	if distance <= 0.02:
		return
	var direction := delta.normalized()
	var visible_length := minf(distance, 0.8 if result == &"miss" else max_tracer_length)
	var segment_to := to
	var segment_from := segment_to - direction * visible_length
	var tracer := MeshInstance3D.new()
	var role := &"near_miss" if result == &"miss" else &"bounded_tracer"
	tracer.name = "%s_%s" % [String(role).to_pascal_case(), _safe_id(event)]
	var mesh := CylinderMesh.new()
	mesh.top_radius = (0.0058 + 0.0005 * float(variant_index)) if StringName(event.get("source_team", &"player")) == &"enemy" else 0.005
	mesh.bottom_radius = mesh.top_radius
	mesh.height = visible_length
	mesh.radial_segments = 6
	mesh.material = _energy_material(color, 2.4 if result == &"miss" else 3.2)
	tracer.mesh = mesh
	var retirement_token := _add_effect(tracer, role, tracer_seconds)
	tracer.global_position = segment_from.lerp(segment_to, 0.5)
	tracer.global_basis = _basis_from_up(direction)
	trace_spawned.emit(event, tracer)
	var tween := tracer.create_tween().set_parallel(true)
	tween.tween_property(tracer, "transparency", 1.0, tracer_seconds)
	tween.tween_property(tracer, "scale", Vector3(0.25, 0.35, 0.25), tracer_seconds)
	_bind_effect_retirement(retirement_token, tween, &"finished", &"tween_finished")


func _spawn_impact(position: Vector3, event: Dictionary) -> void:
	var surface := StringName(event.get("surface_kind", &"character" if bool(event.get("hit", false)) else &"concrete"))
	var root := Node3D.new()
	root.name = "Impact_%s_%s" % [surface, _safe_id(event)]
	match surface:
		&"character":
			_build_character_impact(root)
		&"metal":
			_build_metal_impact(root)
		_:
			_build_concrete_impact(root)
	var impact_role := &"character_hit" if surface == &"character" else &"metal_sparks" if surface == &"metal" else &"concrete_dust"
	var retirement_token := _add_effect(root, impact_role, impact_seconds)
	root.global_position = position
	var normal: Vector3 = event.get("hit_normal", Vector3.UP)
	if not normal.is_zero_approx():
		root.global_basis = _basis_from_up(normal)
	# Assign scale after the orientation basis; setting global_basis replaces scale.
	root.scale = Vector3.ONE
	impact_spawned.emit(event, root)
	var tween := root.create_tween().set_parallel(true)
	var target_scale := 0.82 if surface == &"character" else 1.05
	tween.tween_property(root, "scale", Vector3.ONE * target_scale, impact_seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(root, "rotation:y", root.rotation.y + 0.8, impact_seconds)
	_bind_effect_retirement(retirement_token, tween, &"finished", &"tween_finished")


func _build_character_impact(root: Node3D) -> void:
	var core := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.09
	mesh.height = 0.18
	mesh.radial_segments = 10
	mesh.rings = 5
	mesh.material = _energy_material(Color(1.0, 0.24, 0.06, 0.9), 4.8)
	core.mesh = mesh
	root.add_child(core)
	for angle_index in 4:
		var shard := MeshInstance3D.new()
		var shard_mesh := BoxMesh.new()
		shard_mesh.size = Vector3(0.025, 0.2, 0.025)
		shard_mesh.material = _energy_material(Color(1.0, 0.58, 0.15, 0.86), 3.5)
		shard.mesh = shard_mesh
		shard.rotation.z = float(angle_index) * PI * 0.5
		shard.position.y = 0.1
		root.add_child(shard)


func _build_metal_impact(root: Node3D) -> void:
	for spark_index in 7:
		var spark := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.018, 0.22 + 0.035 * float(spark_index % 3), 0.018)
		mesh.material = _energy_material(Color(1.0, 0.72, 0.24, 0.92), 5.0)
		spark.mesh = mesh
		spark.rotation = Vector3(0.0, float(spark_index) * TAU / 7.0, 0.35 + 0.08 * float(spark_index % 2))
		spark.position = Vector3.UP * 0.08
		root.add_child(spark)


func _build_concrete_impact(root: Node3D) -> void:
	var dust := MeshInstance3D.new()
	var dust_mesh := SphereMesh.new()
	dust_mesh.radius = 0.12
	dust_mesh.height = 0.11
	dust_mesh.radial_segments = 9
	dust_mesh.rings = 4
	dust_mesh.material = _alpha_material(Color(0.48, 0.42, 0.32, 0.62), 1.0)
	dust.mesh = dust_mesh
	root.add_child(dust)
	for chip_index in 5:
		var chip := MeshInstance3D.new()
		var chip_mesh := BoxMesh.new()
		chip_mesh.size = Vector3.ONE * (0.025 + float(chip_index % 2) * 0.014)
		chip_mesh.material = _alpha_material(Color(0.42, 0.39, 0.34, 0.9), 0.0)
		chip.mesh = chip_mesh
		var angle := float(chip_index) * TAU / 5.0
		chip.position = Vector3(cos(angle), 0.3, sin(angle)) * 0.12
		root.add_child(chip)


func _spawn_audio(muzzle_position: Vector3, impact_position: Vector3, result: StringName, surface: StringName, source_team: StringName, local_player_hit: bool, event_identity: String) -> void:
	# The retained viewmodel's FireAudio/AutoFireAudio pair is the sole player
	# report owner. This generic presenter keeps muzzle/tracer/impact feedback for
	# player events, but only enemy events may create a spatial weapon report.
	if source_team == &"enemy":
		_spawn_audio_cue(muzzle_position, _get_shot_audio(), &"spatial_report_audio", -5.0, 0.92, event_identity)
	if result == &"miss":
		_spawn_audio_cue(impact_position, _get_near_miss_audio(), &"near_miss_audio", -10.0, 1.0, event_identity)
	elif result in [&"hit", &"blocked"] and not local_player_hit:
		var stream := _get_character_impact_audio() if surface == &"character" else _get_metal_impact_audio() if surface == &"metal" else _get_concrete_impact_audio()
		_spawn_audio_cue(impact_position, stream, &"surface_impact_audio", -8.0, 1.0, event_identity)


func _spawn_audio_cue(position: Vector3, stream: AudioStream, role: StringName, volume_db: float, pitch: float, event_identity: String) -> void:
	if stream == null:
		return
	var audio_root := Node3D.new()
	var receipt_id := "%s:%s:%d" % [event_identity, role, Time.get_ticks_usec()]
	audio_root.name = "%s_%s" % [String(role).to_pascal_case(), _safe_receipt_id(receipt_id)]
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.bus = &"Combat"
	player.volume_db = volume_db
	player.unit_size = 6.0
	player.max_distance = 42.0
	player.pitch_scale = pitch
	audio_root.add_child(player)
	var lifetime := clampf(stream.get_length(), 0.3, 2.2)
	audio_root.set_meta(&"audio_receipt_id", receipt_id)
	var retirement_token := _add_effect(audio_root, role, lifetime)
	audio_root.global_position = position
	player.play()
	_append_audio_receipt({
		"receipt_id": receipt_id,
		"event_identity": event_identity,
		"run_epoch": current_run_epoch,
		"role": role,
		"bus": player.bus,
		"voice_path": String(player.get_path()),
		"stream_bound": player.stream != null,
		"decoded": not stream.resource_path.is_empty(),
		"stream_path": stream.resource_path,
		"generated": false,
		"onset_usec": Time.get_ticks_usec(),
		"onset_frame": Engine.get_process_frames(),
		"playing_at_onset": player.playing,
		"world_origin": position,
		"spatial": true,
		"attenuation": {"unit_size": player.unit_size, "max_distance": player.max_distance},
		"volume_db": volume_db,
		"pitch_scale": pitch,
		"lifetime_seconds": lifetime,
		"cleanup_observed": false,
		"cleanup_usec": 0,
	})
	var retirement_timer := get_tree().create_timer(lifetime)
	_bind_effect_retirement(retirement_token, retirement_timer, &"timeout", &"timer_timeout")


func _add_effect(effect: Node3D, role: StringName, lifetime: float) -> int:
	while _active_effect_tokens.size() >= max_active_effects:
		_culled_effect_count += 1
		_retire_effect_token(_active_effect_tokens.front(), &"capacity_cull")
	var target := get_tree().current_scene
	if target == null:
		target = get_tree().root
	target.add_child(effect)
	effect.add_to_group(&"combat_event_feedback")
	effect.set_meta(&"presenter_id", get_instance_id())
	effect.set_meta(&"effect_role", role)
	effect.set_meta(&"effect_lifetime_seconds", lifetime)
	_effect_serial += 1
	var retirement_token := _effect_serial
	effect.set_meta(&"retirement_token", retirement_token)
	_effect_records[retirement_token] = {
		"instance_id": effect.get_instance_id(),
		"role": role,
		"receipt_id": String(effect.get_meta(&"audio_receipt_id", "")),
		"created_usec": Time.get_ticks_usec(),
		"run_epoch": current_run_epoch,
		"retirement_generation": 0,
		"owner_source": null,
		"owner_signal": &"",
		"owner_callback": Callable(),
	}
	_active_effect_tokens.append(retirement_token)
	active_effect_count = _active_effect_tokens.size()
	return retirement_token


func _bind_effect_retirement(retirement_token: int, owner_source: Object, owner_signal: StringName, reason: StringName) -> void:
	if not _effect_records.has(retirement_token) or owner_source == null:
		return
	var record: Dictionary = _effect_records[retirement_token]
	var generation := int(record.get("retirement_generation", 0)) + 1
	var owner_callback := _retire_effect_from_owner.bind(retirement_token, generation, reason)
	record["retirement_generation"] = generation
	record["owner_source"] = owner_source
	record["owner_signal"] = owner_signal
	record["owner_callback"] = owner_callback
	_effect_records[retirement_token] = record
	owner_source.connect(owner_signal, owner_callback, CONNECT_ONE_SHOT)


func _retire_effect_from_owner(retirement_token: int, generation: int, reason: StringName) -> void:
	if not _effect_records.has(retirement_token):
		_invalidated_retirement_callback_count += 1
		return
	var record: Dictionary = _effect_records[retirement_token]
	if int(record.get("retirement_generation", 0)) != generation:
		_invalidated_retirement_callback_count += 1
		return
	_retire_effect_token(retirement_token, reason, true)


func _cancel_effect_retirement_owner(record: Dictionary) -> void:
	var owner_source := record.get("owner_source") as Object
	var owner_signal := StringName(record.get("owner_signal", &""))
	var owner_callback: Callable = record.get("owner_callback", Callable())
	if owner_source != null and not owner_signal.is_empty() and owner_callback.is_valid() and owner_source.is_connected(owner_signal, owner_callback):
		owner_source.disconnect(owner_signal, owner_callback)
	if owner_source is Tween:
		var owner_tween := owner_source as Tween
		if owner_tween.is_valid():
			owner_tween.kill()


func _retire_effect_token(retirement_token: int, reason: StringName = &"completion", from_owner := false) -> bool:
	# Completion callbacks bind only an integer identity, never a Node3D that may
	# have been queue_freed by capacity culling, restore, or lifecycle reset.
	# Capacity, reset, and restore retirement disconnect or kill the registered
	# owner before freeing the node, so one identity has exactly one callback.
	if not _effect_records.has(retirement_token):
		_duplicate_cleanup_callback_count += 1
		return false
	var record: Dictionary = _effect_records.get(retirement_token, {})
	if not from_owner:
		_cancel_effect_retirement_owner(record)
	_effect_records.erase(retirement_token)
	_active_effect_tokens.erase(retirement_token)
	active_effect_count = _active_effect_tokens.size()
	var receipt_id := String(record.get("receipt_id", ""))
	if not receipt_id.is_empty():
		_mark_audio_cleanup(receipt_id)
	var instance_id := int(record.get("instance_id", 0))
	if instance_id > 0 and is_instance_id_valid(instance_id):
		var instance := instance_from_id(instance_id)
		if instance is Node:
			(instance as Node).queue_free()
	_effect_cleanup_count += 1
	_retired_effect_tokens[retirement_token] = true
	_retired_effect_order.append(retirement_token)
	while _retired_effect_order.size() > event_cache_limit * 2:
		_retired_effect_tokens.erase(_retired_effect_order.pop_front())
	_effect_cleanup_history.append({
		"retirement_token": retirement_token,
		"role": record.get("role", &"unknown"),
		"run_epoch": record.get("run_epoch", current_run_epoch),
		"reason": reason,
		"cleanup_usec": Time.get_ticks_usec(),
		"cleanup_count_for_identity": 1,
	})
	while _effect_cleanup_history.size() > event_cache_limit:
		_effect_cleanup_history.pop_front()
	return true


func _append_audio_receipt(receipt: Dictionary) -> void:
	_audio_receipts.append(receipt)
	while _audio_receipts.size() > AUDIO_RECEIPT_LIMIT:
		_audio_receipts.pop_front()


func _mark_audio_cleanup(receipt_id: String) -> void:
	for index in range(_audio_receipts.size() - 1, -1, -1):
		if String(_audio_receipts[index].get("receipt_id", "")) != receipt_id:
			continue
		if _audio_receipts[index].get("cleanup_observed", false) == true:
			return
		_audio_receipts[index]["cleanup_observed"] = true
		_audio_receipts[index]["cleanup_usec"] = Time.get_ticks_usec()
		_audio_receipts[index]["voice_lifetime_usec"] = maxi(int(_audio_receipts[index]["cleanup_usec"]) - int(_audio_receipts[index]["onset_usec"]), 0)
		_audio_cleanup_count += 1
		return


func _active_audio_voice_count() -> int:
	var count := 0
	for retirement_token: int in _active_effect_tokens:
		var record: Dictionary = _effect_records.get(retirement_token, {})
		if not String(record.get("receipt_id", "")).is_empty():
			count += 1
	return count


func _decoded_audio_voice_count() -> int:
	var count := 0
	for receipt: Dictionary in _audio_receipts:
		if receipt.get("decoded", false) == true:
			count += 1
	return count


func _safe_receipt_id(receipt_id: String) -> String:
	return receipt_id.replace(":", "_").replace("-", "_")


func _active_effect_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for retirement_token: int in _active_effect_tokens:
		var record: Dictionary = _effect_records.get(retirement_token, {})
		var instance_id := int(record.get("instance_id", 0))
		if instance_id <= 0 or not is_instance_id_valid(instance_id):
			continue
		var effect := instance_from_id(instance_id) as Node3D
		if effect == null:
			continue
		result.append({
			"retirement_token": retirement_token,
			"name": effect.name,
			"role": StringName(effect.get_meta(&"effect_role", &"unknown")),
			"lifetime_seconds": float(effect.get_meta(&"effect_lifetime_seconds", 0.0)),
		})
	return result


func _is_local_player_hit(event: Dictionary, source_team: StringName, result: StringName, surface: StringName) -> bool:
	if source_team != &"enemy" or result != &"hit" or surface != &"character":
		return false
	var target_path := NodePath(String(event.get("target_path", "")))
	var target := get_node_or_null(target_path) if not target_path.is_empty() else null
	return target != null and (target.is_in_group(&"player") or target.is_in_group(&"fps_player"))


func _clip_trace_endpoint_for_camera(from: Vector3, to: Vector3, force_clip: bool) -> Dictionary:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return {"endpoint": to, "clipped": false, "reason": &"camera_unavailable"}
	var original_clearance := to.distance_to(camera.global_position)
	var safe_clearance := maxf(0.7, camera.near * 12.0)
	if not force_clip or original_clearance >= safe_clearance:
		return {"endpoint": to, "clipped": false, "camera_clearance": original_clearance, "required_clearance": safe_clearance}
	var direction := from.direction_to(to)
	if direction.is_zero_approx():
		direction = -camera.global_basis.z
	var clipped_endpoint := camera.global_position - direction * safe_clearance
	return {
		"endpoint": clipped_endpoint,
		"clipped": true,
		"reason": &"local_player_near_plane_guard",
		"camera_clearance": clipped_endpoint.distance_to(camera.global_position),
		"required_clearance": safe_clearance,
	}


func _max_variant_share() -> float:
	var total := 0
	var maximum := 0
	for variant_index in _variant_use_counts:
		var count := int(_variant_use_counts[variant_index])
		total += count
		maximum = maxi(maximum, count)
	return 0.0 if total <= 0 else float(maximum) / float(total)


func _energy_material(color: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b)
	material.emission_energy_multiplier = energy
	return material


func _alpha_material(color: Color, emission_energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.roughness = 0.9
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = Color(color.r, color.g, color.b)
		material.emission_energy_multiplier = emission_energy
	return material


func _basis_from_up(direction: Vector3) -> Basis:
	var up := direction.normalized()
	var tangent := Vector3.FORWARD.cross(up)
	if tangent.is_zero_approx():
		tangent = Vector3.RIGHT
	tangent = tangent.normalized()
	return Basis(tangent, up, up.cross(tangent).normalized()).orthonormalized()


func _safe_id(event: Dictionary) -> String:
	return String(event.get("shot_id", "shot")).replace(":", "_").replace("-", "_")


func _get_shot_audio() -> AudioStream:
	return _shot_audio


func _get_character_impact_audio() -> AudioStream:
	return _character_impact_audio


func _get_metal_impact_audio() -> AudioStream:
	return _metal_impact_audio


func _get_concrete_impact_audio() -> AudioStream:
	return _concrete_impact_audio


func _get_near_miss_audio() -> AudioStream:
	return _near_miss_audio


func _mcp_state() -> Dictionary:
	return snapshot()
