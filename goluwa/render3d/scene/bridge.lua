local render = import("goluwa/render/render.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local bridge = {}
local dynamic = setmetatable({}, {__mode = "k"})
-- every visual in the scene, for the bounds of all of it
local tracked = setmetatable({}, {__mode = "k"})
local bounds_min, bounds_max = {[0] = 0, 0, 0}, {[0] = 0, 0, 0}
local bounds_valid = false
local bounds_dirty = false
-- visuals that have an emissive instance, and a version that changes whenever the emitters could have
local emissive_visuals = setmetatable({}, {__mode = "k"})
bridge.emitter_version = 0
local MAX_DIRTY_BOXES = 64
-- where the scene changed since the last time it was asked, for what caches per region (the light occlusion maps)
local dirty_boxes = {}
local dirty_all = false

local function mark_dirty(aabb)
	if not aabb then
		dirty_all = true

		return
	end

	if dirty_all then return end

	if #dirty_boxes >= MAX_DIRTY_BOXES then
		dirty_all = true
		table.clear(dirty_boxes)

		return
	end

	dirty_boxes[#dirty_boxes + 1] = {aabb.min_x, aabb.min_y, aabb.min_z, aabb.max_x, aabb.max_y, aabb.max_z}
end

local function snapshot(visual)
	local aabb = visual:GetWorldAABB()

	if not aabb then return nil end

	return {
		min_x = aabb.min_x,
		min_y = aabb.min_y,
		min_z = aabb.min_z,
		max_x = aabb.max_x,
		max_y = aabb.max_y,
		max_z = aabb.max_z,
	}
end

-- the box around everything in the scene, nil for an empty one. it only grows until something leaves the scene, then it
-- is measured again
function bridge.GetBounds()
	if bounds_dirty then
		bounds_dirty = false
		bounds_valid = false

		for visual in pairs(tracked) do
			local box = visual.scene_aabb

			if box then
				if not bounds_valid then
					bounds_min[0], bounds_min[1], bounds_min[2] = box.min_x, box.min_y, box.min_z
					bounds_max[0], bounds_max[1], bounds_max[2] = box.max_x, box.max_y, box.max_z
					bounds_valid = true
				else
					bounds_min[0] = math.min(bounds_min[0], box.min_x)
					bounds_min[1] = math.min(bounds_min[1], box.min_y)
					bounds_min[2] = math.min(bounds_min[2], box.min_z)
					bounds_max[0] = math.max(bounds_max[0], box.max_x)
					bounds_max[1] = math.max(bounds_max[1], box.max_y)
					bounds_max[2] = math.max(bounds_max[2], box.max_z)
				end
			end
		end
	end

	if not bounds_valid then return nil end

	return bounds_min, bounds_max
end

local function grow_bounds(box)
	if not box then return end

	if not bounds_valid then
		bounds_min[0], bounds_min[1], bounds_min[2] = box.min_x, box.min_y, box.min_z
		bounds_max[0], bounds_max[1], bounds_max[2] = box.max_x, box.max_y, box.max_z
		bounds_valid = true

		return
	end

	bounds_min[0] = math.min(bounds_min[0], box.min_x)
	bounds_min[1] = math.min(bounds_min[1], box.min_y)
	bounds_min[2] = math.min(bounds_min[2], box.min_z)
	bounds_max[0] = math.max(bounds_max[0], box.max_x)
	bounds_max[1] = math.max(bounds_max[1], box.max_y)
	bounds_max[2] = math.max(bounds_max[2], box.max_z)
end

-- the levels of detail of a visual are picked by the distance to the sphere around it
local function set_lod_bounds(visual, list)
	local box = visual.scene_aabb

	if not box then return end

	local x, y, z = (box.min_x + box.max_x) * 0.5, (box.min_y + box.max_y) * 0.5, (box.min_z + box.max_z) * 0.5
	local ex, ey, ez = box.max_x - box.min_x, box.max_y - box.min_y, box.max_z - box.min_z
	local radius = math.sqrt(ex * ex + ey * ey + ez * ez) * 0.5

	for i = 1, #list do
		instances.SetBounds(list[i].id, x, y, z, radius)
	end
end

function bridge.ConsumeDirty()
	local all = dirty_all
	local boxes = dirty_boxes
	dirty_all = false
	dirty_boxes = {}
	return all, boxes
end

local function release(visual)
	local list = visual.scene_instances

	if not list then return end

	if not instances.IsAlive() then
		visual.scene_instances = nil
		dynamic[visual] = nil
		tracked[visual] = nil
		emissive_visuals[visual] = nil

		return
	end

	for i = 1, #list do
		instances.Remove(list[i].id)
		list[i] = nil
	end

	mark_dirty(visual.scene_aabb)
	visual.scene_instances = nil
	visual.scene_aabb = nil
	dynamic[visual] = nil
	tracked[visual] = nil
	bounds_dirty = true

	if emissive_visuals[visual] then
		emissive_visuals[visual] = nil
		bridge.emitter_version = bridge.emitter_version + 1
	end
end

function bridge.GetEmissiveVisuals()
	return emissive_visuals
end

local function write_flags(material)
	local flags = 0
	local see_through = material:GetAlphaTest() or material:IsSeeThrough()

	if material:GetDoubleSided() then flags = flags + instances.FLAG_DOUBLE_SIDED end

	if material:GetAlphaTest() then flags = flags + instances.FLAG_ALPHA_TEST end

	if
		material:GetAlphaTest() or
		material:IsTransparent() or
		material:GetRayShadowOpacity() < 1
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
	local changed = false
	local emissive = false
	local hidden = not visual.Visible

	for _, entry in ipairs(visual:GetLODRenderEntries()) do
		local mesh = entry.polygon3d.mesh
		local mesh_row = mesh and mesh.Type ~= "null" and meshes.Get(mesh, entry.polygon3d.Dynamic == true)

		if mesh_row then
			count = count + 1
			local material = visual:GetResolvedMaterial(entry)
			local flags, mask = write_flags(material)
			local material_row = materials.GetID(material)
			local matrix = entry.transform:GetWorldMatrix()
			local item = list[count]
			local r, g, b = materials.GetEmissive(material)

			if r + g + b > 0 and (entry.lod_level or 0) == 0 then emissive = true end

			if hidden then mask = 0 end

			if item and item.mesh_row == mesh_row then
				if item.matrix ~= matrix then
					instances.SetMatrix(item.id, matrix)
					item.matrix = matrix
					changed = true
				end

				changed = instances.SetMaterial(item.id, material_row) or changed
				changed = instances.SetMask(item.id, mask, flags) or changed
			else
				changed = true

				if item then instances.Remove(item.id) end

				item = item or {}
				item.id = instances.Add(
					mesh_row,
					material_row,
					matrix,
					mask,
					flags,
					entry.lod_level,
					entry.lod_last,
					entry.lod_near,
					entry.lod_far
				)
				item.level = entry.lod_level or 0
				item.mesh_row = mesh_row
				item.matrix = matrix
				item.entry = entry
				list[count] = item
			end

			item.entry = entry
			item.material = material
		end
	end

	for i = #list, count + 1, -1 do
		instances.Remove(list[i].id)
		list[i] = nil
		changed = true
	end

	if count == 0 then
		release(visual)

		return
	end

	visual.scene_instances = list
	dynamic[visual] = is_dynamic or nil

	if changed then
		mark_dirty(visual.scene_aabb)
		visual.scene_aabb = snapshot(visual)
		mark_dirty(visual.scene_aabb)
		tracked[visual] = true
		grow_bounds(visual.scene_aabb)
		set_lod_bounds(visual, list)
	end

	if emissive or emissive_visuals[visual] then
		if changed or (emissive_visuals[visual] or false) ~= emissive then
			bridge.emitter_version = bridge.emitter_version + 1
		end

		emissive_visuals[visual] = emissive or nil
	end
end

function bridge.RemoveVisual(visual)
	release(visual)
end

-- what moves with a body or a skeleton gets its matrices again every frame
function bridge.RefreshDynamic()
	for visual in pairs(dynamic) do
		local list = visual.scene_instances
		local changed = false

		for i = 1, #list do
			local item = list[i]
			local matrix = item.entry.transform:GetWorldMatrix()

			if item.matrix ~= matrix then
				instances.SetMatrix(item.id, matrix)
				item.matrix = matrix
				changed = true
			end
		end

		if changed then
			mark_dirty(visual.scene_aabb)
			visual.scene_aabb = snapshot(visual)
			mark_dirty(visual.scene_aabb)
			grow_bounds(visual.scene_aabb)
			set_lod_bounds(visual, list)

			if emissive_visuals[visual] then bridge.emitter_version = bridge.emitter_version + 1 end
		end
	end
end

return bridge
