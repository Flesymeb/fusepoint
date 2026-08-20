class_name GodotxHealthBarDraw
extends RefCounted

static func make_rounded_rect_polygon(rect: Rect2, radius: float) -> PackedVector2Array:
	var r = clampf(radius, 0, minf(rect.size.x, rect.size.y) * 0.5)
	var x0 = rect.position.x
	var y0 = rect.position.y
	var w = rect.size.x
	var h = rect.size.y
	if w <= 0 or h <= 0:
		return PackedVector2Array()
	# Godot expects counter-clockwise order (interior on left when walking boundary).
	if r <= 0:
		return PackedVector2Array([
			Vector2(x0, y0),
			Vector2(x0, y0 + h),
			Vector2(x0 + w, y0 + h),
			Vector2(x0 + w, y0)
		])
	var pts: PackedVector2Array = []
	var steps = 12  # segments per 90° arc for smooth edges
	# Walk counter-clockwise: top (left->right), right (top->bottom), bottom (right->left), left (bottom->top).
	pts.append(Vector2(x0 + r, y0))
	pts.append(Vector2(x0 + w - r, y0))
	# Top-right arc: center (x0+w-r, y0+r), angle -PI/2 -> 0
	for i in range(1, steps + 1):
		var t = float(i) / float(steps)
		var angle = -PI * 0.5 + (PI * 0.5) * t
		pts.append(Vector2(x0 + w - r + r * cos(angle), y0 + r + r * sin(angle)))
	pts.append(Vector2(x0 + w, y0 + h - r))
	# Bottom-right arc: center (x0+w-r, y0+h-r), angle 0 -> PI/2
	for i in range(1, steps + 1):
		var t = float(i) / float(steps)
		var angle = (PI * 0.5) * t
		pts.append(Vector2(x0 + w - r + r * cos(angle), y0 + h - r + r * sin(angle)))
	pts.append(Vector2(x0 + r, y0 + h))
	# Bottom-left arc: center (x0+r, y0+h-r), angle PI/2 -> PI
	for i in range(1, steps + 1):
		var t = float(i) / float(steps)
		var angle = PI * 0.5 + (PI * 0.5) * t
		pts.append(Vector2(x0 + r + r * cos(angle), y0 + h - r + r * sin(angle)))
	pts.append(Vector2(x0, y0 + r))
	# Top-left arc: center (x0+r, y0+r), angle PI -> 3*PI/2
	for i in range(1, steps + 1):
		var t = float(i) / float(steps)
		var angle = PI + (PI * 0.5) * t
		pts.append(Vector2(x0 + r + r * cos(angle), y0 + r + r * sin(angle)))
	return pts

static func draw_rounded_rect_filled(canvas: CanvasItem, rect: Rect2, color: Color, radius: float) -> void:
	var pts = make_rounded_rect_polygon(rect, radius)
	if pts.size() < 3:
		return
	canvas.draw_colored_polygon(pts, color)

static func draw_rounded_rect_stroke(canvas: CanvasItem, rect: Rect2, color: Color, width: float, radius: float, _join_round: bool, inner_fill_color: Color) -> void:
	var r = clampf(radius, 0, minf(rect.size.x, rect.size.y) * 0.5)
	if width <= 0:
		return
	var inner = Rect2(rect.position + Vector2(width, width), rect.size - Vector2(width * 2, width * 2))
	if inner.size.x <= 0 or inner.size.y <= 0:
		return
	var inner_r = maxf(0, r - width)
	draw_rounded_rect_filled(canvas, rect, color, r)
	draw_rounded_rect_filled(canvas, inner, inner_fill_color, inner_r)

static func draw_shadow_approximate(canvas: CanvasItem, rect: Rect2, radius: float, shadow_color: Color, offset: Vector2, passes: int) -> void:
	for i in range(passes, 0, -1):
		var alpha = shadow_color.a * (float(i) / float(passes)) * 0.5
		var c = Color(shadow_color.r, shadow_color.g, shadow_color.b, alpha)
		var r2 = rect
		r2.position += offset * (float(passes - i + 1) / float(passes))
		var pts = make_rounded_rect_polygon(r2, radius + i * 2)
		canvas.draw_colored_polygon(pts, c)
	canvas.draw_colored_polygon(make_rounded_rect_polygon(rect, radius), Color(0, 0, 0, 0))

static func draw_gradient_overlay(canvas: CanvasItem, rect: Rect2, _radius: float, style: GodotxHealthBarStyle) -> void:
	if not style.gradient_enabled or style.gradient_intensity <= 0:
		return
	var steps = 24
	match style.gradient_direction:
		GodotxHealthBarEnums.GradientDirection.HORIZONTAL:
			for i in range(steps):
				var t0 = float(i) / float(steps)
				var t1 = float(i + 1) / float(steps)
				var x0 = rect.position.x + rect.size.x * t0
				var x1 = rect.position.x + rect.size.x * t1
				var c = style.gradient_start_color.lerp(style.gradient_end_color, (t0 + t1) * 0.5)
				c.a *= style.gradient_intensity
				canvas.draw_rect(Rect2(x0, rect.position.y, x1 - x0, rect.size.y), c)
		GodotxHealthBarEnums.GradientDirection.VERTICAL:
			for i in range(steps):
				var t0 = float(i) / float(steps)
				var t1 = float(i + 1) / float(steps)
				var y0 = rect.position.y + rect.size.y * t0
				var y1 = rect.position.y + rect.size.y * t1
				var c = style.gradient_start_color.lerp(style.gradient_end_color, (t0 + t1) * 0.5)
				c.a *= style.gradient_intensity
				canvas.draw_rect(Rect2(rect.position.x, y0, rect.size.x, y1 - y0), c)
		GodotxHealthBarEnums.GradientDirection.DIAGONAL_TOP_LEFT, GodotxHealthBarEnums.GradientDirection.DIAGONAL_BOTTOM_LEFT:
			var sy: float = 1.0 if style.gradient_direction == GodotxHealthBarEnums.GradientDirection.DIAGONAL_TOP_LEFT else -1.0
			for i in range(steps):
				var t = (float(i) + 0.5) / float(steps)
				var c = style.gradient_start_color.lerp(style.gradient_end_color, t)
				c.a *= style.gradient_intensity
				var x0 = rect.position.x + rect.size.x * float(i) / float(steps)
				var x1 = rect.position.x + rect.size.x * float(i + 1) / float(steps)
				var y0 = rect.position.y + rect.size.y * (1.0 - sy) * 0.5 + sy * rect.size.y * float(i) / float(steps)
				var y1 = rect.position.y + rect.size.y * (1.0 - sy) * 0.5 + sy * rect.size.y * float(i + 1) / float(steps)
				var pts = PackedVector2Array([
					Vector2(x0, rect.position.y), Vector2(x1, rect.position.y),
					Vector2(x1, rect.position.y + rect.size.y), Vector2(x0, rect.position.y + rect.size.y)
				])
				canvas.draw_colored_polygon(pts, c)
		_:
			pass

static func draw_texture_fitted(canvas: CanvasItem, rect: Rect2, texture: Texture2D, tint: Color, fit_mode: int) -> void:
	if not texture:
		return
	var ts = texture.get_size()
	if ts.x <= 0 or ts.y <= 0:
		return
	var src_rect = Rect2(Vector2.ZERO, ts)
	var dst_rect = rect
	match fit_mode:
		GodotxHealthBarEnums.IconFitMode.FIT:
			var scale = minf(rect.size.x / ts.x, rect.size.y / ts.y)
			var sz = ts * scale
			dst_rect = Rect2(rect.position + (rect.size - sz) * 0.5, sz)
		GodotxHealthBarEnums.IconFitMode.FILL:
			var scale = maxf(rect.size.x / ts.x, rect.size.y / ts.y)
			var sz = ts * scale
			dst_rect = Rect2(rect.position + (rect.size - sz) * 0.5, sz)
		GodotxHealthBarEnums.IconFitMode.STRETCH:
			pass
	canvas.draw_texture_rect_region(texture, dst_rect, src_rect, tint)
