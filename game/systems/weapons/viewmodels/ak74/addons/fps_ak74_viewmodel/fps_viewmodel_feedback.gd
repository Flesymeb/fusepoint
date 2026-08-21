class_name FPSViewmodelFeedback
extends Node3D

enum FireMode { SEMI, AUTO }

@export_node_path("Node3D") var viewmodel_path: NodePath
@export var fire_mode := FireMode.AUTO
@export_range(0.03, 0.5, 0.01) var auto_fire_interval := 0.09
@export_range(0.03, 0.5, 0.01) var semi_fire_interval := 0.12
@export_range(0.01, 0.2, 0.01) var muzzle_flash_seconds := 0.04
@export_range(0.03, 0.5, 0.01) var semi_fire_audio_seconds := 0.12
@export_range(0.02, 0.2, 0.01) var fire_recoil_out_seconds := 0.05
@export_range(0.02, 0.2, 0.01) var fire_recoil_return_seconds := 0.09
@export_range(0.0, 0.15, 0.005) var fire_recoil_hold_seconds := 0.02
@export_range(0.0, 0.08, 0.001) var fire_recoil_back_distance := 0.015
@export_range(0.0, 8.0, 0.1) var fire_recoil_pitch_degrees := 2.1
@export_range(0.0, 4.0, 0.1) var fire_recoil_yaw_degrees := 0.5
@export_range(0.0, 4.0, 0.1) var fire_recoil_roll_degrees := 0.35

@onready var muzzle_flash: Sprite3D = $MuzzleFlash
@onready var fire_audio: AudioStreamPlayer = $FireAudio
@onready var auto_fire_audio: AudioStreamPlayer = $AutoFireAudio
@onready var reload_audio: AudioStreamPlayer = $ReloadAudio
@onready var switch_audio: AudioStreamPlayer = $SwitchAudio
@onready var aim_audio: AudioStreamPlayer = $AimAudio
@onready var inspect_audio: AudioStreamPlayer = $InspectAudio
@onready var walk_audio: AudioStreamPlayer = $WalkAudio
@onready var run_audio: AudioStreamPlayer = $RunAudio

var viewmodel: FPSViewmodelSwitcher
var fire_button_down := false
var fire_cooldown := 0.0
var movement_state := &"idle"
var _clip_signal_connected := false
var _muzzle_flash_tween: Tween
var _fire_audio_tween: Tween
var _fire_recoil_tween: Tween
var _reload_mount_tween: Tween
var _fire_visual_until := 0.0


func _ready() -> void:
	viewmodel = get_node_or_null(viewmodel_path) as FPSViewmodelSwitcher if not viewmodel_path.is_empty() else null
	muzzle_flash.visible = false
	if viewmodel != null:
		call_deferred(&"_bind_viewmodel_signals")


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if fire_button_down and fire_mode == FireMode.AUTO:
		_play_loop_if_needed(auto_fire_audio)
		fire_cooldown -= delta
		while fire_cooldown <= 0.0:
			trigger_fire(true)
			fire_cooldown += fire_interval()
	if _fire_visual_until > 0.0 and now >= _fire_visual_until:
		_fire_visual_until = 0.0
	_sync_movement_state()


func begin_fire() -> void:
	if fire_mode == FireMode.AUTO:
		fire_button_down = true
		trigger_fire(true)
		fire_cooldown = fire_interval()
	else:
		fire_button_down = false
		trigger_fire(false)


func end_fire() -> void:
	fire_button_down = false
	if fire_mode == FireMode.AUTO:
		_stop_audio(auto_fire_audio)


func stop_feedback() -> void:
	fire_button_down = false
	fire_cooldown = 0.0
	_fire_visual_until = 0.0
	_stop_reload_mount()
	muzzle_flash.visible = false
	if _muzzle_flash_tween != null and _muzzle_flash_tween.is_valid():
		_muzzle_flash_tween.kill()
	if _fire_audio_tween != null and _fire_audio_tween.is_valid():
		_fire_audio_tween.kill()
	if _fire_recoil_tween != null and _fire_recoil_tween.is_valid():
		_fire_recoil_tween.kill()
	movement_state = &"idle"
	for player in [fire_audio, auto_fire_audio, reload_audio, switch_audio, aim_audio, inspect_audio, walk_audio, run_audio]:
		_stop_audio(player)
	_sync_movement_state()


func toggle_fire_mode() -> int:
	fire_mode = FireMode.SEMI if fire_mode == FireMode.AUTO else FireMode.AUTO
	fire_button_down = false
	fire_cooldown = 0.0
	_stop_fire_audio()
	_stop_fire_recoil()
	return fire_mode


func trigger_fire(auto_fire := false) -> void:
	_fire_visual_until = maxf(_fire_visual_until, Time.get_ticks_msec() / 1000.0 + _fire_visual_seconds())
	_play_viewmodel_clip(&"fire")
	_play_fire_recoil(auto_fire)
	show_muzzle_flash()
	if auto_fire:
		_play_loop_if_needed(auto_fire_audio)
	_play_audio_with_timeout(fire_audio, 0.98, 0.04, _fire_audio_seconds())


func trigger_reload() -> void:
	_play_viewmodel_clip(&"reload")
	_play_reload_mount_offset()
	if not _clip_signal_connected:
		_play_audio(reload_audio, 0.94, 0.02)


func trigger_inspect() -> void:
	_play_viewmodel_clip(&"inspect")
	if not _clip_signal_connected:
		_play_audio(inspect_audio, 1.0, 0.0)


func set_aiming(enabled: bool) -> void:
	if viewmodel != null and viewmodel.has_method(&"set_aiming"):
		viewmodel.call(&"set_aiming", enabled)
	else:
		trigger_aim(enabled)


func trigger_weapon_switch() -> void:
	_stop_reload_mount()
	_play_audio(switch_audio, 0.94, 0.03)


func trigger_aim(_enabled: bool) -> void:
	_play_audio(aim_audio, 1.0, 0.02)


func start_walk() -> void:
	movement_state = &"walk"
	_sync_movement_state()


func start_run() -> void:
	movement_state = &"run"
	_sync_movement_state()


func stop_movement() -> void:
	movement_state = &"idle"
	_sync_movement_state()


func show_muzzle_flash() -> void:
	muzzle_flash.visible = true
	muzzle_flash.scale = Vector3.ONE * (0.75 + randf() * 0.2)
	if _muzzle_flash_tween != null and _muzzle_flash_tween.is_valid():
		_muzzle_flash_tween.kill()
	_muzzle_flash_tween = create_tween()
	_muzzle_flash_tween.tween_interval(muzzle_flash_seconds)
	_muzzle_flash_tween.tween_callback(func() -> void:
		muzzle_flash.visible = false
	)


func fire_interval() -> float:
	return auto_fire_interval if fire_mode == FireMode.AUTO else semi_fire_interval


func fire_mode_label() -> String:
	return "AUTO" if fire_mode == FireMode.AUTO else "SEMI"


func is_auto_fire() -> bool:
	return fire_mode == FireMode.AUTO


func movement_label() -> String:
	return String(movement_state).to_upper()


func _bind_viewmodel_signals() -> void:
	if viewmodel == null:
		return
	if viewmodel.has_signal(&"clip_changed"):
		viewmodel.clip_changed.connect(_on_viewmodel_clip_changed)
		_clip_signal_connected = true
	if viewmodel.has_signal(&"weapon_switch_started"):
		viewmodel.weapon_switch_started.connect(_on_viewmodel_switch_started)
	if viewmodel.has_signal(&"aiming_changed"):
		viewmodel.aiming_changed.connect(_on_viewmodel_aiming_changed)


func _on_viewmodel_clip_changed(alias: StringName) -> void:
	match alias:
		&"reload":
			_play_audio(reload_audio, 0.94, 0.02)
		&"inspect":
			_play_audio(inspect_audio, 1.0, 0.0)


func _on_viewmodel_switch_started(_from_id: StringName, _to_id: StringName) -> void:
	trigger_weapon_switch()


func _on_viewmodel_aiming_changed(enabled: bool) -> void:
	trigger_aim(enabled)


func _play_viewmodel_clip(alias: StringName) -> bool:
	if viewmodel == null or not viewmodel.has_method(&"play_clip"):
		return false
	return bool(viewmodel.call(&"play_clip", alias))


func _sync_movement_state() -> void:
	if viewmodel != null:
		var current_clip := _current_viewmodel_clip()
		if current_clip == &"fire":
			if _fire_visual_until <= 0.0:
				_play_viewmodel_clip(movement_state)
			return
		if current_clip.is_empty() or current_clip == &"idle" or current_clip == &"walk" or current_clip == &"run":
			if current_clip != movement_state:
				_play_viewmodel_clip(movement_state)
	match movement_state:
		&"walk":
			_stop_audio(run_audio)
			_play_loop_if_needed(walk_audio)
		&"run":
			_stop_audio(walk_audio)
			_play_loop_if_needed(run_audio)
		_:
			_stop_audio(walk_audio)
			_stop_audio(run_audio)


func _play_loop_if_needed(player: AudioStreamPlayer) -> void:
	if player == null or player.stream == null or player.playing:
		return
	player.play()


func _stop_audio(player: AudioStreamPlayer) -> void:
	if player != null and player.playing:
		player.stop()


func _stop_fire_audio() -> void:
	if _fire_audio_tween != null and _fire_audio_tween.is_valid():
		_fire_audio_tween.kill()
	_stop_audio(fire_audio)
	_stop_audio(auto_fire_audio)


func _stop_fire_recoil() -> void:
	if _fire_recoil_tween != null and _fire_recoil_tween.is_valid():
		_fire_recoil_tween.kill()


func _play_reload_mount_offset() -> void:
	if viewmodel == null:
		return
	var profile := viewmodel.current_profile()
	if profile == null or profile.reload_mount_offset.is_zero_approx():
		return
	var mount := _viewmodel_mount()
	if mount == null:
		return
	_stop_reload_mount()
	mount.position = Vector3.ZERO
	_reload_mount_tween = create_tween()
	_reload_mount_tween.tween_property(mount, "position", profile.reload_mount_offset, 0.05)
	var reload_clip_duration := _clip_duration(&"reload")
	if reload_clip_duration > 0.12:
		_reload_mount_tween.tween_interval(reload_clip_duration - 0.12)
	_reload_mount_tween.tween_property(mount, "position", Vector3.ZERO, 0.07)


func _stop_reload_mount() -> void:
	if _reload_mount_tween != null and _reload_mount_tween.is_valid():
		_reload_mount_tween.kill()
	var mount := _viewmodel_mount()
	if mount != null:
		mount.position = Vector3.ZERO


func _play_fire_recoil(auto_fire: bool) -> void:
	var mount := _viewmodel_mount()
	if mount == null:
		return
	_stop_fire_recoil()
	var kick_scale := 0.65 if auto_fire else 1.0
	var start_position := mount.position
	var start_rotation := mount.rotation_degrees
	var kick_position := start_position + Vector3(0.0, 0.0, -fire_recoil_back_distance * kick_scale)
	var kick_rotation := start_rotation + Vector3(
		-fire_recoil_pitch_degrees * kick_scale,
		(randf() * 2.0 - 1.0) * fire_recoil_yaw_degrees * kick_scale,
		(randf() * 2.0 - 1.0) * fire_recoil_roll_degrees * kick_scale,
	)
	_fire_recoil_tween = create_tween().set_parallel(true)
	_fire_recoil_tween.set_trans(Tween.TRANS_QUAD)
	_fire_recoil_tween.set_ease(Tween.EASE_OUT)
	_fire_recoil_tween.tween_property(mount, "position", kick_position, fire_recoil_out_seconds)
	_fire_recoil_tween.tween_property(mount, "rotation_degrees", kick_rotation, fire_recoil_out_seconds)
	_fire_recoil_tween.chain().tween_interval(fire_recoil_hold_seconds)
	_fire_recoil_tween.tween_callback(func() -> void:
		var recoil_reset := create_tween().set_parallel(true)
		recoil_reset.set_trans(Tween.TRANS_SINE)
		recoil_reset.set_ease(Tween.EASE_IN)
		recoil_reset.tween_property(mount, "position", start_position, fire_recoil_return_seconds)
		recoil_reset.tween_property(mount, "rotation_degrees", start_rotation, fire_recoil_return_seconds)
	)


func _play_audio_with_timeout(player: AudioStreamPlayer, pitch_base: float, pitch_spread: float, timeout_seconds: float) -> void:
	if player == null or player.stream == null:
		return
	player.pitch_scale = pitch_base + randf() * pitch_spread
	player.play()
	if timeout_seconds <= 0.0:
		return
	if _fire_audio_tween != null and _fire_audio_tween.is_valid():
		_fire_audio_tween.kill()
	_fire_audio_tween = create_tween()
	_fire_audio_tween.tween_interval(timeout_seconds)
	_fire_audio_tween.tween_callback(func() -> void:
		_stop_audio(player)
	)


func _fire_audio_seconds() -> float:
	var duration := semi_fire_audio_seconds
	if fire_audio != null and fire_audio.stream != null:
		duration = minf(duration, fire_audio.stream.get_length())
	if viewmodel != null and viewmodel.animation_player != null:
		var fire_clip := StringName(viewmodel.animation_for(&"fire"))
		if not fire_clip.is_empty() and viewmodel.animation_player.has_animation(fire_clip):
			duration = minf(duration, viewmodel.animation_player.get_animation(fire_clip).length)
	return maxf(duration, 0.03)


func _fire_visual_seconds() -> float:
	return _fire_audio_seconds()


func _clip_duration(alias: StringName) -> float:
	if viewmodel == null or viewmodel.animation_player == null:
		return 0.0
	var animation_name := viewmodel.animation_for(alias)
	if animation_name.is_empty() or not viewmodel.animation_player.has_animation(animation_name):
		return 0.0
	return viewmodel.animation_player.get_animation(animation_name).length


func _viewmodel_mount() -> Node3D:
	if viewmodel == null:
		return null
	return viewmodel.get("model_mount") as Node3D


func _current_viewmodel_clip() -> StringName:
	if viewmodel == null:
		return &""
	var value: Variant = viewmodel.get("current_clip")
	if value is StringName:
		return value
	if value is String:
		return StringName(value)
	return &""


func _play_audio(player: AudioStreamPlayer, pitch_base: float, pitch_spread: float) -> void:
	if player == null or player.stream == null:
		return
	player.pitch_scale = pitch_base + randf() * pitch_spread
	player.play()
