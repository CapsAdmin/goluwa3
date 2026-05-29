local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = {}

function post_source.GetRawSceneSourceTexture(self)
	if
		render3d.use_smaa_resolve and
		render3d.pipelines.smaa_resolve and
		render3d.pipelines.smaa_resolve.framebuffers
	then
		local current_idx = system.GetFrameNumber() % 2 + 1
		return render3d.pipelines.smaa_resolve:GetFramebuffer(current_idx):GetAttachment(1)
	end

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

	if render3d.pipelines.atmosphere and render3d.pipelines.atmosphere.framebuffers then
		local current_idx = system.GetFrameNumber() % 2 + 1
		return render3d.pipelines.atmosphere:GetFramebuffer(current_idx):GetAttachment(1)
	end

	if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
		return nil
	end

	local current_idx = system.GetFrameNumber() % 2 + 1
	return render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1)
end

function post_source.GetSceneSourceTexture(self)
	if self.name == "scene_fog" then
		return post_source.GetRawSceneSourceTexture(self)
	end

	if
		self.name ~= "volumetric_fog" and
		self.name ~= "scene_fog" and
		render3d.pipelines.volumetric_fog
	then
		return render3d.pipelines.volumetric_fog:GetFramebuffer():GetAttachment(1)
	end

	if self.name ~= "scene_fog" and render3d.pipelines.scene_fog then
		return render3d.pipelines.scene_fog:GetFramebuffer():GetAttachment(1)
	end

	return post_source.GetRawSceneSourceTexture(self)
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
