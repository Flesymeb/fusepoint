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
var _impact_audio: AudioStreamWAV


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
	last_event = event.duplicate(true)
	presented_event_count += 1

	var from: Vector3 = event.get("muzzle_origin", event.get("origin", global_position))
	var direction: Vector3 = event.get("direction", Vector3.FORWARD)
	if direction.is_zero_approx():
		direction = Vector3.FORWARD
	var to: Vector3 = event.get("hit_position", from + direction.normalized() * float(event.get("range_meters", 24.0)))
	var source_team := StringName(event.get("source_team", &"player"))
	var tracer_color := enemy_tracer_color if source_team == &"enemy" else player_tracer_color
	_spawn_muzzle(from, direction, tracer_color, event)
	_spawn_tracer(from, to, tracer_color, event)
	var result := StringName(event.get("result", &"hit" if bool(event.get("hit", false)) else &"miss"))
	if result in [&"hit", &"blocked"]:
		_spawn_impact(to, event)
	_spawn_audio(from, result, source_team)
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


func snapshot() -> Dictionary:
	return {
		"family_id": &"combat_event_feedback",
		"presented_event_count": presented_event_count,
		"duplicate_event_count": duplicate_event_count,
		"active_effect_count": active_effect_count,
		"cached_event_count": _observed_ids.size(),
		"last_event": last_event,
		"variant_roles": [&"muzzle_cross", &"ballistic_tracer", &"character_hit", &"metal_sparks", &"concrete_dust"],
	}


func _remember_event(shot_id: String) -> void:
	_observed_ids[shot_id] = true
	_observed_order.append(shot_id)
	while _observed_order.size() > event_cache_limit:
		_observed_ids.erase(_observed_order.pop_front())


func _spawn_muzzle(position: Vector3, direction: Vector3, color: Color, event: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Muzzle_%s" % _safe_id(event)
	var core := MeshInstance3D.new()
	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.085
	core_mesh.height = 0.17
	core_mesh.radial_segments = 10
	core_mesh.rings = 5
	core_mesh.material = _energy_material(Color(1.0, 0.87, 0.5, 0.96), 7.5)
	core.mesh = core_mesh
	root.add_child(core)
	for axis in [Vector3.RIGHT, Vector3.UP]:
		var streak := MeshInstance3D.new()
		var streak_mesh := CylinderMesh.new()
		streak_mesh.top_radius = 0.012
		streak_mesh.bottom_radius = 0.055
		streak_mesh.height = 0.42
		streak_mesh.radial_segments = 6
		streak_mesh.material = _energy_material(color, 5.2)
		streak.mesh = streak_mesh
		streak.basis = _basis_from_up(axis)
		root.add_child(streak)
	_add_effect(root)
	root.global_position = position + direction.normalized() * 0.035
	root.scale = Vector3.ONE * 0.45
	var tween := root.create_tween().set_parallel(true)
	tween.tween_property(root, "scale", Vector3.ONE * 1.35, muzzle_seconds)
	tween.finished.connect(_retire_effect.bind(root))


func _spawn_tracer(from: Vector3, to: Vector3, color: Color, event: Dictionary) -> void:
	var delta := to - from
	var distance := delta.length()
	if distance <= 0.02:
		return
	var tracer := MeshInstance3D.new()
	tracer.name = "Tracer_%s" % _safe_id(event)
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.012 if StringName(event.get("source_team", &"player")) == &"enemy" else 0.009
	mesh.bottom_radius = mesh.top_radius
	mesh.height = distance
	mesh.radial_segments = 6
	mesh.material = _energy_material(color, 4.2)
	tracer.mesh = mesh
	_add_effect(tracer)
	tracer.global_position = from.lerp(to, 0.5)
	tracer.global_basis = _basis_from_up(delta)
	trace_spawned.emit(event, tracer)
	var tween := tracer.create_tween().set_parallel(true)
	tween.tween_property(tracer, "transparency", 1.0, tracer_seconds)
	tween.tween_property(tracer, "scale", Vector3(0.35, 1.0, 0.35), tracer_seconds)
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
	_add_effect(root)
	root.global_position = position
	var near_player_hit := surface == &"character" and StringName(event.get("source_team", &"player")) == &"enemy"
	var normal: Vector3 = event.get("hit_normal", Vector3.UP)
	if not normal.is_zero_approx():
		root.global_basis = _basis_from_up(normal)
	# Assign scale after the orientation basis; setting global_basis replaces scale.
	root.scale = Vector3.ONE * (0.22 if near_player_hit else 1.0)
	impact_spawned.emit(event, root)
	var tween := root.create_tween().set_parallel(true)
	var target_scale := 0.52 if near_player_hit else (1.8 if surface == &"character" else 2.4)
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


func _spawn_audio(position: Vector3, result: StringName, source_team: StringName) -> void:
	var audio_root := Node3D.new()
	audio_root.name = "ShotAudio"
	var player := AudioStreamPlayer3D.new()
	player.stream = _get_impact_audio() if result in [&"hit", &"blocked"] else _get_shot_audio()
	player.volume_db = -5.0 if source_team == &"enemy" else -7.0
	player.unit_size = 8.0
	player.max_distance = 46.0
	player.pitch_scale = 0.92 if source_team == &"enemy" else 1.06
	audio_root.add_child(player)
	_add_effect(audio_root)
	audio_root.global_position = position
	player.play()
	get_tree().create_timer(0.42).timeout.connect(_retire_effect.bind(audio_root))


func _add_effect(effect: Node3D) -> void:
	while _active_effects.size() >= max_active_effects:
		_retire_effect(_active_effects.front())
	var target := get_tree().current_scene
	if target == null:
		target = get_tree().root
	target.add_child(effect)
	effect.add_to_group(&"combat_event_feedback")
	effect.set_meta(&"presenter_id", get_instance_id())
	_active_effects.append(effect)
	active_effect_count = _active_effects.size()


func _retire_effect(effect: Node3D) -> void:
	_active_effects.erase(effect)
	active_effect_count = _active_effects.size()
	if is_instance_valid(effect):
		effect.queue_free()


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


func _get_impact_audio() -> AudioStreamWAV:
	if _impact_audio == null:
		_impact_audio = _synth_sound(0.12, 420.0, 0.32, 0.48)
	return _impact_audio


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
