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

		vec3 SRGBToLinear(vec3 col) {
			vec3 low = col / 12.92;
			vec3 high = pow((col + 0.055) / 1.055, vec3(2.4));
			return mix(low, high, step(0.04045, col));
		}

		// AgX (Troy Sobotka), with the polynomial fit of its default contrast
		// curve by Benjamin Wrensch. About 16.5 stops from black to white, and
		// bright saturated colours desaturate towards white instead of
		// skewing hue like a per channel curve does.
		vec3 agx_contrast(vec3 x) {
			vec3 x2 = x * x;
			vec3 x4 = x2 * x2;
			return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
		}

		vec3 agx(vec3 x, bool punchy) {
			const mat3 inset = mat3(
				0.842479062253094, 0.0423282422610123, 0.0423756549057051,
				0.0784335999999992, 0.878468636469772, 0.0784336,
				0.0792237451477643, 0.0791661274605434, 0.879142973793104
			);
			const mat3 outset = mat3(
				1.19687900512017, -0.0528968517574562, -0.0529716355144438,
				-0.0980208811401368, 1.15190312990417, -0.0980434501171241,
				-0.0990297440797205, -0.0989611768448433, 1.15107367264116
			);
			const float min_ev = -12.47393;
			const float max_ev = 4.026069;
			x = clamp(log2(max(inset * x, vec3(1e-10))), min_ev, max_ev);
			x = agx_contrast((x - min_ev) / (max_ev - min_ev));

			// looks: base AgX reads washed out, so the default adds a little
			// saturation; punchy is Blender's
			float saturation = 1.2;

			if (punchy) {
				x = pow(max(x, vec3(0.0)), vec3(1.35));
				saturation = 1.4;
			}

			float luma = dot(x, vec3(0.2126, 0.7152, 0.0722));
			x = luma + saturation * (x - luma);

			// the curve's output is display encoded (gamma 2.2)
			return pow(max(outset * x, vec3(0.0)), vec3(2.2));
		}

		vec3 aces_fitted(vec3 x) {
			return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
		}

		// x is exposed (middle grey at 0.18); returns linear display colour.
		// tonemapper: 0 = AgX, 1 = AgX punchy, 2 = ACES
		vec3 tonemap(vec3 x, int tonemapper) {
			x = max(x, vec3(0.0));

			if (tonemapper == 2) return aces_fitted(x);

			return agx(x, tonemapper == 1);
		}
	]]
end

return compute_helpers
