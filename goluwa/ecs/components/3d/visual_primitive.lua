local prototype = import("goluwa/prototype.lua")
local VisualPrimitive = prototype.CreateTemplate("visual_primitive")

local function find_visual_component(entity)
	local current = entity

	while current and current.IsValid and current:IsValid() do
		if current.visual then return current.visual end
		current = current:GetParent()
	end

	return nil
end

VisualPrimitive:StartStorable()
VisualPrimitive:GetSet("Polygon3D", nil, {callback = "InvalidateVisual"})
VisualPrimitive:GetSet("Material", nil, {callback = "InvalidateVisual", type = "render3d_material"})
VisualPrimitive:EndStorable()
VisualPrimitive:GetSet("LocalAABB", nil, {callback = "InvalidateVisual"})

function VisualPrimitive:InvalidateVisual()
	local visual = self.Owner and find_visual_component(self.Owner) or nil

	if visual then visual:InvalidateHierarchyState() end
end

function VisualPrimitive:SetPolygon3D(polygon3d)
	if not (polygon3d.mesh and polygon3d.mesh.vertex_buffer) then
		error(
			"SetPolygon3D requires a Polygon3D object with .mesh.vertex_buffer, got: " .. tostring(polygon3d)
		)
	end

	self.Polygon3D = polygon3d
	self.LocalAABB = polygon3d.AABB
	self:InvalidateVisual()
end

function VisualPrimitive:GetLocalAABB()
	return self.LocalAABB or self.Polygon3D and self.Polygon3D.AABB or nil
end

function VisualPrimitive:OnAdd()
	self:InvalidateVisual()
end

function VisualPrimitive:OnRemove()
	self:InvalidateVisual()
end

function VisualPrimitive:OnParent()
	self:InvalidateVisual()
end

function VisualPrimitive:OnUnParent()
	self:InvalidateVisual()
end

return VisualPrimitive:Register()