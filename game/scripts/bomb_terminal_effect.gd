class_name FusepointBombTerminalEffect
extends Node3D

## Authored, presentation-only detonation stack. Mission authority and damage
## remain in MissionController; this scene only renders one immutable event.

const LAYER_NAMES: Array[StringName] = [
	&"flash", &"fire", &"sparks", &"debris", &"pressure_wave", &"dust", &"local_light",
]

@export var flash_material: Material
@export var fire_material: Material
@export var spark_material: Material
@export var debris_material: Material
@export var wave_material: Material
@export var dust_material: Material

@onready var flash_core: MeshInstance3D = $FlashCore
@onready var fire: GPUParticles3D = $Fire
@onready var sparks: GPUParticles3D = $Sparks
@onready var debris: GPUParticles3D = $Debris
@onready var pressure_wave: MeshInstance3D = $PressureWave
@onready var dust: GPUParticles3D = $Dust
@onready var local_light: OmniLight3D = $ExplosionLight

var terminal_event_id := ""
var authoritative_world_origin := Vector3.ZERO
var presentation_origin := Vector3.ZERO
var started_usec := 0
var started_frame := 0
var _layer_started: Dictionary = {}


func _ready() -> void:
	# Every visible layer uses authored ArrayMesh topology. This keeps the terminal
	# stack free of PrimitiveMesh silhouettes while retaining the original,
	# bounded particle timings and transparent materials.
	flash_core.mesh = _build_flash_mesh(flash_material)
	fire.draw_pass_1 = _build_flame_mesh(fire_material)
	sparks.draw_pass_1 = _build_spark_mesh(spark_material)
	debris.draw_pass_1 = _build_debris_mesh(debris_material)
	pressure_wave.mesh = _build_pressure_ring_mesh(wave_material)
	dust.draw_pass_1 = _build_dust_mesh(dust_material)
	visible = false


func _make_array_mesh(
	vertices: PackedVector3Array,
	indices: PackedInt32Array,
	material: Material,
	colors := PackedColorArray(),
) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	if not colors.is_empty():
		arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


func _build_flash_mesh(material: Material) -> ArrayMesh:
	return _build_irregular_volume(
		material,
		PackedFloat32Array([-0.34, -0.12, 0.13, 0.38]),
		PackedFloat32Array([0.34, 0.62, 0.48, 0.22]),
		10,
		1.73,
		Color(1.0, 0.98, 0.78, 0.72),
		Color(1.0, 0.34, 0.04, 0.08),
	)


func _build_flame_mesh(material: Material) -> ArrayMesh:
	# A closed, faceted flame seed gives every particle a genuine 3D silhouette.
	# The cloud's randomized motion supplies the larger fireball volume without
	# exposing detached opaque cards when a frame lands between particle phases.
	return _build_irregular_volume(
		material,
		PackedFloat32Array([-0.28, -0.10, 0.16, 0.43, 0.72]),
		PackedFloat32Array([0.08, 0.18, 0.125, 0.072, 0.018]),
		7,
		2.31,
		Color(1.0, 0.86, 0.25, 0.86),
		Color(0.9, 0.035, 0.004, 0.05),
	)


func _build_irregular_volume(
	material: Material,
	ring_heights: PackedFloat32Array,
	ring_radii: PackedFloat32Array,
	segments: int,
	noise_seed: float,
	base_color: Color,
	tip_color: Color,
) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var bottom_y := ring_heights[0] - maxf(0.025, ring_radii[0] * 0.35)
	var top_y := ring_heights[ring_heights.size() - 1] + maxf(0.025, ring_radii[ring_radii.size() - 1] * 0.55)
	vertices.append(Vector3(0.0, bottom_y, 0.0))
	colors.append(base_color)
	for ring_index in ring_heights.size():
		var t := float(ring_index) / float(maxi(1, ring_heights.size() - 1))
		for segment_index in segments:
			var angle := TAU * float(segment_index) / float(segments)
			var irregularity := 1.0 + 0.34 * sin(float(segment_index) * noise_seed + float(ring_index) * 1.47)
			var radius := ring_radii[ring_index] * irregularity
			var twist := 0.15 * sin(float(ring_index) * 1.91 + noise_seed)
			var center_offset := Vector2(
				0.045 * sin(float(ring_index) * 1.37 + noise_seed),
				0.04 * cos(float(ring_index) * 1.81 + noise_seed),
			)
			vertices.append(Vector3(center_offset.x + cos(angle + twist) * radius, ring_heights[ring_index], center_offset.y + sin(angle + twist) * radius))
			colors.append(base_color.lerp(tip_color, t))
	var top_index := vertices.size()
	vertices.append(Vector3(0.025 * sin(noise_seed), top_y, 0.025 * cos(noise_seed)))
	colors.append(tip_color)
	for segment_index in segments:
		var next_segment := (segment_index + 1) % segments
		indices.append_array(PackedInt32Array([0, 1 + next_segment, 1 + segment_index]))
	for ring_index in ring_heights.size() - 1:
		var ring_start := 1 + ring_index * segments
		var next_ring_start := ring_start + segments
		for segment_index in segments:
			var next_segment := (segment_index + 1) % segments
			var a := ring_start + segment_index
			var b := ring_start + next_segment
			var c := next_ring_start + segment_index
			var d := next_ring_start + next_segment
			indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
	var final_ring_start := 1 + (ring_heights.size() - 1) * segments
	for segment_index in segments:
		var next_segment := (segment_index + 1) % segments
		indices.append_array(PackedInt32Array([final_ring_start + segment_index, final_ring_start + next_segment, top_index]))
	return _make_array_mesh(vertices, indices, material, colors)


func _build_spark_mesh(material: Material) -> ArrayMesh:
	var vertices := PackedVector3Array([
		Vector3(-0.012, -0.17, 0.0), Vector3(0.014, -0.17, 0.0), Vector3(0.0, 0.2, 0.0),
		Vector3(0.0, -0.15, -0.012), Vector3(0.0, -0.15, 0.014), Vector3(0.0, 0.21, 0.0),
	])
	return _make_array_mesh(vertices, PackedInt32Array([0, 1, 2, 3, 4, 5]), material)


func _build_debris_mesh(material: Material) -> ArrayMesh:
	var vertices := PackedVector3Array([
		Vector3(-0.07, -0.035, -0.045), Vector3(0.065, -0.028, -0.035),
		Vector3(0.018, 0.075, -0.018), Vector3(-0.025, 0.012, 0.085),
	])
	return _make_array_mesh(vertices, PackedInt32Array([0, 1, 2, 0, 3, 1, 0, 2, 3, 1, 3, 2]), material)


func _build_pressure_ring_mesh(material: Material) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	const SEGMENTS := 72
	for segment_index in SEGMENTS:
		var angle := TAU * float(segment_index) / float(SEGMENTS)
		var irregularity := 0.035 * sin(float(segment_index) * 2.43)
		var inner_radius := 0.82 + irregularity
		var outer_radius := 1.0 + irregularity * 0.5
		vertices.append(Vector3(cos(angle) * inner_radius, -0.018, sin(angle) * inner_radius))
		vertices.append(Vector3(cos(angle) * outer_radius, 0.018 + 0.012 * sin(float(segment_index) * 1.31), sin(angle) * outer_radius))
	for segment_index in SEGMENTS:
		var next := (segment_index + 1) % SEGMENTS
		var a := segment_index * 2
		var b := a + 1
		var c := next * 2
		var d := c + 1
		indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
	return _make_array_mesh(vertices, indices, material)


func _build_dust_mesh(material: Material) -> ArrayMesh:
	return _build_irregular_volume(
		material,
		PackedFloat32Array([-0.16, -0.05, 0.08, 0.18]),
		PackedFloat32Array([0.14, 0.22, 0.19, 0.09]),
		8,
		1.39,
		Color(0.32, 0.24, 0.16, 0.58),
		Color(0.12, 0.095, 0.08, 0.06),
	)


func play(event_id: String, authority_origin: Vector3, visible_origin: Vector3, particle_scale: float) -> void:
	terminal_event_id = event_id
	authoritative_world_origin = authority_origin
	presentation_origin = visible_origin
	started_usec = Time.get_ticks_usec()
	started_frame = Engine.get_process_frames()
	global_position = visible_origin
	visible = true
	set_meta(&"terminal_event_id", event_id)
	set_meta(&"spawned_usec", started_usec)
	set_meta(&"spawned_phase", &"flash_impulse")
	set_meta(&"authoritative_world_origin", authority_origin)
	set_meta(&"presentation_origin", visible_origin)

	var density := clampf(particle_scale, 0.5, 1.0)
	for particles: GPUParticles3D in [fire, sparks, debris, dust]:
		particles.amount_ratio = density
		particles.emitting = false
	_start_particle_layer(fire, &"fire_sparks_expansion")
	_start_particle_layer(sparks, &"fire_sparks_expansion")
	var staged_particles := create_tween()
	staged_particles.tween_interval(0.28)
	staged_particles.tween_callback(_start_particle_layer.bind(debris, &"debris_pressure_wave"))
	staged_particles.tween_interval(0.24)
	staged_particles.tween_callback(_start_particle_layer.bind(dust, &"dust_camera_down"))

	flash_core.scale = Vector3.ONE * 0.04
	flash_core.visible = true
	flash_core.transparency = 0.0
	var flash_tween := create_tween().set_parallel(true)
	# The screen-space flash and local light carry the impact. Keep this world-space
	# core small and translucent so a slow render frame can never expose an opaque
	# globe that obscures the authored scene.
	flash_tween.tween_property(flash_core, "scale", Vector3.ONE * 0.72, 0.10).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	flash_tween.tween_property(flash_core, "transparency", 1.0, 0.10)
	flash_tween.chain().tween_callback(flash_core.set_visible.bind(false)).set_delay(0.02)

	pressure_wave.scale = Vector3.ONE * 0.04
	pressure_wave.visible = true
	pressure_wave.transparency = 0.0
	var wave_tween := create_tween().set_parallel(true)
	wave_tween.tween_property(pressure_wave, "scale", Vector3(14.0, 1.0, 14.0), 0.9).set_delay(0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	wave_tween.tween_property(pressure_wave, "transparency", 1.0, 0.86).set_delay(0.28)
	var wave_hide := create_tween()
	wave_hide.tween_interval(1.08)
	wave_hide.tween_callback(pressure_wave.set_visible.bind(false))

	local_light.light_energy = 12.0
	var light_tween := create_tween()
	light_tween.tween_property(local_light, "light_energy", 1.5, 0.20)
	light_tween.tween_property(local_light, "light_energy", 0.0, 1.25)


func _start_particle_layer(particles: GPUParticles3D, layer_phase: StringName) -> void:
	if not is_instance_valid(particles) or not is_inside_tree():
		return
	particles.set_meta(&"spawned_phase", layer_phase)
	particles.set_meta(&"spawned_usec", Time.get_ticks_usec())
	particles.restart()
	particles.emitting = true
	_layer_started[particles.name] = {
		"phase": layer_phase,
		"usec": Time.get_ticks_usec(),
		"frame": Engine.get_process_frames(),
	}


func layer_receipts() -> Array[Dictionary]:
	var nodes: Array[Node3D] = [flash_core, fire, sparks, debris, pressure_wave, dust, local_light]
	var receipts: Array[Dictionary] = []
	for index in nodes.size():
		var node := nodes[index]
		var receipt := {
			"name": LAYER_NAMES[index],
			"path": String(node.get_path()),
			"terminal_event_id": terminal_event_id,
			"authoritative_world_origin": authoritative_world_origin,
			"presentation_origin": presentation_origin,
			"spawned_usec": started_usec,
			"spawned_frame": started_frame,
			"layer_started": _layer_started.get(node.name, {}),
			"visible": node.visible and visible,
			"production_authored_scene": true,
			"cleanup_pending": is_inside_tree(),
		}
		if node is GPUParticles3D:
			receipt["emitting"] = (node as GPUParticles3D).emitting
			receipt["amount_ratio"] = (node as GPUParticles3D).amount_ratio
			var particle_mesh := (node as GPUParticles3D).draw_pass_1
			receipt["final_mesh_type"] = particle_mesh.get_class() if particle_mesh != null else &"missing"
			receipt["primitive_mesh_bound"] = particle_mesh is PrimitiveMesh
		elif node is MeshInstance3D:
			receipt["scale"] = (node as MeshInstance3D).scale
			receipt["transparency"] = (node as MeshInstance3D).transparency
			var final_mesh := (node as MeshInstance3D).mesh
			receipt["final_mesh_type"] = final_mesh.get_class() if final_mesh != null else &"missing"
			receipt["primitive_mesh_bound"] = final_mesh is PrimitiveMesh
		elif node is OmniLight3D:
			receipt["light_energy"] = (node as OmniLight3D).light_energy
			receipt["omni_range"] = (node as OmniLight3D).omni_range
		receipts.append(receipt)
	return receipts


func _mcp_state() -> Dictionary:
	var receipts := layer_receipts()
	var primitive_count := 0
	var array_mesh_count := 0
	for receipt: Dictionary in receipts:
		if receipt.get("primitive_mesh_bound", false) == true:
			primitive_count += 1
		if String(receipt.get("final_mesh_type", "")) == "ArrayMesh":
			array_mesh_count += 1
	return {
		"terminal_event_id": terminal_event_id,
		"authoritative_world_origin": authoritative_world_origin,
		"presentation_origin": presentation_origin,
		"started_usec": started_usec,
		"started_frame": started_frame,
		"layer_count": receipts.size(),
		"array_mesh_layer_count": array_mesh_count,
		"primitive_mesh_layer_count": primitive_count,
		"all_visual_meshes_authored_arrays": array_mesh_count == 6 and primitive_count == 0,
		"layer_receipts": receipts,
	}
