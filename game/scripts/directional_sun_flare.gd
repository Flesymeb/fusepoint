class_name FusepointDirectionalSunFlare
extends Control

## Presentation-only directional glare. It observes the accepted sun and active
## camera; it never changes environment energy, exposure, lighting, or gameplay.

@export var sun_path: NodePath

var facing_strength := 0.0
var visible_area_ratio := 0.0
var sun_screen_position := Vector2.ZERO
var draw_visible := false

@onready var sun: DirectionalLight3D = get_node(sun_path) as DirectionalLight3D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = additive
	set_process(true)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	draw_visible = false
	facing_strength = 0.0
	visible_area_ratio = 0.0
	var camera := get_viewport().get_camera_3d()
	if not is_instance_valid(sun) or camera == null:
		return
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		return
	var view_direction := -camera.global_transform.basis.z
	var sun_direction := sun.global_transform.basis * Vector3(0.0, 0.0, 1.0)
	var facing := view_direction.dot(sun_direction)
	if facing <= 0.12:
		return
	var sun_world := camera.global_position + sun_direction * 1000.0
	if camera.is_position_behind(sun_world):
		return
	var screen_position := camera.unproject_position(sun_world)
	if screen_position.x < 0.0 or screen_position.x > viewport_size.x or screen_position.y < 0.0 or screen_position.y > viewport_size.y:
		return
	var center := viewport_size * 0.5
	var distance_factor := clampf(1.0 - center.distance_to(screen_position) / maxf(viewport_size.length() * 0.72, 1.0), 0.0, 1.0)
	var strength := pow(clampf(facing, 0.0, 1.0), 1.7) * (0.28 + distance_factor * 0.72)
	var core_radius := 4.0 + 7.0 * facing
	var halo_radius := 32.0 + 15.0 * facing
	for layer_index in 10:
		var layer_t := float(layer_index) / 9.0
		var radius := core_radius + layer_t * (halo_radius - core_radius)
		var alpha := (1.0 - layer_t) * (1.0 - layer_t) * 0.036 * strength
		draw_circle(screen_position, radius, Color(1.0, 0.84 + layer_t * 0.16, 0.54, alpha))
	draw_circle(screen_position, core_radius, Color(1.0, 0.98, 0.88, 0.34 * strength))
	var axis := screen_position - center
	for spec in [[0.30, 13.0, Color(1.0, 0.54, 0.22, 0.042)], [0.58, 8.0, Color(0.42, 0.72, 1.0, 0.034)], [0.86, 17.0, Color(1.0, 0.66, 0.30, 0.030)]]:
		var ghost_color: Color = spec[2]
		ghost_color.a *= strength
		draw_circle(center + axis * float(spec[0]), float(spec[1]), ghost_color)
	draw_visible = true
	facing_strength = strength
	sun_screen_position = screen_position
	var estimated_pixels := PI * halo_radius * halo_radius + PI * (13.0 * 13.0 + 8.0 * 8.0 + 17.0 * 17.0)
	visible_area_ratio = estimated_pixels / maxf(viewport_size.x * viewport_size.y, 1.0)


func _mcp_state() -> Dictionary:
	return {
		"family_id": &"directional_sun_flare",
		"enabled": visible,
		"draw_visible": draw_visible,
		"singleton_count": 1,
		"direction_bound": sun != null,
		"sun_path": String(sun.get_path()) if sun != null else "",
		"facing_strength": facing_strength,
		"screen_position": sun_screen_position,
		"visible_area_ratio": visible_area_ratio,
		"maximum_visible_area_ratio": 0.02,
		"blend_mode": &"additive",
		"changes_exposure": false,
		"presentation_only": true,
	}
