local exposure = import("goluwa/render3d/exposure.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local exposure_compensation = {}
exposure_compensation.REFERENCE_EV = 10
exposure_compensation.MIN_EV = -4
exposure_compensation.MAX_EV = 7
exposure_compensation.block = {{"exposure_compensation_tex", "int"}}

function exposure_compensation.WriteBlock(self, block)
	local texture = post_source.GetExposureTexture(true)
	block.exposure_compensation_tex = texture and self:GetTextureIndex(texture) or -1
	return block
end

function exposure_compensation.GetGLSL()
	return [[
		#ifndef GOLUWA_EXPOSURE_COMPENSATION
		#define GOLUWA_EXPOSURE_COMPENSATION
		float exposure_compensation_ev(int exposure_tex, float fallback) {
			if (exposure_tex == -1) return fallback;

			float current = texture(TEXTURE(exposure_tex), vec2(0.5)).r;

			if (current <= 0.0) return fallback;

			return ]] .. exposure.LOG_EXPOSURE_AT_EV0 .. [[ - log2(current);
		}

		float exposure_compensation_gain(int exposure_tex, float amount, float reference_ev, float min_ev, float max_ev) {
			if (exposure_tex == -1 || amount == 0.0) return 1.0;

			return exp2(clamp(exposure_compensation_ev(exposure_tex, reference_ev) - reference_ev, min_ev, max_ev) * amount);
		}

		float effect_exposure_gain(int exposure_tex, float amount) {
			return exposure_compensation_gain(exposure_tex, amount, ]] .. string.format(
			"%.2f, %.2f, %.2f",
			exposure_compensation.REFERENCE_EV,
			exposure_compensation.MIN_EV,
			exposure_compensation.MAX_EV
		) .. [[);
		}
		#endif
	]]
end

return exposure_compensation
