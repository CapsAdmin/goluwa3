local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ambient_occlusion = import("goluwa/render3d/ambient_occlusion.lua")
local normal_debug = import("goluwa/render3d/normal_debug.lua")
local post_source = {}

function post_source.GetOpaqueSceneFramebuffer()
	if render3d.IsWaterEnabled() then
		if render3d.IsPassEnabled("ocean") then
			local current_idx = system.GetFrameNumber() % 2 + 1

			if render3d.pipelines.ocean_resolve.framebuffers then
				return render3d.pipelines.ocean_resolve:GetFramebuffer(current_idx)
			end

			if render3d.pipelines.ocean.framebuffers then
				return render3d.pipelines.ocean:GetFramebuffer(current_idx)
			end
		end
	end

	if not render3d.HasPass("lighting") then return nil end

	if not render3d.IsPassEnabled("lighting") then
		return render3d.pipelines.lighting_albedo:GetFramebuffer(1)
	end

	return render3d.pipelines.lighting:GetFramebuffer(1)
end

function post_source.GetOpaqueSceneTexture()
	local framebuffer = post_source.GetOpaqueSceneFramebuffer()
	return framebuffer and framebuffer:GetAttachment(1) or nil
end

function post_source.GetFoggedOpaqueSceneFramebuffer()
	if render3d.IsPassEnabled("volumetric_fog") then
		return render3d.pipelines.volumetric_fog:GetFramebuffer()
	end

	return post_source.GetOpaqueSceneFramebuffer()
end

function post_source.GetFoggedOpaqueSceneTexture()
	local framebuffer = post_source.GetFoggedOpaqueSceneFramebuffer()
	return framebuffer and framebuffer:GetAttachment(1) or nil
end

function post_source.GetRawSceneSourceTexture()
	return post_source.GetFoggedOpaqueSceneTexture()
end

function post_source.GetDebugTexture()
	if normal_debug.GetView() ~= 0 then
		return render3d.pipelines.normal_debug:GetFramebuffer():GetAttachment(1)
	end

	if
		ambient_occlusion.GetDebugView() ~= 0 and
		render3d.IsPassEnabled("ambient_occlusion_debug")
	then
		return render3d.pipelines.ambient_occlusion_debug:GetFramebuffer():GetAttachment(1)
	end
end

function post_source.GetSceneSourceTexture(self)
	if self.name == "blit_compute" or self.name == "blit_scene" then
		local debug_texture = post_source.GetDebugTexture()

		if debug_texture then return debug_texture end
	end

	if self.name == "taa" and render3d.IsAntiAliasingEnabled("edge_aa_t") then
		return render3d.pipelines.edge_aa:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)
	end

	if
		self.name ~= "taa" and
		(
			render3d.IsAntiAliasingEnabled("taa") or
			render3d.IsAntiAliasingEnabled("edge_aa_t")
		)
	then
		if render3d.pipelines.taa_sharpen.is_enabled() then
			return render3d.pipelines.taa_sharpen:GetFramebuffer():GetAttachment(1)
		end

		return render3d.pipelines.taa:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)
	end

	if render3d.IsAntiAliasingEnabled("edge_aa") then
		return render3d.pipelines.edge_aa:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)
	end

	if render3d.IsAntiAliasingEnabled("ssaa") then
		return render3d.pipelines.ssaa:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)
	end

	if render3d.IsAntiAliasingEnabled("fxaa") then
		return render3d.pipelines.fxaa:GetFramebuffer():GetAttachment(1)
	end

	return post_source.GetRawSceneSourceTexture()
end

function post_source.GetExposureTexture(previous)
	if not render3d.IsPassEnabled("blit") then return nil end

	local pipeline = render3d.pipelines.exposure_feedback

	if not pipeline.framebuffers then return nil end

	local current = system.GetFrameNumber() % 2 == 0 and 1 or 2
	return pipeline:GetFramebuffer():GetAttachment(previous and 3 - current or current)
end

post_source.PRE_EXPOSURE_HEADROOM = 32
post_source.UNEXPOSED_SDR_WHITE = 10000
post_source.pre_exposure_block = {
	{"pre_exposure_tex", "int"},
	{"prev_pre_exposure_tex", "int"},
}

function post_source.WritePreExposureBlock(self, block)
	local current = post_source.GetExposureTexture(true)
	local previous = post_source.GetExposureTexture(false)
	block.pre_exposure_tex = current and self:GetTextureIndex(current) or -1
	block.prev_pre_exposure_tex = previous and self:GetTextureIndex(previous) or -1
	return block
end

function post_source.GetPreExposureFromExposureGLSL()
	return [[
		float pre_exposure_from_exposure(float exposure) {
			return exposure > 0.0 ? exposure / ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
		}
	]]
end

function post_source.GetPreExposureGLSL(block_name)
	return post_source.GetPreExposureFromExposureGLSL() .. [[
		float read_pre_exposure(int texture_index) {
			return texture_index == -1 ? 1.0 : pre_exposure_from_exposure(texture(TEXTURE(texture_index), vec2(0.5)).r);
		}

		float get_pre_exposure() {
			return read_pre_exposure(]] .. block_name .. [[.pre_exposure_tex);
		}

		// what an absolute luminance is multiplied by to show on screen, where 1 is white
		float get_exposure() {
			return get_pre_exposure() * ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[;
		}

		float get_previous_pre_exposure() {
			return read_pre_exposure(]] .. block_name .. [[.prev_pre_exposure_tex);
		}
	]]
end

function post_source.GetCompressGLSL()
	return [[
		vec3 rgb_to_ycocg(vec3 c) {
			return vec3(
				0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
				0.5 * c.r - 0.5 * c.b,
				-0.25 * c.r + 0.5 * c.g - 0.25 * c.b
			);
		}

		vec3 ycocg_to_rgb(vec3 c) {
			return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
		}

		float get_luma(vec3 c) {
			return dot(c, vec3(0.2126, 0.7152, 0.0722));
		}

		// exposed and Reinhard compressed by luminance, so the inverse is exact. 1 - luma
		// keeps float precision to ~1e6 exposed, the sun's disc is ~5e4 at noon
		vec3 compress(vec3 c, float exposure) {
			c *= exposure;
			return rgb_to_ycocg(c / (1.0 + get_luma(c)));
		}

		vec3 decompress(vec3 c, float exposure) {
			vec3 rgb = max(ycocg_to_rgb(c), vec3(0.0));
			return rgb / max(1.0 - get_luma(rgb), 1e-6) / exposure;
		}
	]]
end

function post_source.WriteSceneSourceTexture(self, block, key)
	local texture = post_source.GetSceneSourceTexture(self)

	if not texture then
		block[key] = -1
		return
	end

	block[key] = self:GetTextureIndex(texture)
end

return post_source
