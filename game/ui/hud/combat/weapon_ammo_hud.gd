class_name WeaponAmmoHUD
extends Control

## Borderless, signal-friendly FPS weapon and ammunition HUD.

const WEAPON_SILHOUETTES := {
	&"ak74m": preload("res://ui/hud/combat/weapon_silhouettes/ak74m.svg"),
	&"saiga12": preload("res://ui/hud/combat/weapon_silhouettes/saiga12.svg"),
}
const WEAPON_SILHOUETTE_PATHS := {
	&"ak74m": "res://ui/hud/combat/weapon_silhouettes/ak74m.svg",
	&"saiga12": "res://ui/hud/combat/weapon_silhouettes/saiga12.svg",
}

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

var _equipped_id := &"ak74m"
var _bound_silhouette_identity := &""
var _bound_silhouette_path := ""
var _silhouette_update_serial := 0
var _last_authoritative_signature := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_silhouette(_equipped_id)
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


func set_authoritative_weapon_state(
	weapon_id: StringName,
	next_weapon_name: String,
	next_fire_mode: String,
	magazine: int,
	reserve: int,
	capacity: int,
	reload_progress := -1.0,
) -> void:
	if not is_node_ready():
		await ready
	var signature := "%s|%s|%s|%d|%d|%d|%.4f" % [
		String(weapon_id), next_weapon_name, next_fire_mode,
		magazine, reserve, capacity, reload_progress,
	]
	if signature == _last_authoritative_signature:
		return
	_last_authoritative_signature = signature
	_equipped_id = weapon_id if WEAPON_SILHOUETTES.has(weapon_id) else &"ak74m"
	weapon_name = next_weapon_name
	fire_mode = next_fire_mode
	magazine_ammo = magazine
	reserve_ammo = reserve
	magazine_capacity = capacity
	_apply_silhouette(_equipped_id)
	_reload_row.visible = reload_progress >= 0.0
	_reload_progress.value = clampf(reload_progress, 0.0, 1.0) * 100.0
	_refresh()


func _apply_silhouette(weapon_id: StringName) -> void:
	var texture: Texture2D = WEAPON_SILHOUETTES.get(weapon_id) as Texture2D
	var next_path := String(WEAPON_SILHOUETTE_PATHS.get(weapon_id, ""))
	if _bound_silhouette_identity != weapon_id or _bound_silhouette_path != next_path:
		_silhouette_update_serial += 1
	_bound_silhouette_identity = weapon_id
	_bound_silhouette_path = next_path
	_weapon_icon.texture = texture
	_weapon_icon.visible = texture != null


func _mcp_state() -> Dictionary:
	return {
		"equipped_id": String(_equipped_id),
		"weapon_name": weapon_name,
		"fire_mode": fire_mode,
		"magazine": magazine_ammo,
		"reserve": reserve_ammo,
		"capacity": magazine_capacity,
		"silhouette_identity": String(_bound_silhouette_identity),
		"silhouette_path": _bound_silhouette_path,
		"silhouette_visible": _weapon_icon.visible,
		"silhouette_update_serial": _silhouette_update_serial,
		"native_transparent_rgba": true,
		"slot_size": _weapon_icon.size,
		"reload_visible": _reload_row.visible,
		"reload_progress": _reload_progress.value / 100.0,
	}


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
