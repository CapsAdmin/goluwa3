local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = {}

function post_source.GetRawSceneSourceTexture(self)
	if render3d.IsOceanEnabled() then
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

-- the scene as the passes after self see it: taa resolves the fogged scene,
-- and everything after taa reads its output
function post_source.GetSceneSourceTexture(self)
	if self.name ~= "taa" and render3d.pipelines.taa then
		return render3d.pipelines.taa:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(1)
	end

	if self.name ~= "volumetric_fog" and render3d.pipelines.volumetric_fog then
		return render3d.pipelines.volumetric_fog:GetFramebuffer():GetAttachment(1)
	end

	return post_source.GetRawSceneSourceTexture(self)
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

function post_source.WriteRawSceneSourceTexture(self, block, key)
	local texture = post_source.GetRawSceneSourceTexture(self)

	if not texture then
		block[key] = -1
		return
	end

	block[key] = self:GetTextureIndex(texture)
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
