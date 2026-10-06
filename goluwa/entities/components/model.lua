local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("model")
META.Network = {
	ModelPath = {"string", 0.5, "reliable"},
	ModelOptions = {"table", 0.5, "reliable"},
	MaterialConfig = {"table", 0.5, "reliable"},
}
META:GetSet("ModelPath", "", {callback = "Rebuild"})
META:GetSet("ModelOptions", nil, {callback = "Rebuild"})
META:GetSet("MaterialConfig", nil, {callback = "Rebuild"})
META:GetSet("Material", nil, {callback = "Rebuild"})

function META:Initialize()
	self.initialized = true
	self:Rebuild()
end

function META:Clear()
	local owner = self.Owner

	if self.children then
		for _, child in ipairs(self.children) do
			child:Remove()
		end

		self.children = nil
	end

	if owner.visual then owner:RemoveComponent("visual") end

	self.material = nil
end

function META:Rebuild()
	if not self.initialized then return end

	self:Clear()

	if not RENDER_3D or self.ModelPath == "" then return end

	local owner = self.Owner

	if self.ModelPath:ends_with(".lua") then
		self.material, self.children = import("goluwa/render3d/shapes.lua").BuildModelAsset(
			owner,
			self.ModelPath,
			self.Material or self.MaterialConfig,
			self.ModelOptions
		)
	else
		owner:AddComponent("visual"):SetModelPath(self.ModelPath)
	end
end

function META:OnRemove()
	self:Clear()
end

return META:Register()
