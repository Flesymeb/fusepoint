class_name FPSShotFeedback3D
extends Node3D

## Lightweight default tracer/impact feedback for hitscan weapons. Products may
## replace its material or bind shot_resolved to authored VFX without changing
## the authoritative ray/damage path.

signal trace_spawned(event: Dictionary, effect: Node3D)
signal impact_spawned(event: Dictionary, effect: Node3D)

@export_node_path("FPSHitscanWeapon") var hitscan_weapon_path: NodePath
@export_range(0.01, 1.0, 0.01) var tracer_seconds := 0.06
@export_range(0.01, 1.0, 0.01) var impact_seconds := 0.16
@export_range(0.001, 0.1, 0.001) var impact_radius := 0.035
# Warm, short-lived streaks read as muzzle/impact energy. The previous cyan
# value was a calibration aid and looked like a debug ray in finished play.
@export var player_tracer_color := Color(1.0, 0.78, 0.38, 0.7)
@export var enemy_tracer_color := Color(1.0, 0.3, 0.1, 0.68)
@export var impact_color := Color(1.0, 0.55, 0.18, 0.92)

var active_effect_count := 0
var _hitscan: FPSHitscanWeapon


func _ready() -> void:
	_hitscan = get_node_or_null(hitscan_weapon_path) as FPSHitscanWeapon if not hitscan_weapon_path.is_empty() else null
	if _hitscan != null:
		_hitscan.shot_resolved.connect(show_shot)


func show_shot(event: Dictionary) -> void:
	if not bool(event.get("accepted", event.get("applied", false))):
		return
	var from: Vector3 = event.get("muzzle_origin", event.get("origin", global_position))
	var direction: Vector3 = event.get("direction", Vector3.FORWARD)
	var to: Vector3 = event.get("hit_position", from + direction * float(event.get("range_meters", 24.0)))
	var source_team := StringName(event.get("source_team", &"player"))
	var color := enemy_tracer_color if source_team == &"enemy" else player_tracer_color
	_spawn_tracer(from, to, color, event)
	if bool(event.get("hit", event.get("applied", false))):
		_spawn_impact(to, event)


func _spawn_tracer(from: Vector3, to: Vector3, color: Color, event: Dictionary) -> void:
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = Color(color.r, color.g, color.b)
	material.emission_energy_multiplier = 3.0
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(from)
	mesh.surface_set_color(Color(color.r, color.g, color.b, color.a * 0.2))
	mesh.surface_add_vertex(to)
	mesh.surface_end()
	var tracer := MeshInstance3D.new()
	tracer.name = "ShotTracer"
	tracer.mesh = mesh
	_add_world_effect(tracer)
	active_effect_count += 1
	trace_spawned.emit(event, tracer)
	var tween := tracer.create_tween()
	tween.tween_property(tracer, "transparency", 1.0, tracer_seconds)
	tween.tween_callback(_retire_effect.bind(tracer))


func _spawn_impact(position: Vector3, event: Dictionary) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = impact_radius
	mesh.height = impact_radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = impact_color
	material.emission_enabled = true
	material.emission = Color(impact_color.r, impact_color.g, impact_color.b)
	material.emission_energy_multiplier = 4.0
	mesh.material = material
	var impact := MeshInstance3D.new()
	impact.name = "ShotImpact"
	impact.mesh = mesh
	_add_world_effect(impact)
	impact.global_position = position
	active_effect_count += 1
	impact_spawned.emit(event, impact)
	var tween := impact.create_tween().set_parallel(true)
	tween.tween_property(impact, "scale", Vector3.ONE * 2.4, impact_seconds)
	tween.tween_property(impact, "transparency", 1.0, impact_seconds)
	tween.chain().tween_callback(_retire_effect.bind(impact))


func _add_world_effect(effect: Node3D) -> void:
	var target := get_tree().current_scene
	if target == null:
		target = get_tree().root
	target.add_child(effect)


func _retire_effect(effect: Node3D) -> void:
	active_effect_count = maxi(0, active_effect_count - 1)
	if is_instance_valid(effect):
		effect.queue_free()
