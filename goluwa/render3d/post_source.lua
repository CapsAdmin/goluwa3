local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = {}

-- the lit opaque scene, before anything translucent is drawn over it
function post_source.GetOpaqueSceneTexture()
	if render3d.IsWaterEnabled() then
		if
			render3d.pipelines.ocean_resolve and
			render3d.pipelines.ocean_resolve.framebuffers
		then
			local current_idx = system.GetFrameNumber() % 2 + 1
			return render3d.pipelines.ocean_resolve:GetFramebuffer(current_idx):GetAttachment(1)
		end

		if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
			local current_idx = system.GetFrameNumber() % 2 + 1
			return render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(1)
		end
	end

	if not render3d.pipelines.lighting then return nil end

	return render3d.pipelines.lighting:GetFramebuffer(1):GetAttachment(1)
end

-- the opaque scene with the fog in front of it, which the translucent
-- surfaces are laid over
function post_source.GetFoggedOpaqueSceneTexture()
	if render3d.pipelines.volumetric_fog then
		return render3d.pipelines.volumetric_fog:GetFramebuffer():GetAttachment(1)
	end

	return post_source.GetOpaqueSceneTexture()
end

-- the whole scene, before taa. the translucent pass composites over the
-- fogged opaque scene in place
function post_source.GetRawSceneSourceTexture()
	return post_source.GetFoggedOpaqueSceneTexture()
end

-- the scene as the passes after self see it: taa resolves the raw scene,
-- and everything after taa reads its output
function post_source.GetSceneSourceTexture(self)
	if self.name ~= "taa" and render3d.pipelines.taa then
		return render3d.pipelines.taa:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)
	end

	return post_source.GetRawSceneSourceTexture()
end

-- The auto exposure multiplier (r) from passes/blit.lua. Its pass alternates
-- between two attachments each frame; before it has run this frame, previous
-- gives last frame's.
function post_source.GetExposureTexture(previous)
	local pipeline = render3d.pipelines.exposure_feedback

	if not pipeline or not pipeline.framebuffers then return nil end

	local current = system.GetFrameNumber() % 2 == 0 and 1 or 2
	return pipeline:GetFramebuffer():GetAttachment(previous and 3 - current or current)
end

-- Scene color is stored pre-exposed: absolute luminance (cd/m2) times last frame's
-- exposure over PRE_EXPOSURE_HEADROOM. The metered average then sits near
-- KEY / PRE_EXPOSURE_HEADROOM whether it is noon or night, so fp16 holds both a
-- starlit shadow and the sun's disc (~1e9 cd/m2) with room for the exposure to lag.
-- Lighting stays absolute; passes multiply by get_pre_exposure() when they write
-- the scene and divide by it when they read it back for anything physical.
-- Passes without the exposure pipeline (probe captures) use 1, staying absolute.
post_source.PRE_EXPOSURE_HEADROOM = 32
post_source.pre_exposure_block = {
	{"pre_exposure_tex", "int"},
	{"prev_pre_exposure_tex", "int"},
}

function post_source.WritePreExposureBlock(self, block)
	-- before this frame's exposure pass, the attachment it writes still holds the one before last
	local current = post_source.GetExposureTexture(true)
	local previous = post_source.GetExposureTexture(false)
	block.pre_exposure_tex = current and self:GetTextureIndex(current) or -1
	block.prev_pre_exposure_tex = previous and self:GetTextureIndex(previous) or -1
	return block
end

-- pre_exposure_from_exposure(e) for passes that sample an exposure texture themselves
function post_source.GetPreExposureFromExposureGLSL()
	return [[
		float pre_exposure_from_exposure(float exposure) {
			return exposure > 0.0 ? exposure / ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[ : 1.0;
		}
	]]
end

-- get_pre_exposure(): what this frame's scene color is multiplied by
-- get_previous_pre_exposure(): what last frame's was, to bring history into this frame's
function post_source.GetPreExposureGLSL(block_name)
	return post_source.GetPreExposureFromExposureGLSL() .. [[
		float read_pre_exposure(int texture_index) {
			return texture_index == -1 ? 1.0 : pre_exposure_from_exposure(texture(TEXTURE(texture_index), vec2(0.5)).r);
		}

		float get_pre_exposure() {
			return read_pre_exposure(]] .. block_name .. [[.pre_exposure_tex);
		}

		float get_previous_pre_exposure() {
			return read_pre_exposure(]] .. block_name .. [[.prev_pre_exposure_tex);
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
