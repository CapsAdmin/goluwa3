local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local gi = {}
gi.MODES = {none = 0, ddgi = 1}
gi.MIN_WEIGHT = ddgi.MIN_WEIGHT

function gi.GetMode()
	if render3d.IsPassEnabled("ddgi") then return "ddgi" end

	return "none"
end

function gi.GetScreenTexture()
	local mode = gi.GetMode()

	if mode == "ddgi" then return ddgi.GetScreenTexture() end

	return nil
end

function gi.GetScreenGeometryTexture()
	local mode = gi.GetMode()

	if mode == "ddgi" then return ddgi.GetScreenGeometryTexture() end

	return nil
end

function gi.GetScreenSpecularTexture()
	local mode = gi.GetMode()

	if mode == "ddgi" then return ddgi.GetScreenSpecularTexture() end

	return nil
end

function gi.IsDebugGI()
	local mode = gi.GetMode()

	if mode == "ddgi" then return ddgi.IsDebugGI() end

	return false
end

function gi.GetDebugOverlayTexture()
	if gi.GetMode() ~= "ddgi" then return nil end

	return ddgi.GetDebugOverlayTexture()
end

function gi.ResetHistory()
	ddgi.ResetHistory()
end

function gi.GetProbeBlockLayout()
	local layout = table.copy(ddgi.GetProbeBlockLayout())
	layout[#layout + 1] = {"gi_mode", "int"}
	return layout
end

function gi.WriteProbeBlock(self, block)
	ddgi.WriteProbeBlock(self, block)
	local mode = gi.GetMode()
	block.gi_mode = gi.MODES[mode]

	if mode ~= "ddgi" then
		block.ddgi_cascade_count = 0
		block.ddgi_reset_mask = 0
		block.ddgi_update_mask = 0
		block.ddgi_rt_ready = render.GetDevice().ray_query_supported and 1 or 0
	end

	return block
end

function gi.GetCommonGLSL()
	return ddgi.GetCommonGLSL() .. [[

		#define GI_MODE_NONE 0
		#define GI_MODE_DDGI 1

		bool gi_available() {
			return ddgi_data.ddgi_cascade_count > 0;
		}

		bool gi_in_volume(vec3 P) {
			return ddgi_in_volume(P);
		}

		bool gi_covers(vec3 P, float weight) {
			return weight > 0.0 || ddgi_data.gi_mode == GI_MODE_DDGI && ddgi_in_volume(P);
		}

		vec4 gi_sample_irradiance_pair(vec3 P, vec3 N, vec3 L, vec3 L2, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight, out vec4 second) {
			return ddgi_sample_irradiance_pair(P, N, L, L2, V, smooth_blend, visibility_min_weight, weight, second);
		}

		vec4 gi_sample_irradiance(vec3 P, vec3 N, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight) {
			vec4 second;
			return gi_sample_irradiance_pair(P, N, N, N, V, smooth_blend, visibility_min_weight, weight, second);
		}
	]]
end

function gi.GetMediumGLSL()
	return ddgi.GetMediumGLSL() .. [[

		vec4 gi_sample_medium(vec3 P, vec3 N, out float weight) {
			return ddgi_sample_medium(P, N, weight);
		}
	]]
end

return gi
