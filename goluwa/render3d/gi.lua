local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local radiance_cache = import("goluwa/render3d/radiance_cache.lua")
local radiance = import("goluwa/render3d/radiance.lua")
local gi = {}
gi.MODES = {none = 0, radiance_cache = 1}
gi.MIN_WEIGHT = radiance_cache.MIN_WEIGHT

function gi.GetMode()
	if render3d.IsPassEnabled("radiance_cache") then return "radiance_cache" end

	return "none"
end

function gi.IsPerPixel()
	return render3d.IsPassEnabled("radiance")
end

function gi.GetScreenTexture()
	if gi.IsPerPixel() then return radiance.GetOutputTexture(1) end

	return nil
end

function gi.GetScreenGeometryTexture()
	if gi.IsPerPixel() then return radiance.GetOutputTexture(2) end

	return nil
end

function gi.GetScreenSpecularTexture()
	if gi.IsPerPixel() then return radiance.GetSpecularTexture() end

	return nil
end

function gi.IsDebugGI()
	if gi.IsPerPixel() then return radiance.IsDebugGI() end

	return false
end

function gi.GetDebugOverlayTexture()
	if gi.GetMode() ~= "radiance_cache" then return nil end

	return radiance_cache.GetDebugOverlayTexture()
end

function gi.ResetHistory()
	radiance_cache.ResetHistory()
	radiance.ResetHistory()
end

function gi.GetProbeBlockLayout()
	local layout = table.copy(radiance_cache.GetProbeBlockLayout())
	layout[#layout + 1] = {"gi_mode", "int"}
	return layout
end

function gi.WriteProbeBlock(self, block)
	radiance_cache.WriteProbeBlock(self, block)
	local mode = gi.GetMode()
	block.gi_mode = gi.MODES[mode]

	if mode ~= "radiance_cache" then
		block.radiance_cache_cascade_count = 0
		block.radiance_cache_reset_mask = 0
		block.radiance_cache_update_mask = 0
		block.radiance_cache_rt_ready = render.GetDevice().ray_query_supported and 1 or 0
	end

	return block
end

function gi.GetCommonGLSL()
	return radiance_cache.GetCommonGLSL() .. [[

		#define GI_MODE_NONE 0
		#define GI_MODE_CACHE 1

		bool gi_available() {
			return radiance_cache_data.radiance_cache_cascade_count > 0;
		}

		bool gi_in_volume(vec3 P) {
			return radiance_cache_in_volume(P);
		}

		bool gi_covers(vec3 P, float weight) {
			return weight > 0.0 || radiance_cache_data.gi_mode == GI_MODE_CACHE && radiance_cache_in_volume(P);
		}

		vec4 gi_sample_irradiance_pair(vec3 P, vec3 N, vec3 L, vec3 L2, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight, out vec4 second) {
			return radiance_cache_sample_irradiance_pair(P, N, L, L2, V, smooth_blend, visibility_min_weight, weight, second);
		}

		vec4 gi_sample_irradiance(vec3 P, vec3 N, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight) {
			vec4 second;
			return gi_sample_irradiance_pair(P, N, N, N, V, smooth_blend, visibility_min_weight, weight, second);
		}
	]]
end

function gi.GetMediumGLSL()
	return radiance_cache.GetMediumGLSL() .. [[

		vec4 gi_sample_medium(vec3 P, vec3 N, out float weight) {
				return radiance_cache_sample_medium(P, N, weight);
		}
	]]
end

return gi
