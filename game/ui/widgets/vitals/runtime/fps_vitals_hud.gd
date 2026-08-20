class_name FPSVitalsHUD
extends Control

## Compact, borderless FPS health/armor composition.

const HEALTH_STYLE := preload("res://ui/widgets/vitals/runtime/godotx_health_bar_style.gd")

@export var health_color := Color(0.18, 0.87, 0.66, 1.0)
@export var armor_color := Color(0.35, 0.68, 0.92, 0.95)
@export var track_color := Color(0.01, 0.025, 0.03, 0.35)
@export_range(1, 12, 1) var health_bar_thickness := 6
@export_range(1, 12, 1) var armor_bar_thickness := 3

@onready var _health_label: Label = %HealthValue
@onready var _armor_label: Label = %ArmorValue
@onready var _health_bar: GodotxHealthBarControl = %HealthBar
@onready var _armor_bar: GodotxHealthBarControl = %ArmorBar
@onready var _armor_row: HBoxContainer = %ArmorRow


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_health_bar.custom_minimum_size.y = health_bar_thickness
	_armor_bar.custom_minimum_size.y = armor_bar_thickness
	_health_bar.style = _make_style(health_color, 0.22)
	_armor_bar.style = _make_style(armor_color, 0.18)
	set_health(100.0, 100.0, false)
	set_armor(100.0, 100.0, false)


func set_health(current: float, maximum: float = 100.0, animate: bool = true) -> void:
	if not is_node_ready():
		await ready
	var safe_max := maxf(maximum, 1.0)
	var safe_value := clampf(current, 0.0, safe_max)
	_health_label.text = str(int(roundf(safe_value)))
	_health_bar.min_value = 0.0
	_health_bar.max_value = safe_max
	_health_bar.set_value(safe_value, animate)


func set_armor(current: float, maximum: float = 100.0, animate: bool = true) -> void:
	if not is_node_ready():
		await ready
	var safe_max := maxf(maximum, 1.0)
	var safe_value := clampf(current, 0.0, safe_max)
	_armor_label.text = str(int(roundf(safe_value)))
	_armor_bar.min_value = 0.0
	_armor_bar.max_value = safe_max
	_armor_bar.set_value(safe_value, animate)


func set_armor_visible(show_armor: bool) -> void:
	if not is_node_ready():
		await ready
	_armor_row.visible = show_armor


func _make_style(fill: Color, track_alpha: float) -> GodotxHealthBarStyle:
	var style := HEALTH_STYLE.new()
	style.roundness = 100.0
	style.fill_inset = Vector2.ZERO
	style.background_color = Color(track_color.r, track_color.g, track_color.b, track_alpha)
	style.fill_color = fill
	style.border_enabled = false
	style.border_thickness = 0
	style.shadow_enabled = false
	style.gradient_enabled = false
	style.label_enabled = false
	style.animation_duration = 0.2
	return style
