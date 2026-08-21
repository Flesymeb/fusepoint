extends Control

## Directional, screen-space sun lens flare.
## Unlike Environment Glow, this overlay is only visible when the camera faces
## the configured DirectionalLight3D and therefore does not brighten the map.

var sun: DirectionalLight3D
var camera: Camera3D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var canvas_material := CanvasItemMaterial.new()
	canvas_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = canvas_material
	set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if not is_instance_valid(sun) or not is_instance_valid(camera):
		return

	var viewport_size: Vector2 = get_viewport_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		return

	# DirectionalLight3D rays travel along local -Z. The visible sun is in the
	# opposite direction from the light's origin, i.e. local +Z.
	var view_direction := -camera.global_transform.basis.z
	var sun_direction := sun.global_transform.basis * Vector3(0.0, 0.0, 1.0)
	var facing := view_direction.dot(sun_direction)
	if facing <= 0.08:
		return

	var sun_world := camera.global_position + sun_direction * 1000.0
	var sun_screen := camera.unproject_position(sun_world)
	if sun_screen.x < -viewport_size.x or sun_screen.x > viewport_size.x * 2.0 \
		or sun_screen.y < -viewport_size.y or sun_screen.y > viewport_size.y * 2.0:
		return

	var center := viewport_size * 0.5
	var screen_distance := center.distance_to(sun_screen)
	var distance_factor := clampf(
		1.0 - screen_distance / maxf(viewport_size.length() * 0.75, 1.0),
		0.0,
		1.0
	)
	var strength := pow(clampf(facing, 0.0, 1.0), 1.5) * (0.25 + distance_factor * 0.75)

	# Warm solar core and several very soft layers. There is deliberately no
	# draw_arc here: a hard outline reads as an artificial ring around the sun.
	for layer in range(12):
		var layer_t := float(layer) / 11.0
		var layer_radius := 5.0 + layer_t * (42.0 + 16.0 * facing)
		var layer_alpha := (1.0 - layer_t) * (1.0 - layer_t) * 0.042 * strength
		draw_circle(sun_screen, layer_radius, Color(1.0, 0.84 + layer_t * 0.16, 0.48, layer_alpha))
	draw_circle(sun_screen, 4.0 + 7.0 * facing, Color(1.0, 0.98, 0.86, 0.38 * strength))

	# More lens ghosts distributed on the axis through the screen centre. The
	# low alpha keeps them visible as light spots without lifting scene exposure.
	var axis := sun_screen - center
	var ghost_specs := [
		[0.18, 13.0, Color(1.0, 0.58, 0.24, 0.075)],
		[0.34, 25.0, Color(1.0, 0.42, 0.16, 0.105)],
		[0.50, 10.0, Color(0.35, 0.70, 1.0, 0.080)],
		[0.66, 18.0, Color(0.60, 0.86, 1.0, 0.065)],
		[0.82, 32.0, Color(1.0, 0.68, 0.30, 0.075)],
		[0.98, 12.0, Color(0.45, 0.78, 1.0, 0.060)],
		[1.16, 22.0, Color(1.0, 0.52, 0.20, 0.050)],
		[1.34, 8.0, Color(0.70, 0.92, 1.0, 0.045)],
	]
	for spec in ghost_specs:
		var ghost_position: Vector2 = center + axis * float(spec[0])
		var ghost_radius: float = float(spec[1])
		var ghost_color: Color = spec[2]
		ghost_color.a *= strength
		draw_circle(ghost_position, ghost_radius, ghost_color)
