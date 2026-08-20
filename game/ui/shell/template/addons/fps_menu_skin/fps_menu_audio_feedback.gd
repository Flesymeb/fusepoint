class_name FPSMenuAudioFeedback
extends "res://ui/shell/template/addons/maaacks_menus_template/base/nodes/autoloads/ui_sound_controller/ui_sound_controller.gd"

## Extends the template's existing UI sound router with one restrained cancel cue.

@export var back_pressed: AudioStream

var _back_player: AudioStreamPlayer


func _ready() -> void:
	super._ready()
	_back_player = _build_stream_player(back_pressed, "BackPressed")


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _back_player != null:
		_play_stream(_back_player)
