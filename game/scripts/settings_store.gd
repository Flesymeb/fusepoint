class_name FusepointSettingsStore
extends Node

signal settings_applied(values: Dictionary)

const CONFIG_PATH := "user://fusepoint_settings.cfg"
const SECTION := "accessibility"
const WINDOWED_SIZE := Vector2i(1280, 720)
const FULLSCREEN_SIZE := Vector2i(1920, 1080)

var values := {
	"master_volume": 0.85,
	"subtitle_size": 18.0,
	"ui_scale": 1.0,
	"fov": 76.0,
	"reduced_camera_motion": false,
	"screen_shake": true,
	"hold_ads": true,
	"hold_sprint": true,
	"fullscreen_enabled": false,
}


func _ready() -> void:
	load_settings()
	apply_runtime.call_deferred()


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	for key in values:
		values[key] = config.get_value(SECTION, key, values[key])
	values["ui_scale"] = clampf(float(values["ui_scale"]), 1.0, 2.0)


func save_settings(next_values: Dictionary) -> void:
	for key in values:
		if next_values.has(key):
			values[key] = next_values[key]
	values["ui_scale"] = clampf(float(values["ui_scale"]), 1.0, 2.0)
	var config := ConfigFile.new()
	for key in values:
		config.set_value(SECTION, key, values[key])
	config.save(CONFIG_PATH)
	apply_runtime()
	settings_applied.emit(values.duplicate(true))


func apply_runtime() -> void:
	var window := get_window()
	var fullscreen_enabled := bool(values.get("fullscreen_enabled", false))
	# Retain the registered Maaack menu helper as the single window-mode
	# mechanism while FusepointSettingsStore remains the product-owned value.
	if fullscreen_enabled:
		# A window launched with the 1280x720 debug override otherwise carries
		# that backing size into fullscreen on some display servers.
		AppSettings.set_fullscreen_enabled(false, window)
		AppSettings.set_resolution(FULLSCREEN_SIZE, window, false)
		AppSettings.set_fullscreen_enabled(true, window)
	else:
		AppSettings.set_fullscreen_enabled(false, window)
		AppSettings.set_resolution(WINDOWED_SIZE, window, false)
	window.content_scale_factor = 1.0
	window.scaling_3d_scale = 1.0
	AudioServer.set_bus_volume_db(0, linear_to_db(clampf(float(values["master_volume"]), 0.001, 1.0)))
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null:
		var camera := player.get_node_or_null("Head/Camera3D") as Camera3D
		if camera != null:
			camera.fov = clampf(float(values["fov"]), 65.0, 95.0)
		if player.has_method(&"apply_accessibility_settings"):
			player.call(&"apply_accessibility_settings", values)
	for group_name: StringName in [&"product_shell", &"tactical_hud", &"terminal_presenter"]:
		var owner := get_tree().get_first_node_in_group(group_name)
		if owner != null and owner.has_method(&"apply_accessibility_settings"):
			owner.call(&"apply_accessibility_settings", values)
	var damage_feedback := get_node_or_null("../../PlayerDamageFeedback")
	if damage_feedback != null and damage_feedback.has_method(&"apply_accessibility_settings"):
		damage_feedback.call(&"apply_accessibility_settings", values)


func snapshot() -> Dictionary:
	return values.duplicate(true)


func _mcp_state() -> Dictionary:
	var window := get_window()
	return {
		"config_path": CONFIG_PATH,
		"values": values,
		"persisted": FileAccess.file_exists(CONFIG_PATH),
		"display": {
			"fullscreen_enabled": bool(values.get("fullscreen_enabled", false)),
			"requested_size": FULLSCREEN_SIZE if bool(values.get("fullscreen_enabled", false)) else WINDOWED_SIZE,
			"window_mode": window.mode,
			"window_size": window.size,
			"viewport_size": window.get_visible_rect().size,
			"content_scale_size": window.content_scale_size,
			"content_scale_factor": window.content_scale_factor,
			"render_scale_3d": window.scaling_3d_scale,
		},
	}
