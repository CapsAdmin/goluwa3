local render = import("goluwa/render/render.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local bridge = {}
local dynamic = {}

local function release(visual)
	local list = visual.scene_instances

	if not list then return end

	if not instances.IsAlive() then
		visual.scene_instances = nil

		return
	end

	for i = 1, #list do
		instances.Remove(list[i].id)
		list[i] = nil
	end

	visual.scene_instances = nil
	dynamic[visual] = nil
end

local function write_flags(material)
	local flags = 0
	local see_through = material:GetAlphaTest() or material:IsSeeThrough()

	if material:GetDoubleSided() then flags = flags + instances.FLAG_DOUBLE_SIDED end

	if material:GetAlphaTest() then flags = flags + instances.FLAG_ALPHA_TEST end

	if
		material:GetAlphaTest() or
		material:IsTransparent() or
		material:GetSoupShadowOpacity() < 1
	then
		flags = flags + instances.FLAG_NO_OPAQUE
	end

	return flags, see_through and instances.MASK_SEE_THROUGH or instances.MASK_SOLID
end

-- the instances of a visual: one per render entry that has a mesh the gpu has, in the scene as the entry's own world
-- matrix places it. called whenever the visual is dirty in the scene acceleration, in the frame it changed
function bridge.UpdateVisual(visual, is_dynamic)
	if not render.GetDevice().ray_tracing_supported then return end

	if not visual:IsValid() or visual.scene_removed or not visual.InSceneBVH then
		release(visual)

		return
	end

	local list = visual.scene_instances or {}
	local count = 0
	local hidden = not visual.Visible

	for _, entry in ipairs(visual:GetBVHRenderEntries()) do
		local mesh = entry.polygon3d.mesh
		local mesh_row = mesh and mesh.Type ~= "null" and meshes.Get(mesh)

		if mesh_row then
			count = count + 1
			local material = visual:GetResolvedMaterial(entry)
			local flags, mask = write_flags(material)
			local material_row = materials.GetID(material)
			local matrix = entry.transform:GetWorldMatrix()
			local item = list[count]

			if hidden then mask = 0 end

			if item and item.mesh_row == mesh_row then
				if item.matrix ~= matrix then
					instances.SetMatrix(item.id, matrix)
					item.matrix = matrix
				end

				instances.SetMaterial(item.id, material_row)
				instances.SetMask(item.id, mask, flags)
			else
				if item then instances.Remove(item.id) end

				item = item or {}
				item.id = instances.Add(mesh_row, material_row, matrix, mask, flags)
				item.mesh_row = mesh_row
				item.matrix = matrix
				item.entry = entry
				list[count] = item
			end

			item.entry = entry
			item.mesh = mesh
		end
	end

	for i = #list, count + 1, -1 do
		instances.Remove(list[i].id)
		list[i] = nil
	end

	if count == 0 then
		release(visual)

		return
	end

	visual.scene_instances = list
	dynamic[visual] = is_dynamic or nil
end

function bridge.RemoveVisual(visual)
	release(visual)
end

-- what moves with a body or a skeleton gets its matrices again every frame
function bridge.RefreshDynamic()
	for visual in pairs(dynamic) do
		local list = visual.scene_instances

		for i = 1, #list do
			local item = list[i]
			local matrix = item.entry.transform:GetWorldMatrix()

			if item.matrix ~= matrix then
				instances.SetMatrix(item.id, matrix)
				item.matrix = matrix
			end
		end
	end
end

return bridge
