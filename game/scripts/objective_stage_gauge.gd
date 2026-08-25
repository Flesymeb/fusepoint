class_name FusepointObjectiveStageGauge
extends Control

const TRACK_COLOR := Color(0.02, 0.045, 0.05, 0.68)
const EMPTY_COLOR := Color(0.20, 0.25, 0.24, 0.82)
const ACTIVE_COLOR := Color(1.0, 0.70, 0.18, 0.96)
const COMPLETE_COLOR := Color(0.18, 0.92, 0.76, 0.98)
const CONTESTED_COLOR := Color(1.0, 0.28, 0.12, 0.96)
const LOCKED_COLOR := Color(0.48, 0.52, 0.50, 0.70)

var segment_count := 3
var completed_count := 0
var active_index := -1
var active_progress := 0.0
var contested := false
var locked := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _get_minimum_size() -> Vector2:
	return Vector2(180.0, 12.0)


func set_capture_progress(progress: float, active: bool, is_contested: bool, complete: bool) -> void:
	segment_count = 12
	completed_count = 12 if complete else clampi(int(floor(clampf(progress, 0.0, 1.0) * 12.0)), 0, 12)
	active_index = clampi(completed_count, 0, 11) if active and not complete else -1
	active_progress = clampf(progress * 12.0 - floor(progress * 12.0), 0.0, 1.0) if active and not complete else 0.0
	contested = is_contested
	locked = false
	queue_redraw()


func set_defusal_progress(done_count: int, stage_index: int, progress: float, is_active: bool, is_locked: bool, is_contested: bool, complete: bool) -> void:
	segment_count = 3
	completed_count = 3 if complete else clampi(done_count, 0, 3)
	active_index = clampi(stage_index, 0, 2) if is_active and not complete else -1
	active_progress = clampf(progress, 0.0, 1.0) if is_active and not complete else 0.0
	contested = is_contested
	locked = is_locked
	queue_redraw()


func _draw() -> void:
	var track := Rect2(Vector2.ZERO, size)
	draw_rect(track, TRACK_COLOR, true)
	if segment_count <= 0:
		return
	var gap := 3.0
	var usable_width := maxf(size.x - gap * float(segment_count - 1), 1.0)
	var segment_width := maxf(floor(usable_width / float(segment_count)), 2.0)
	var height := maxf(size.y, 8.0)
	for index in range(segment_count):
		var x := float(index) * (segment_width + gap)
		var rect := Rect2(Vector2(x, 0.0), Vector2(segment_width, height))
		var color := LOCKED_COLOR if locked else EMPTY_COLOR
		if index < completed_count:
			color = COMPLETE_COLOR
		elif index == active_index:
			color = CONTESTED_COLOR if contested else ACTIVE_COLOR
		draw_rect(rect, color, true)
		if index == active_index and active_progress > 0.0:
			var fill_color := CONTESTED_COLOR if contested else ACTIVE_COLOR
			var fill_rect := Rect2(rect.position, Vector2(rect.size.x * active_progress, rect.size.y))
			draw_rect(fill_rect, fill_color, true)
