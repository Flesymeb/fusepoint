class_name GodotxHealthBar2D
extends Node2D

signal value_change_started(from_value: float, to_value: float)
signal value_changed(new_value: float)
signal value_change_finished(final_value: float)

var _value: float = 100.0
var _min_value: float = 0.0
var _max_value: float = 100.0
var _display_value: float = 100.0
var _style: GodotxHealthBarStyle
var _tween: Tween
var _bar_size: Vector2 = Vector2(80, 14)
var _cached_fill_rect: Rect2
var _label_text: String = ""
var _icon_instance: Node
var _follow_target: Node2D
var _follow_offset: Vector2 = Vector2(0, -16)
var _center_on_target: bool = true
var _billboard_scale: bool = false
var _base_scale: Vector2 = Vector2.ONE

@export var style: GodotxHealthBarStyle:
	set(v):
		if v:
			_style = v
		else:
			_style = _get_default_style()
		_queue_update_fill_rect()
		queue_redraw()
	get:
		return _style if _style else _get_default_style()

@export var bar_size: Vector2 = Vector2(80, 14):
	set(v):
		_bar_size = Vector2(maxf(4, v.x), maxf(4, v.y))
		_queue_update_fill_rect()
		queue_redraw()
	get:
		return _bar_size

@export var value: float = 100.0:
	set(v):
		set_value(v, true)
	get:
		return _value

@export var min_value: float = 0.0:
	set(v):
		_min_value = v
		queue_redraw()
	get:
		return _min_value

@export var max_value: float = 100.0:
	set(v):
		_max_value = v
		queue_redraw()
	get:
		return _max_value

@export var follow_target: Node2D:
	set(v):
		_follow_target = v
	get:
		return _follow_target

@export var follow_offset: Vector2 = Vector2(0, -24):
	set(v):
		_follow_offset = v
	get:
		return _follow_offset

@export var center_on_target: bool = true:
	set(v):
		_center_on_target = v
	get:
		return _center_on_target

@export var billboard_scale: bool = false:
	set(v):
		_billboard_scale = v
	get:
		return _billboard_scale

func _get_default_style() -> GodotxHealthBarStyle:
	if _style != null:
		return _style
	_style = GodotxHealthBarStyle.new()
	return _style

func _init() -> void:
	if _style == null:
		_style = GodotxHealthBarStyle.new()

func _ready() -> void:
	if not style:
		_style = GodotxHealthBarStyle.new()
	if style.use_threshold_colors:
		style.validate_thresholds()
	_queue_update_fill_rect()
	queue_redraw()

func _process(_delta: float) -> void:
	if is_instance_valid(_follow_target):
		var target_pos = _follow_target.global_position
		if _center_on_target:
			global_position = target_pos + Vector2(-_bar_size.x * 0.5, _follow_offset.y)
		else:
			global_position = target_pos + _follow_offset
	if _billboard_scale:
		var cam = get_viewport().get_camera_2d()
		if cam:
			var zoom = cam.zoom
			var s = 1.0 / minf(zoom.x, zoom.y)
			scale = _base_scale * s
		else:
			scale = _base_scale

func _queue_update_fill_rect() -> void:
	_cached_fill_rect = _compute_fill_rect()

func _compute_fill_rect() -> Rect2:
	var st = style
	var border = st.border_thickness if st.border_enabled else 0
	var inset = st.fill_inset
	if inset.x == 0 and inset.y == 0:
		inset = Vector2(border, border)
	var inner_size = _bar_size - Vector2((border + inset.x) * 2, (border + inset.y) * 2)
	if inner_size.x <= 0 or inner_size.y <= 0:
		return Rect2(Vector2(border + inset.x, border + inset.y), Vector2.ZERO)
	# _display_value is always normalized 0..100 by set_value/_set_display_value
	var t = clampf(_display_value / 100.0, 0.0, 1.0)
	return Rect2(Vector2(border + inset.x, border + inset.y), Vector2(inner_size.x * t, inner_size.y))

func set_value(v: float, animate: bool = true) -> void:
	var range_ok = max_value - min_value
	if range_ok <= 0:
		push_warning("GodotxHealthBar2D: max_value <= min_value")
		range_ok = 100.0
	var normalized = clampf((v - min_value) / range_ok * 100.0, 0, 100.0)
	var prev = _value
	_value = normalized
	var use_animate = animate and style.animation_enabled and style.animation_mode == GodotxHealthBarEnums.AnimationMode.TWEEN
	if use_animate and abs(_display_value - _value) > style.animation_snap_threshold:
		value_change_started.emit(prev, _value)
		if _tween and _tween.is_valid():
			_tween.kill()
		_tween = create_tween()
		var dur = style.animation_duration
		var ease = style.animation_easing
		var trans = style.animation_transition
		if _value < _display_value and style.animation_duration_decrease >= 0:
			dur = style.animation_duration_decrease
			ease = style.animation_easing_decrease
			trans = style.animation_transition_decrease
		_tween.set_ease(ease)
		_tween.set_trans(trans)
		_tween.tween_method(_set_display_value, _display_value, _value, dur)
		_tween.tween_callback(_on_animation_finished)
	else:
		_set_display_value(_value)
		value_changed.emit(_value)
		queue_redraw()

func _set_display_value(v: float) -> void:
	_display_value = clampf(v, 0, 100.0)
	_queue_update_fill_rect()
	value_changed.emit(_display_value)
	queue_redraw()

func _on_animation_finished() -> void:
	value_change_finished.emit(_display_value)

func get_value() -> float:
	return _value

func _draw() -> void:
	var st = style
	if not st:
		return
	var bar_rect = Rect2(Vector2.ZERO, _bar_size)
	var inner_rect = Rect2(
		Vector2(st.border_thickness if st.border_enabled else 0, st.border_thickness if st.border_enabled else 0),
		_bar_size - Vector2((st.border_thickness if st.border_enabled else 0) * 2, (st.border_thickness if st.border_enabled else 0) * 2)
	)
	var inset = st.fill_inset
	var border = st.border_thickness if st.border_enabled else 0
	if inset.x == 0 and inset.y == 0:
		inset = Vector2(border, border)
	inner_rect = Rect2(inner_rect.position + Vector2(inset.x, inset.y), inner_rect.size - inset * 2)
	if inner_rect.size.x < 0 or inner_rect.size.y < 0:
		inner_rect.size = Vector2.ZERO
	var fill_rect = _cached_fill_rect
	var radius = st.get_effective_round_radius(inner_rect.size.y)

	if st.shadow_enabled:
		var apply = st.shadow_apply_to
		if apply == 1 or apply == 3:
			GodotxHealthBarDraw.draw_shadow_approximate(self, bar_rect, radius + border, st.shadow_color, st.shadow_offset, maxi(1, st.shadow_blur_passes))
		if apply == 2 or apply == 3:
			GodotxHealthBarDraw.draw_shadow_approximate(self, fill_rect, radius, st.shadow_color, st.shadow_offset, maxi(1, st.shadow_blur_passes))

	if st.border_enabled:
		GodotxHealthBarDraw.draw_rounded_rect_stroke(self, bar_rect, st.border_color, float(st.border_thickness), radius + border, st.border_join_round, st.background_color)

	if inner_rect.size.x > 0 and inner_rect.size.y > 0:
		GodotxHealthBarDraw.draw_rounded_rect_filled(self, inner_rect, st.background_color, radius)
	var fill_color = st.get_fill_color_for_value(_display_value)
	if fill_rect.size.x > 0 and fill_rect.size.y > 0:
		GodotxHealthBarDraw.draw_rounded_rect_filled(self, fill_rect, fill_color, radius)
	elif inner_rect.size.x > 0 and inner_rect.size.y > 0:
		var fill_w = inner_rect.size.x * clampf(_display_value / 100.0, 0.0, 1.0)
		if fill_w > 0:
			GodotxHealthBarDraw.draw_rounded_rect_filled(self, Rect2(inner_rect.position, Vector2(fill_w, inner_rect.size.y)), fill_color, radius)

	if st.gradient_enabled:
		var g_apply = st.gradient_apply_to
		if g_apply == 1 or g_apply == 3:
			GodotxHealthBarDraw.draw_gradient_overlay(self, inner_rect, radius, st)
		if g_apply == 2 or g_apply == 3:
			GodotxHealthBarDraw.draw_gradient_overlay(self, fill_rect, radius, st)

	_draw_label_2d(bar_rect, inner_rect)
	_draw_icon_2d(bar_rect, inner_rect)

func _draw_label_2d(bar_rect: Rect2, inner_rect: Rect2) -> void:
	var st = style
	if not st.label_enabled:
		return
	var text = _format_label(st)
	var font_to_use: Font = st.font if st.font else ThemeDB.fallback_font
	if font_to_use == null:
		var root = get_tree().root if is_inside_tree() else null
		if root:
			font_to_use = root.get_theme_default_font()
	if font_to_use == null:
		return
	var font_size = maxi(8, st.font_size)
	var ts = font_to_use.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var ascent = font_to_use.get_ascent(font_size)
	var pos: Vector2
	match st.label_position:
		GodotxHealthBarEnums.LabelPosition.TOP:
			pos = Vector2(bar_rect.position.x + bar_rect.size.x * 0.5 - ts.x * 0.5, bar_rect.position.y - ts.y - st.label_offset.y) + st.label_offset
		GodotxHealthBarEnums.LabelPosition.BOTTOM:
			pos = Vector2(bar_rect.position.x + bar_rect.size.x * 0.5 - ts.x * 0.5, bar_rect.end.y + st.label_offset.y) + Vector2(st.label_offset.x, 0)
		GodotxHealthBarEnums.LabelPosition.LEFT:
			pos = Vector2(bar_rect.position.x - ts.x - st.label_offset.x, bar_rect.position.y + bar_rect.size.y * 0.5 - ts.y * 0.5) + Vector2(0, st.label_offset.y)
		GodotxHealthBarEnums.LabelPosition.RIGHT:
			pos = Vector2(bar_rect.end.x + st.label_offset.x, bar_rect.position.y + bar_rect.size.y * 0.5 - ts.y * 0.5) + Vector2(0, st.label_offset.y)
		GodotxHealthBarEnums.LabelPosition.CENTER_INSIDE:
			pos = inner_rect.position + (inner_rect.size - ts) * 0.5 + st.label_offset
		_:
			pos = inner_rect.position + (inner_rect.size - ts) * 0.5 + st.label_offset
	pos.y += ascent
	var crid = get_canvas_item()
	if not crid.is_valid():
		return
	if st.outline_size > 0:
		font_to_use.draw_string_outline(crid, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, st.outline_size, st.outline_color)
	if st.label_shadow_enabled:
		font_to_use.draw_string(crid, pos + st.label_shadow_offset, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, st.label_shadow_color)
	font_to_use.draw_string(crid, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, st.font_color)

func _format_label(st: GodotxHealthBarStyle) -> String:
	var v = _display_value
	var mx = st.label_custom_max
	var num_val: float = (v / 100.0) * mx if st.label_format.contains("{max}") else v
	return st.label_format.replace("{value}", str(int(roundf(num_val)))).replace("{max}", str(int(mx)))

func _draw_icon_2d(bar_rect: Rect2, inner_rect: Rect2) -> void:
	var st = style
	if not st.icon_enabled:
		return
	var default_icon_size = maxf(inner_rect.size.y, 16)
	var sz = st.icon_forced_size
	if sz.x <= 0 or sz.y <= 0:
		sz = Vector2(default_icon_size, default_icon_size)
	var offset = st.icon_offset
	var pos: Vector2
	match st.icon_position:
		GodotxHealthBarEnums.IconPosition.BEFORE:
			pos = Vector2(bar_rect.position.x - sz.x + offset.x, bar_rect.position.y + bar_rect.size.y * 0.5 - sz.y * 0.5 + offset.y)
		GodotxHealthBarEnums.IconPosition.AFTER:
			pos = Vector2(bar_rect.end.x + offset.x, bar_rect.position.y + bar_rect.size.y * 0.5 - sz.y * 0.5 + offset.y)
		GodotxHealthBarEnums.IconPosition.ABOVE:
			pos = Vector2(bar_rect.position.x + bar_rect.size.x * 0.5 - sz.x * 0.5 + offset.x, bar_rect.position.y - sz.y + offset.y)
		GodotxHealthBarEnums.IconPosition.BELOW:
			pos = Vector2(bar_rect.position.x + bar_rect.size.x * 0.5 - sz.x * 0.5 + offset.x, bar_rect.end.y + offset.y)
		GodotxHealthBarEnums.IconPosition.INSIDE_LEFT:
			pos = inner_rect.position + offset
		GodotxHealthBarEnums.IconPosition.INSIDE_RIGHT:
			pos = Vector2(inner_rect.end.x - sz.x, inner_rect.position.y) + offset
		_:
			pos = bar_rect.position + offset
	var icon_rect = Rect2(pos, sz)
	if st.icon_texture:
		GodotxHealthBarDraw.draw_texture_fitted(self, icon_rect, st.icon_texture, st.icon_tint, st.icon_fit_mode)
	elif st.icon_scene and _icon_instance == null:
		var inst = st.icon_scene.instantiate()
		if inst is Control:
			inst.position = pos
			inst.size = sz
			add_child(inst)
			_icon_instance = inst
		elif inst is Node2D:
			inst.position = pos
			add_child(inst)
			_icon_instance = inst
		else:
			push_error("GodotxHealthBar2D: icon_scene root must be Control or Node2D")
			if is_instance_valid(inst):
				inst.queue_free()
	else:
		GodotxHealthBarDraw.draw_rounded_rect_filled(self, icon_rect, Color(st.icon_tint.r, st.icon_tint.g, st.icon_tint.b, 0.6), minf(4, minf(sz.x, sz.y) * 0.5))
		GodotxHealthBarDraw.draw_rounded_rect_filled(self, Rect2(icon_rect.position + Vector2(2, 2), icon_rect.size - Vector2(4, 4)), st.icon_tint, minf(2, minf(sz.x, sz.y) * 0.25))
