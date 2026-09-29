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

		// Dithers encoded (0 to 1, in the space the output is quantized in) to
		// hide banding from quantizing it to steps + 1 levels. noise is uniform
		// in 0 to 1 per channel. Reshaped to a triangular distribution of +-1
		// step, the noise is equally strong whatever the value (uniform +-0.5
		// vanishes on exact output levels and peaks between them, Gjol 2016).
		// Within a step of black or white it narrows to +-0.5 so clamping
		// doesn't lift black or dim white. steps 0 turns it off.
		vec3 dither(vec3 encoded, vec3 noise, float steps) {
			if (steps == 0.0) return encoded;

			vec3 r = noise * 2.0 - 1.0;
			r = sign(r) * (1.0 - sqrt(1.0 - abs(r)));
			vec3 amplitude = mix(vec3(0.5), vec3(1.0), clamp(min(encoded, 1.0 - encoded) * steps, 0.0, 1.0));
			return clamp(encoded + r * amplitude / steps, 0.0, 1.0);
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

		// Gran Turismo 7 (Polyphony Digital's MIT sample, ICtCp). A per channel
		// curve is blended with one that keeps the hue and only fades chroma
		// out near peak, so highlights desaturate without skewing. It works in
		// linear BT.2020 where 1.0 is 100 cd/m2. The curve's toe and midpoint
		// are absolute, so only the shoulder moves with the display's peak and
		// SDR (peak 250 cd/m2) and HDR look the same below it.
		vec3 gt7_curve(vec3 x, float peak) {
			const float alpha = 0.25;
			const float mid = 0.538;
			const float linear_section = 0.444;
			const float toe_strength = 1.28;
			const float k = (linear_section - 1.0) / (alpha - 1.0);
			float ka = peak * linear_section + peak * k;
			float kb = -peak * k * exp(linear_section / k);
			float kc = -1.0 / (k * peak);
			vec3 t = clamp(x / mid, 0.0, 1.0);
			vec3 weight_linear = t * t * (3.0 - 2.0 * t);
			vec3 toe = mid * pow(x / mid, vec3(toe_strength));
			vec3 shoulder = ka + kb * exp(x * kc);
			return mix(mix(toe, x, weight_linear), shoulder, step(linear_section * peak, x));
		}

		vec3 gt7_pq_encode(vec3 x) {
			vec3 y = pow(x * 0.01, vec3(0.1593017578125));
			return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), vec3(78.84375));
		}

		vec3 gt7_pq_decode(vec3 n) {
			vec3 np = pow(clamp(n, 0.0, 1.0), vec3(1.0 / 78.84375));
			vec3 l = max(np - 0.8359375, vec3(0.0)) / (18.8515625 - 18.6875 * np);
			return pow(l, vec3(1.0 / 0.1593017578125)) * 100.0;
		}

		vec3 gt7_rgb_to_ictcp(vec3 rgb) {
			const mat3 rgb_to_lms = mat3(
				1688.0, 683.0, 99.0,
				2146.0, 2951.0, 309.0,
				262.0, 462.0, 3688.0
			) / 4096.0;
			const mat3 lms_to_ictcp = mat3(
				2048.0, 6610.0, 17933.0,
				2048.0, -13613.0, -17390.0,
				0.0, 7003.0, -543.0
			) / 4096.0;
			return lms_to_ictcp * gt7_pq_encode(rgb_to_lms * rgb);
		}

		vec3 gt7_ictcp_to_rgb(vec3 ictcp) {
			const mat3 ictcp_to_lms = mat3(
				1.0, 1.0, 1.0,
				0.00860904, -0.00860904, 0.560031,
				0.11103, -0.11103, -0.320627
			);
			const mat3 lms_to_rgb = mat3(
				3.43661, -0.79133, -0.0259499,
				-2.50645, 1.9836, -0.0989137,
				0.0698454, -0.192271, 1.12486
			);
			return max(lms_to_rgb * gt7_pq_decode(ictcp_to_lms * ictcp), vec3(0.0));
		}

		// x is linear BT.709 in units of 100 cd/m2, peak (at least 2.5) in the
		// same units; returns the same
		vec3 gt7(vec3 x, float peak) {
			const mat3 bt709_to_bt2020 = mat3(
				0.6274, 0.0691, 0.0164,
				0.3293, 0.9195, 0.0880,
				0.0433, 0.0114, 0.8956
			);
			const mat3 bt2020_to_bt709 = mat3(
				1.6605, -0.1246, -0.0182,
				-0.5876, 1.1329, -0.1006,
				-0.0728, -0.0083, 1.1187
			);
			const float blend_ratio = 0.6;
			const float fade_start = 0.98;
			const float fade_end = 1.16;

			vec3 rgb = bt709_to_bt2020 * x;
			vec3 ucs = gt7_rgb_to_ictcp(rgb);
			vec3 skewed = gt7_curve(rgb, peak);
			float chroma_scale = 1.0 - smoothstep(fade_start, fade_end, ucs.x / gt7_rgb_to_ictcp(vec3(peak)).x);
			vec3 scaled = gt7_ictcp_to_rgb(vec3(ucs.x, ucs.yz * chroma_scale));
			return max(bt2020_to_bt709 * min(mix(skewed, scaled, blend_ratio), vec3(peak)), vec3(0.0));
		}

		// x is exposed (middle grey at 0.18); returns linear display colour.
		// tonemapper: 0 = AgX, 1 = AgX punchy, 2 = ACES, 3 = GT7
		vec3 tonemap(vec3 x, int tonemapper) {
			x = max(x, vec3(0.0));

			// exposed 1.0 is GT's SDR white of 250 cd/m2, which keeps middle
			// grey at 0.18
			if (tonemapper == 3) return gt7(x * 2.5, 2.5) / 2.5;

			if (tonemapper == 2) return aces_fitted(x);

			return agx(x, tonemapper == 1);
		}
	]]
end

return compute_helpers
