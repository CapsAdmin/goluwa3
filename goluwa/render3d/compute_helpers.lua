local compute_helpers = {}

function compute_helpers.GetScreenHelpersGLSL()
	return [[
		ivec2 get_screen_pos() {
			return ivec2(gl_GlobalInvocationID.xy);
		}

		bool is_screen_pos_in_bounds(ivec2 pos, ivec2 size) {
			return pos.x < size.x && pos.y < size.y;
		}

		vec2 get_screen_uv(ivec2 pos, ivec2 size) {
			return (vec2(pos) + vec2(0.5)) / vec2(size);
		}
	]]
end

function compute_helpers.GetColorHelpersGLSL()
	return [[
		vec3 LinearToSRGB(vec3 col) {
			vec3 low = col * 12.92;
			vec3 high = 1.055 * pow(col, vec3(1.0 / 2.4)) - 0.055;
			return mix(low, high, step(0.0031308, col));
		}

		vec3 tonemap(vec3 x, float exposure) {
			x *= exposure;
			const float a = 2.51;
			const float b = 0.03;
			const float c = 2.43;
			const float d = 0.59;
			const float e = 0.14;
			vec3 col = (x * (a * x + b)) / (x * (c * x + d) + e);
			col = pow(col * 0.75, vec3(1.5)) * 1.25;
			return col;
		}

		vec3 tonemap_lottes(vec3 rgb) {
			const vec3 a = vec3(1.5);
			const vec3 d = vec3(0.91);
			const vec3 hdr_max = vec3(8.0);
			const vec3 mid_in = vec3(0.26);
			const vec3 mid_out = vec3(0.32);

			const vec3 b = (-pow(mid_in, a) + pow(hdr_max, a) * mid_out) /
				((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);
			const vec3 c = (pow(hdr_max, a * d) * pow(mid_in, a) -
							pow(hdr_max, a) * pow(mid_in, a * d) * mid_out) /
				((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);

			return pow(rgb, a) / (pow(rgb, a * d) * b + c);
		}
	]]
end

return compute_helpers
