local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("model")
META.Network = {
	ModelPath = {"string", 0.5, "reliable"},
	ModelOptions = {"table", 0.5, "reliable"},
	MaterialConfig = {"table", 0.5, "reliable"},
}
META:StartStorable()
META:GetSet("ModelPath", "", {callback = "Rebuild", asset = "models"})
META:GetSet("ModelOptions", nil, {callback = "Rebuild"})
META:GetSet("MaterialConfig", nil, {callback = "OnMaterialChanged"})
META:EndStorable()
META:GetSet("Material", nil, {callback = "OnMaterialChanged"})

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

-- the meshes do not depend on the material, so the primitives that use the model's material just get the new one
function META:OnMaterialChanged()
	if not (self.initialized and self.children) then return end

	self.material = import("goluwa/render3d/shapes.lua").Material(self.Material or self.MaterialConfig)

	for _, child in ipairs(self.children) do
		if child.uses_model_material then
			child.visual_primitive:SetMaterial(self.material)
		end
	end
end

function META:OnRemove()
	self:Clear()
end

return META:Register()
