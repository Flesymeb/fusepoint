class_name FusepointBombTerminalEffect
extends Node3D

## Authored, presentation-only detonation stack. Mission authority and damage
## remain in MissionController; this scene only renders one immutable event.

const LAYER_NAMES: Array[StringName] = [
	&"flash", &"fire", &"sparks", &"debris", &"pressure_wave", &"dust", &"local_light",
]

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
	visible = false


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
	# sphere that obscures the authored scene.
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

	local_light.light_energy = 22.0
	var light_tween := create_tween()
	light_tween.tween_property(local_light, "light_energy", 2.0, 0.22)
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
		elif node is MeshInstance3D:
			receipt["scale"] = (node as MeshInstance3D).scale
			receipt["transparency"] = (node as MeshInstance3D).transparency
		elif node is OmniLight3D:
			receipt["light_energy"] = (node as OmniLight3D).light_energy
			receipt["omni_range"] = (node as OmniLight3D).omni_range
		receipts.append(receipt)
	return receipts
