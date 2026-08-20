class_name FusepointSettingsStore
extends Node

signal settings_applied(values: Dictionary)

const CONFIG_PATH := "user://fusepoint_settings.cfg"
const SECTION := "accessibility"

var values := {
	"master_volume": 0.85,
	"subtitle_size": 18.0,
	"ui_scale": 1.0,
	"fov": 76.0,
	"reduced_camera_motion": false,
	"screen_shake": true,
	"hold_ads": true,
	"hold_sprint": true,
}


func _ready() -> void:
	load_settings()
	apply_runtime()


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	for key in values:
		values[key] = config.get_value(SECTION, key, values[key])


func save_settings(next_values: Dictionary) -> void:
	for key in values:
		if next_values.has(key):
			values[key] = next_values[key]
	var config := ConfigFile.new()
	for key in values:
		config.set_value(SECTION, key, values[key])
	config.save(CONFIG_PATH)
	apply_runtime()
	settings_applied.emit(values.duplicate(true))


func apply_runtime() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(clampf(float(values["master_volume"]), 0.001, 1.0)))
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null:
		var camera := player.get_node_or_null("Head/Camera3D") as Camera3D
		if camera != null:
			camera.fov = clampf(float(values["fov"]), 65.0, 95.0)


func snapshot() -> Dictionary:
	return values.duplicate(true)


func _mcp_state() -> Dictionary:
	return {"config_path": CONFIG_PATH, "values": values, "persisted": FileAccess.file_exists(CONFIG_PATH)}
