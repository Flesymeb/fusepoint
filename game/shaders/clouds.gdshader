shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled;

uniform vec4 cloud_color : source_color = vec4(1.0, 1.0, 1.0, 0.72);
uniform float cloud_scale = 15.0;
uniform float drift_speed = 0.004;
uniform float density = 0.56;

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
	vec2 p = UV * cloud_scale + vec2(TIME * drift_speed, TIME * drift_speed * 0.35);
	float n = noise2(p) * 0.55;
	n += noise2(p * 2.1 + vec2(7.3, -2.4)) * 0.30;
	n += noise2(p * 4.5 - vec2(3.1, 8.7)) * 0.15;
	float cloud = smoothstep(density - 0.16, density + 0.10, n);
	float edge_fade = smoothstep(0.02, 0.14, UV.y) * (1.0 - smoothstep(0.84, 0.99, UV.y));
	ALBEDO = cloud_color.rgb;
	EMISSION = cloud_color.rgb * 0.12;
	ALPHA = cloud * edge_fade * cloud_color.a;
}
