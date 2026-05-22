local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = {}

function post_source.WriteRawSceneSourceTexture(self, block, key)
	if
		render3d.use_smaa_resolve and
		render3d.pipelines.smaa_resolve and
		render3d.pipelines.smaa_resolve.framebuffers
	then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block[key] = self:GetTextureIndex(render3d.pipelines.smaa_resolve:GetFramebuffer(current_idx):GetAttachment(1))
		return
	end

	if
		render3d.pipelines.ocean_resolve and
		render3d.pipelines.ocean_resolve.framebuffers
	then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block[key] = self:GetTextureIndex(render3d.pipelines.ocean_resolve:GetFramebuffer(current_idx):GetAttachment(1))
		return
	end

	if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(1))
		return
	end

	if render3d.pipelines.clouds_composite then
		block[key] = self:GetTextureIndex(render3d.pipelines.clouds_composite:GetFramebuffer():GetAttachment(1))
		return
	end

	if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
		block[key] = -1
		return
	end

	local current_idx = system.GetFrameNumber() % 2 + 1
	block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
end

function post_source.WriteSceneSourceTexture(self, block, key)
	if self.name ~= "volumetric_fog" and render3d.pipelines.volumetric_fog then
		block[key] = self:GetTextureIndex(render3d.pipelines.volumetric_fog:GetFramebuffer():GetAttachment(1))
		return
	end

	if self.name ~= "scene_fog" and render3d.pipelines.scene_fog then
		block[key] = self:GetTextureIndex(render3d.pipelines.scene_fog:GetFramebuffer():GetAttachment(1))
		return
	end

	post_source.WriteRawSceneSourceTexture(self, block, key)
end

return post_source
