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
			x = max(x * exposure, vec3(0.0));
			return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
		}

		vec3 tonemap_extended(vec3 x, float exposure) {
			const float peak = 4.0;
			return tonemap(x, exposure / peak) * peak;
		}
	]]
end

return compute_helpers
