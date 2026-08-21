class_name FPSShotFeedback3D
extends Node3D

## Idempotent presentation-only observer for immutable player/enemy shot events.
## Ammo, hit resolution, damage and score are committed before this listener runs.

signal shot_presented(event: Dictionary)
signal trace_spawned(event: Dictionary, effect: Node3D)
signal impact_spawned(event: Dictionary, effect: Node3D)

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

var _hitscan: FPSHitscanWeapon
var _observed_ids: Dictionary = {}
var _observed_order: Array[String] = []
var _active_effects: Array[Node3D] = []
var _shot_audio: AudioStreamWAV
var _character_impact_audio: AudioStreamWAV
var _metal_impact_audio: AudioStreamWAV
var _concrete_impact_audio: AudioStreamWAV
var _near_miss_audio: AudioStreamWAV
var _last_presentation: Dictionary = {}
var _variant_use_counts := {0: 0, 1: 0, 2: 0, 3: 0}
var _culled_effect_count := 0
var _local_impact_suppression_count := 0


func _ready() -> void:
	_hitscan = get_node_or_null(hitscan_weapon_path) as FPSHitscanWeapon if not hitscan_weapon_path.is_empty() else null
	if _hitscan != null:
		_hitscan.shot_resolved.connect(show_shot)


func show_shot(event: Dictionary) -> bool:
	var accepted := bool(event.get("accepted", false)) or int(event.get("ammo_commit", 0)) == 1
	var shot_id := String(event.get("shot_id", ""))
	if not accepted or shot_id.is_empty():
		return false
	if _observed_ids.has(shot_id):
		duplicate_event_count += 1
		return false
	_remember_event(shot_id)
	presented_event_count += 1

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
	var roles: Array[StringName] = [&"compact_muzzle", &"near_miss" if result == &"miss" else &"bounded_tracer", &"spatial_report_audio"]
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
	_spawn_audio(from, to, result, surface, source_team, local_player_hit)
	_last_presentation = {
		"shot_id": shot_id,
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
		"roles": roles,
		"variant_index": variant_index,
		"effect_lifetimes": {"muzzle": muzzle_seconds, "tracer": tracer_seconds, "impact": 0.0 if world_impact_suppressed else impact_seconds},
		"concurrency": {"active": active_effect_count, "limit": max_active_effects, "culled_total": _culled_effect_count},
		"presentation_count": presented_event_count,
		"duplicate_count": duplicate_event_count,
	}
	last_event = event.duplicate(true)
	last_event["presentation"] = _last_presentation.duplicate(true)
	shot_presented.emit(event.duplicate(true))
	return true


func reset_feedback() -> void:
	for effect: Node3D in _active_effects.duplicate():
		if is_instance_valid(effect):
			effect.queue_free()
	_active_effects.clear()
	active_effect_count = 0
	_observed_ids.clear()
	_observed_order.clear()
	last_event.clear()
	_last_presentation.clear()


func snapshot() -> Dictionary:
	return {
		"family_id": &"enemy_shot_feedback_vfx",
		"presented_event_count": presented_event_count,
		"duplicate_event_count": duplicate_event_count,
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
		"variant_roles": [&"compact_muzzle", &"bounded_tracer", &"near_miss", &"character_hit", &"metal_sparks", &"concrete_dust"],
	}


func _remember_event(shot_id: String) -> void:
	_observed_ids[shot_id] = true
	_observed_order.append(shot_id)
	while _observed_order.size() > event_cache_limit:
		_observed_ids.erase(_observed_order.pop_front())


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
	_add_effect(root, &"compact_muzzle", muzzle_seconds)
	root.global_position = position + direction.normalized() * 0.035
	root.scale = Vector3.ONE * 0.7
	var tween := root.create_tween().set_parallel(true)
	tween.tween_property(root, "scale", Vector3.ONE, muzzle_seconds)
	tween.finished.connect(_retire_effect.bind(root))


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
	_add_effect(tracer, role, tracer_seconds)
	tracer.global_position = segment_from.lerp(segment_to, 0.5)
	tracer.global_basis = _basis_from_up(direction)
	trace_spawned.emit(event, tracer)
	var tween := tracer.create_tween().set_parallel(true)
	tween.tween_property(tracer, "transparency", 1.0, tracer_seconds)
	tween.tween_property(tracer, "scale", Vector3(0.25, 0.35, 0.25), tracer_seconds)
	tween.finished.connect(_retire_effect.bind(tracer))


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
	_add_effect(root, impact_role, impact_seconds)
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
	tween.finished.connect(_retire_effect.bind(root))


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


func _spawn_audio(muzzle_position: Vector3, impact_position: Vector3, result: StringName, surface: StringName, source_team: StringName, local_player_hit: bool) -> void:
	_spawn_audio_cue(muzzle_position, _get_shot_audio(), &"spatial_report_audio", -5.0 if source_team == &"enemy" else -7.0, 0.92 if source_team == &"enemy" else 1.06)
	if result == &"miss":
		_spawn_audio_cue(impact_position, _get_near_miss_audio(), &"near_miss_audio", -10.0, 1.0)
	elif result in [&"hit", &"blocked"] and not local_player_hit:
		var stream := _get_character_impact_audio() if surface == &"character" else _get_metal_impact_audio() if surface == &"metal" else _get_concrete_impact_audio()
		_spawn_audio_cue(impact_position, stream, &"surface_impact_audio", -8.0, 1.0)


func _spawn_audio_cue(position: Vector3, stream: AudioStreamWAV, role: StringName, volume_db: float, pitch: float) -> void:
	var audio_root := Node3D.new()
	audio_root.name = String(role).to_pascal_case()
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = volume_db
	player.unit_size = 6.0
	player.max_distance = 42.0
	player.pitch_scale = pitch
	audio_root.add_child(player)
	_add_effect(audio_root, role, 0.42)
	audio_root.global_position = position
	player.play()
	get_tree().create_timer(0.42).timeout.connect(_retire_effect.bind(audio_root))


func _add_effect(effect: Node3D, role: StringName, lifetime: float) -> void:
	while _active_effects.size() >= max_active_effects:
		_culled_effect_count += 1
		_retire_effect(_active_effects.front())
	var target := get_tree().current_scene
	if target == null:
		target = get_tree().root
	target.add_child(effect)
	effect.add_to_group(&"combat_event_feedback")
	effect.set_meta(&"presenter_id", get_instance_id())
	effect.set_meta(&"effect_role", role)
	effect.set_meta(&"effect_lifetime_seconds", lifetime)
	_active_effects.append(effect)
	active_effect_count = _active_effects.size()


func _retire_effect(effect: Node3D) -> void:
	_active_effects.erase(effect)
	active_effect_count = _active_effects.size()
	if is_instance_valid(effect):
		effect.queue_free()


func _active_effect_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for effect: Node3D in _active_effects:
		if not is_instance_valid(effect):
			continue
		result.append({
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


func _get_shot_audio() -> AudioStreamWAV:
	if _shot_audio == null:
		_shot_audio = _synth_sound(0.16, 118.0, 0.58, 0.25)
	return _shot_audio


func _get_character_impact_audio() -> AudioStreamWAV:
	if _character_impact_audio == null:
		_character_impact_audio = _synth_sound(0.11, 190.0, 0.22, 0.34)
	return _character_impact_audio


func _get_metal_impact_audio() -> AudioStreamWAV:
	if _metal_impact_audio == null:
		_metal_impact_audio = _synth_sound(0.14, 860.0, 0.42, 0.18)
	return _metal_impact_audio


func _get_concrete_impact_audio() -> AudioStreamWAV:
	if _concrete_impact_audio == null:
		_concrete_impact_audio = _synth_sound(0.16, 105.0, 0.20, 0.50)
	return _concrete_impact_audio


func _get_near_miss_audio() -> AudioStreamWAV:
	if _near_miss_audio == null:
		_near_miss_audio = _synth_sound(0.13, 1240.0, 0.18, 0.12)
	return _near_miss_audio


func _synth_sound(duration: float, frequency: float, tone_gain: float, noise_gain: float) -> AudioStreamWAV:
	const MIX_RATE := 22050
	var sample_count := int(MIX_RATE * duration)
	var bytes := PackedByteArray()
	bytes.resize(sample_count * 2)
	for sample_index in sample_count:
		var t := float(sample_index) / float(MIX_RATE)
		var progress := float(sample_index) / float(sample_count)
		var decay := pow(1.0 - progress, 2.6)
		var tone := sin(TAU * frequency * t) * tone_gain
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


func _mcp_state() -> Dictionary:
	return snapshot()
