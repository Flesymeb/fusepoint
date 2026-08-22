extends MainMenu

## Fusepoint's product adapter intentionally inherits Maaack's registered
## MainMenu base. The shell owns scene transitions while the component retains
## its native button, focus, submenu, confirmation, and lifecycle contracts.

signal settings_requested

@export_range(0.0, 24.0, 0.5) var background_parallax_pixels := 10.0
@export_range(1.0, 16.0, 0.5) var background_parallax_response := 5.5
@export_range(0.0, 96.0, 1.0) var background_overscan_pixels := 36.0

@onready var _background: TextureRect = $BackgroundTextureRect

var _background_motion := Vector2.ZERO


func _ready() -> void:
	super._ready()
	# Fusepoint routes these two actions through ProductShell, so both remain
	# available without replacing Maaack's inherited menu implementation.
	new_game_button.show()
	options_button.show()
	new_game_button.grab_focus.call_deferred()
	_resize_background()
	get_viewport().size_changed.connect(_resize_background)


func _process(delta: float) -> void:
	var viewport_size := get_viewport_rect().size
	var target := _parallax_target_for_position(get_viewport().get_mouse_position(), viewport_size)
	var weight := 1.0 - exp(-background_parallax_response * delta)
	_background_motion = _background_motion.lerp(target, weight)
	_apply_background_motion()


func new_game() -> void:
	# ProductShell consumes the original component signal and performs the
	# authoritative title -> loadout transition.
	game_started.emit()


func _on_options_button_pressed() -> void:
	if options_packed_scene == null:
		settings_requested.emit()
		return
	super._on_options_button_pressed()


func _parallax_target_for_position(pointer: Vector2, viewport_size: Vector2) -> Vector2:
	if background_parallax_pixels <= 0.0 or viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return Vector2.ZERO
	var normalized := (pointer / viewport_size - Vector2(0.5, 0.5)).clamp(
		Vector2(-0.5, -0.5), Vector2(0.5, 0.5)
	)
	return -normalized * background_parallax_pixels * 2.0


func _resize_background() -> void:
	_apply_background_motion()


func _apply_background_motion() -> void:
	var overscan := maxf(background_overscan_pixels, background_parallax_pixels + 2.0)
	_background.offset_left = -overscan + _background_motion.x
	_background.offset_top = -overscan + _background_motion.y
	_background.offset_right = overscan + _background_motion.x
	_background.offset_bottom = overscan + _background_motion.y
