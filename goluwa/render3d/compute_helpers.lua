local glsl_common = import("goluwa/render3d/glsl_common.lua")
local tonemappers = import("goluwa/render3d/tonemappers.lua")
local compute_helpers = {}

function compute_helpers.GetScreenHelpersGLSL()
	return glsl_common.GetLuminanceGLSL() .. [[
		ivec2 get_screen_pos() {
			return ivec2(gl_GlobalInvocationID.xy);
		}

		bool is_screen_pos_in_bounds(ivec2 pos, ivec2 size) {
			return pos.x < size.x && pos.y < size.y;
		}

		vec2 get_screen_uv(ivec2 pos, ivec2 size) {
			return (vec2(pos) + vec2(0.5)) / vec2(size);
		}

		vec2 edge_clamp_uv(vec2 uv, ivec2 texture_size) {
			vec2 half_texel = vec2(0.5) / vec2(texture_size);
			return clamp(uv, half_texel, vec2(1.0) - half_texel);
		}

		vec4 texture_catmull_rom(sampler2D tex, vec2 uv) {
			ivec2 texture_size = textureSize(tex, 0);
			vec2 size = vec2(texture_size);
			vec2 position = uv * size;
			vec2 center = floor(position - 0.5) + 0.5;
			vec2 f = position - center;
			vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
			vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
			vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
			vec2 w3 = f * f * (-0.5 + 0.5 * f);
			vec2 w12 = w1 + w2;
			vec2 tc0 = edge_clamp_uv((center - 1.0) / size, texture_size);
			vec2 tc3 = edge_clamp_uv((center + 2.0) / size, texture_size);
			vec2 tc12 = edge_clamp_uv((center + w2 / w12) / size, texture_size);
			vec4 result =
				textureLod(tex, vec2(tc12.x, tc0.y), 0.0) * (w12.x * w0.y) +
				textureLod(tex, vec2(tc0.x, tc12.y), 0.0) * (w0.x * w12.y) +
				textureLod(tex, vec2(tc12.x, tc12.y), 0.0) * (w12.x * w12.y) +
				textureLod(tex, vec2(tc3.x, tc12.y), 0.0) * (w3.x * w12.y) +
				textureLod(tex, vec2(tc12.x, tc3.y), 0.0) * (w12.x * w3.y);
			float total = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
			return max(result / total, vec4(0.0));
		}
	]]
end

function compute_helpers.GetColorHelpersGLSL()
	return glsl_common.GetLuminanceGLSL() .. glsl_common.GetPQGLSL() .. [[
		vec3 LinearToSRGB(vec3 col) {
			vec3 low = col * 12.92;
			vec3 high = 1.055 * pow(max(col, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
			return mix(low, high, step(0.0031308, col));
		}

		vec3 SRGBToLinear(vec3 col) {
			vec3 low = col / 12.92;
			vec3 high = pow(max((col + 0.055) / 1.055, vec3(0.0)), vec3(2.4));
			return mix(low, high, step(0.04045, col));
		}

		vec3 dither(vec3 encoded, vec3 noise, float steps) {
			if (steps == 0.0) return encoded;

			vec3 r = noise * 2.0 - 1.0;
			r = sign(r) * (1.0 - sqrt(1.0 - abs(r)));
			vec3 amplitude = mix(vec3(0.5), vec3(1.0), clamp(min(encoded, 1.0 - encoded) * steps, 0.0, 1.0));
			return clamp(encoded + r * amplitude / steps, 0.0, 1.0);
		}

	]] .. tonemappers.GetGLSL() .. [[

		vec3 rows_mul(vec3 r0, vec3 r1, vec3 r2, vec3 x) {
			return vec3(dot(r0, x), dot(r1, x), dot(r2, x));
		}

		vec3 slog3_curve(vec3 x) {
			vec3 high = (420.0 + log(max(x + 0.01, vec3(1e-6)) / 0.19) / 2.302585093 * 261.5) / 1023.0;
			vec3 low = (x * (171.2102946929 - 95.0) / 0.01125 + 95.0) / 1023.0;
			return mix(low, high, step(0.01125, x));
		}

		vec3 logc_curve(vec3 x) {
			vec3 high = 0.247190 * log(max(5.555556 * x + 0.052272, vec3(1e-6))) / 2.302585093 + 0.385537;
			vec3 low = 5.367655 * x + 0.092809;
			return mix(low, high, step(0.010591, x));
		}

		mat3 rows_matrix(vec3 r0, vec3 r1, vec3 r2) {
			return transpose(mat3(r0, r1, r2));
		}

		vec3 slog3_inverse(vec3 y) {
			vec3 high = pow(vec3(10.0), (y * 1023.0 - 420.0) / 261.5) * 0.19 - 0.01;
			vec3 low = (y * 1023.0 - 95.0) * 0.01125 / (171.2102946929 - 95.0);
			return mix(low, high, step(171.2102946929 / 1023.0, y));
		}

		vec3 logc_inverse(vec3 y) {
			vec3 high = (pow(vec3(10.0), (y - 0.385537) / 0.247190) - 0.052272) / 5.555556;
			vec3 low = (y - 0.092809) / 5.367655;
			return mix(low, high, step(5.367655 * 0.010591 + 0.092809, y));
		}

		vec3 log_decode(vec3 y, int tonemapper) {
			if (tonemapper == 5) {
				return inverse(rows_matrix(vec3(0.6456795, 0.2591145, 0.0952060), vec3(0.0875300, 0.7596996, 0.1527704), vec3(0.0369574, 0.1292809, 0.8337617))) * slog3_inverse(y);
			}

			return inverse(rows_matrix(vec3(0.6313210, 0.2708007, 0.0978783), vec3(0.0368199, 0.7930370, 0.1701431), vec3(0.0173697, 0.1487892, 0.8338411))) * logc_inverse(y);
		}

		vec3 log_encode(vec3 x, int tonemapper) {
			x = max(x, vec3(0.0));

			if (tonemapper == 5) {
				return slog3_curve(rows_mul(vec3(0.6456795, 0.2591145, 0.0952060), vec3(0.0875300, 0.7596996, 0.1527704), vec3(0.0369574, 0.1292809, 0.8337617), x));
			}

			return logc_curve(rows_mul(vec3(0.6313210, 0.2708007, 0.0978783), vec3(0.0368199, 0.7930370, 0.1701431), vec3(0.0173697, 0.1487892, 0.8338411), x));
		}

	]]
end

return compute_helpers
