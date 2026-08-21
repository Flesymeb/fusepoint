shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled;

uniform vec4 cloud_color : source_color = vec4(0.98, 0.99, 1.0, 0.34);
uniform float cloud_scale = 14.0;
uniform float drift_speed = 0.0035;
uniform float density = 0.57;
uniform float sun_response = 0.16;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	vec2 p = UV * cloud_scale + vec2(TIME * drift_speed, TIME * drift_speed * 0.31);
	float n = noise2(p) * 0.55;
	n += noise2(p * 2.1 + vec2(7.3, -2.4)) * 0.30;
	n += noise2(p * 4.5 - vec2(3.1, 8.7)) * 0.15;
	float cloud = smoothstep(density - 0.16, density + 0.10, n);
	float radial_edge = 1.0 - smoothstep(0.34, 0.50, length(UV - vec2(0.5)));
	float light_response = mix(0.86, 1.0 + sun_response, smoothstep(0.45, 0.82, n));
	ALBEDO = cloud_color.rgb * light_response;
	EMISSION = cloud_color.rgb * sun_response;
	ALPHA = cloud * radial_edge * cloud_color.a;
}
