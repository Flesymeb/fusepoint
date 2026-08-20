class_name FPSMatchScoreHUD
extends Control

## Compact, symmetric FPS match score and timer composition.

@export var left_team := "CROWN"
@export var right_team := "FORGE"
@export_range(0, 999, 1) var left_score := 95
@export_range(0, 999, 1) var right_score := 82
@export_range(0, 5999, 1) var remaining_seconds := 462
@export var match_mode := "DOMINATION"

@onready var _mode_label: Label = %Mode
@onready var _left_team_label: Label = %LeftTeam
@onready var _right_team_label: Label = %RightTeam
@onready var _left_score_label: Label = %LeftScore
@onready var _right_score_label: Label = %RightScore
@onready var _timer_label: Label = %Timer


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_refresh()


func set_match(mode: String, next_left_team: String, next_right_team: String) -> void:
	match_mode = mode
	left_team = next_left_team
	right_team = next_right_team
	_refresh_if_ready()


func set_score(next_left_score: int, next_right_score: int) -> void:
	left_score = clampi(next_left_score, 0, 999)
	right_score = clampi(next_right_score, 0, 999)
	_refresh_if_ready()


func set_time_seconds(seconds: int) -> void:
	remaining_seconds = clampi(seconds, 0, 5999)
	_refresh_if_ready()


func _refresh_if_ready() -> void:
	if is_node_ready():
		_refresh()


func _refresh() -> void:
	_mode_label.text = match_mode.to_upper()
	_left_team_label.text = left_team.to_upper()
	_right_team_label.text = right_team.to_upper()
	_left_score_label.text = str(left_score).pad_zeros(3)
	_right_score_label.text = str(right_score).pad_zeros(3)
	_timer_label.text = "%02d:%02d" % [remaining_seconds / 60, remaining_seconds % 60]
