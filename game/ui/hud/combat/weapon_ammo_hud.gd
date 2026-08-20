class_name WeaponAmmoHUD
extends Control

## Borderless, signal-friendly FPS weapon and ammunition HUD.

@export_group("State")
@export var weapon_name := "AK-74M":
	set(value):
		weapon_name = value
		_refresh_if_ready()
@export var fire_mode := "AUTO":
	set(value):
		fire_mode = value
		_refresh_if_ready()
@export_range(0, 999, 1) var magazine_ammo := 30:
	set(value):
		magazine_ammo = maxi(value, 0)
		_refresh_if_ready()
@export_range(0, 9999, 1) var reserve_ammo := 120:
	set(value):
		reserve_ammo = maxi(value, 0)
		_refresh_if_ready()
@export_range(0, 999, 1) var magazine_capacity := 30:
	set(value):
		magazine_capacity = maxi(value, 0)
		_refresh_if_ready()

@export_group("Presentation")
@export_range(0, 100, 1) var low_ammo_threshold := 5:
	set(value):
		low_ammo_threshold = maxi(value, 0)
		_refresh_if_ready()
@export var normal_color := Color(0.96, 0.98, 0.98, 0.96):
	set(value):
		normal_color = value
		_refresh_if_ready()
@export var accent_color := Color(0.94, 0.76, 0.28, 1.0):
	set(value):
		accent_color = value
		_refresh_if_ready()
@export var warning_color := Color(1.0, 0.35, 0.2, 1.0):
	set(value):
		warning_color = value
		_refresh_if_ready()

@onready var _weapon_icon: TextureRect = %WeaponIcon
@onready var _weapon_name_label: Label = %WeaponName
@onready var _fire_mode_label: Label = %FireMode
@onready var _magazine_label: Label = %Magazine
@onready var _reserve_label: Label = %Reserve
@onready var _reload_row: HBoxContainer = %ReloadRow
@onready var _reload_progress: ProgressBar = %ReloadProgress


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_refresh()


func set_weapon(next_weapon_name: String, next_fire_mode: String = "") -> void:
	weapon_name = next_weapon_name
	if not next_fire_mode.is_empty():
		fire_mode = next_fire_mode


func set_ammo(magazine: int, reserve: int, capacity: int = -1) -> void:
	magazine_ammo = magazine
	reserve_ammo = reserve
	if capacity >= 0:
		magazine_capacity = capacity


func set_weapon_icon(texture: Texture2D) -> void:
	if not is_node_ready():
		await ready
	_weapon_icon.texture = texture
	_weapon_icon.visible = texture != null


func set_reload_progress(progress: float) -> void:
	if not is_node_ready():
		await ready
	_reload_row.visible = progress >= 0.0
	_reload_progress.value = clampf(progress, 0.0, 1.0) * 100.0


func _refresh_if_ready() -> void:
	if is_node_ready():
		_refresh()


func _refresh() -> void:
	_weapon_name_label.text = weapon_name
	_fire_mode_label.text = fire_mode
	_magazine_label.text = str(magazine_ammo).pad_zeros(2)
	_reserve_label.text = "/ %d" % reserve_ammo
	_magazine_label.add_theme_color_override(
		"font_color",
		warning_color if magazine_ammo <= low_ammo_threshold else accent_color
	)
	_reserve_label.add_theme_color_override("font_color", normal_color)
	_weapon_name_label.add_theme_color_override("font_color", normal_color)
	_fire_mode_label.add_theme_color_override("font_color", accent_color)
