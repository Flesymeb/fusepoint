@tool
class_name GodotxHealthBarStyle
extends Resource

@export_group("Bar Geometry")
@export_range(0.0, 100.0, 0.5) var roundness: float = 20.0
@export var fill_inset: Vector2 = Vector2(2, 2)

@export_group("Colors")
@export var background_color: Color = Color(0.01, 0.025, 0.03, 0.35)
@export var fill_color: Color = Color(0.18, 0.87, 0.66, 1.0)
@export var use_threshold_colors: bool = false
@export var threshold_red_max: float = 10.0
@export var threshold_orange_max: float = 70.0
@export var color_red: Color = Color(0.9, 0.25, 0.2, 1.0)
@export var color_orange: Color = Color(0.95, 0.6, 0.15, 1.0)
@export var color_green: Color = Color(0.25, 0.75, 0.35, 1.0)

@export_group("Border")
@export var border_enabled: bool = false
@export var border_thickness: int = 0
@export var border_color: Color = Color(0, 0, 0, 0)
@export var border_join_round: bool = true

@export_group("Shadow")
@export var shadow_enabled: bool = false
@export var shadow_color: Color = Color(0, 0, 0, 0.35)
@export var shadow_offset: Vector2 = Vector2(2, 3)
@export var shadow_blur_passes: int = 3
@export var shadow_apply_to: int = 2

@export_group("Gradient")
@export var gradient_enabled: bool = false
@export var gradient_direction: GodotxHealthBarEnums.GradientDirection = GodotxHealthBarEnums.GradientDirection.HORIZONTAL
@export var gradient_start_color: Color = Color(1, 1, 1, 0.25)
@export var gradient_end_color: Color = Color(0, 0, 0, 0.2)
@export_range(0.0, 1.0, 0.05) var gradient_intensity: float = 1.0
@export var gradient_apply_to: int = 1

@export_group("Label")
@export var label_enabled: bool = false
@export var label_position: GodotxHealthBarEnums.LabelPosition = GodotxHealthBarEnums.LabelPosition.CENTER_INSIDE
@export var label_offset: Vector2 = Vector2.ZERO
@export var label_format: String = "{value}%"
@export var label_custom_max: float = 100.0
@export var font: Font = preload("res://ui/widgets/vitals/fonts/BarlowCondensed-Medium.ttf")
@export var font_size: int = 14
@export var font_color: Color = Color(1, 1, 1, 1.0)
@export var outline_size: int = 0
@export var outline_color: Color = Color(0, 0, 0, 1.0)
@export var label_shadow_enabled: bool = false
@export var label_shadow_offset: Vector2 = Vector2(1, 1)
@export var label_shadow_color: Color = Color(0, 0, 0, 0.5)

@export_group("Icon")
@export var icon_enabled: bool = false
@export var icon_texture: Texture2D
@export var icon_scene: PackedScene
@export var icon_position: GodotxHealthBarEnums.IconPosition = GodotxHealthBarEnums.IconPosition.BEFORE
@export var icon_offset: Vector2 = Vector2.ZERO
@export var icon_forced_size: Vector2 = Vector2(24, 24)
@export var icon_fit_mode: GodotxHealthBarEnums.IconFitMode = GodotxHealthBarEnums.IconFitMode.FIT
@export var icon_tint: Color = Color.WHITE

@export_group("Animation")
@export var animation_enabled: bool = true
@export var animation_mode: GodotxHealthBarEnums.AnimationMode = GodotxHealthBarEnums.AnimationMode.TWEEN
@export var animation_duration: float = 0.25
@export var animation_easing: Tween.EaseType = Tween.EASE_OUT
@export var animation_transition: Tween.TransitionType = Tween.TRANS_QUAD
@export var animation_duration_decrease: float = -1.0
@export var animation_easing_decrease: Tween.EaseType = Tween.EASE_OUT
@export var animation_transition_decrease: Tween.TransitionType = Tween.TRANS_QUAD
@export var animation_snap_threshold: float = 0.0

const SHADOW_APPLY_BACKGROUND := 1
const SHADOW_APPLY_FILL := 2
const SHADOW_APPLY_BOTH := 3
const GRADIENT_APPLY_BACKGROUND := 1
const GRADIENT_APPLY_FILL := 2
const GRADIENT_APPLY_BOTH := 3

func _validate_property(property: Dictionary) -> void:
	if property.name == "animation_duration_decrease":
		property.usage = PROPERTY_USAGE_NO_EDITOR if not animation_enabled else PROPERTY_USAGE_DEFAULT
	if property.name == "gradient_apply_to":
		property.hint_string = "1=Background, 2=Fill, 3=Both"
	if property.name == "shadow_apply_to":
		property.hint_string = "1=Background, 2=Fill, 3=Both"

func get_fill_color_for_value(value_0_100: float) -> Color:
	if not use_threshold_colors:
		return fill_color
	if value_0_100 <= threshold_red_max:
		return color_red
	if value_0_100 <= threshold_orange_max:
		return color_orange
	return color_green

func get_effective_round_radius(bar_height: float) -> float:
	var r = (roundness / 100.0) * bar_height
	var max_r = bar_height * 0.5
	return minf(r, max_r)

func validate_thresholds() -> bool:
	if threshold_red_max < 0 or threshold_red_max > 100:
		push_error("GodotX Health Bar: threshold_red_max must be 0..100")
		threshold_red_max = clampf(threshold_red_max, 0, 100)
	if threshold_orange_max < 0 or threshold_orange_max > 100:
		push_error("GodotX Health Bar: threshold_orange_max must be 0..100")
		threshold_orange_max = clampf(threshold_orange_max, 0, 100)
	if threshold_red_max >= threshold_orange_max:
		push_error("GodotX Health Bar: threshold_red_max must be < threshold_orange_max; correcting.")
		threshold_orange_max = maxf(threshold_red_max + 1.0, threshold_orange_max)
	return true
