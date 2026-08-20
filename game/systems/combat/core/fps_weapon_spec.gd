class_name FPSWeaponSpec
extends Resource

@export var weapon_id: StringName = &"rifle"
@export var display_name := "RIFLE"
@export_range(1.0, 1000.0, 1.0) var damage := 30.0
@export_range(1.0, 5000.0, 1.0) var range_meters := 160.0
@export_range(30.0, 2000.0, 1.0) var rounds_per_minute := 600.0
@export_range(1, 500, 1) var magazine_size := 30
@export_range(0, 2000, 1) var starting_reserve := 120
@export_range(0.05, 10.0, 0.05) var reload_seconds := 1.8
@export var automatic := true
@export_range(0.0, 15.0, 0.01) var hip_spread_degrees := 0.7
@export_range(0.0, 15.0, 0.01) var aim_spread_degrees := 0.12


func snapshot() -> Dictionary:
	return {
		"weapon_id": String(weapon_id),
		"display_name": display_name,
		"damage": damage,
		"range_meters": range_meters,
		"rounds_per_minute": rounds_per_minute,
		"magazine_size": magazine_size,
		"starting_reserve": starting_reserve,
		"reload_seconds": reload_seconds,
		"automatic": automatic,
		"hip_spread_degrees": hip_spread_degrees,
		"aim_spread_degrees": aim_spread_degrees,
	}
