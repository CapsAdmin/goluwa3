local render = import("goluwa/render/render.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local draw = import("goluwa/render3d/scene/draw.lua")
local bridge = {}
local dynamic = setmetatable({}, {__mode = "k"})
local cpu_drawn = setmetatable({}, {__mode = "k"})
local tracked = setmetatable({}, {__mode = "k"})
local bounds_min, bounds_max = {[0] = 0, 0, 0}, {[0] = 0, 0, 0}
local bounds_valid = false
local bounds_dirty = false
local emissive_visuals = setmetatable({}, {__mode = "k"})
bridge.emitter_version = 0
local MAX_DIRTY_BOXES = 64
local dirty_queues = {}

function bridge.CreateDirtyQueue()
	local queue = {all = false, boxes = {}}
	dirty_queues[#dirty_queues + 1] = queue
	return queue
end

local function mark_dirty(aabb)
	local box = aabb and {aabb.min_x, aabb.min_y, aabb.min_z, aabb.max_x, aabb.max_y, aabb.max_z}

	for _, queue in ipairs(dirty_queues) do
		if not box then
			queue.all = true
		elseif not queue.all then
			if #queue.boxes >= MAX_DIRTY_BOXES then
				queue.all = true
				table.clear(queue.boxes)
			else
				queue.boxes[#queue.boxes + 1] = box
			end
		end
	end
end

local DIRTY_MOVE_TOLERANCE = 0.01

local function moved(a, b)
	return math.abs(a.min_x - b.min_x) > DIRTY_MOVE_TOLERANCE or
		math.abs(a.min_y - b.min_y) > DIRTY_MOVE_TOLERANCE or
		math.abs(a.min_z - b.min_z) > DIRTY_MOVE_TOLERANCE or
		math.abs(a.max_x - b.max_x) > DIRTY_MOVE_TOLERANCE or
		math.abs(a.max_y - b.max_y) > DIRTY_MOVE_TOLERANCE or
		math.abs(a.max_z - b.max_z) > DIRTY_MOVE_TOLERANCE
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

local function set_lod_bounds(visual, list)
	local box = visual.scene_aabb

	if not box then return end

	local x, y, z = (box.min_x + box.max_x) * 0.5,
	(box.min_y + box.max_y) * 0.5,
	(box.min_z + box.max_z) * 0.5
	local ex, ey, ez = box.max_x - box.min_x, box.max_y - box.min_y, box.max_z - box.min_z
	local radius = math.sqrt(ex * ex + ey * ey + ez * ez) * 0.5

	for i = 1, #list do
		instances.SetBounds(list[i].id, x, y, z, radius)
	end
end

function bridge.ConsumeDirty(queue)
	local all = queue.all
	local boxes = queue.boxes
	queue.all = false
	queue.boxes = {}
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
		draw.ClearRow(list[i].id)
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

do
	local box = {}
	local huge = math.huge

	function bridge.GetEntryBox(entry, matrix)
		local aabb = entry.source_aabb

		if not aabb or aabb.min_x > aabb.max_x then return nil end

		local min_x, min_y, min_z, max_x, max_y, max_z = huge, huge, huge, -huge, -huge, -huge

		for i = 0, 7 do
			local x, y, z = matrix:TransformVectorUnpacked(
				bit.band(i, 1) ~= 0 and aabb.max_x or aabb.min_x,
				bit.band(i, 2) ~= 0 and aabb.max_y or aabb.min_y,
				bit.band(i, 4) ~= 0 and aabb.max_z or aabb.min_z
			)

			if x < min_x then min_x = x end

			if x > max_x then max_x = x end

			if y < min_y then min_y = y end

			if y > max_y then max_y = y end

			if z < min_z then min_z = z end

			if z > max_z then max_z = z end
		end

		box.min_x, box.min_y, box.min_z, box.max_x, box.max_y, box.max_z = min_x, min_y, min_z, max_x, max_y, max_z
		return box
	end
end

local function set_raster(visual, item, entry, material, mesh, mesh_row, matrix)
	local flags = 0
	local module = import("goluwa/entities/components/visual.lua").Library
	local shown = not visual.RaysOnly and visual.Visible
	local in_view = shown and not visual.ViewHidden and not entry.primitive.ViewHidden
	local drawn = in_view and module.MaterialDrawsInGBuffer(material)
	local translucent = in_view and module.MaterialDrawsTranslucent(material)

	if shown and visual.CastShadows then flags = instances.RASTER_SHADOW end

	if translucent then
		flags = flags + instances.RASTER_TRANSLUCENT

		if material:GetDoubleSided() then
			flags = flags + instances.RASTER_DOUBLE_SIDED
		end

		if visual.UseOcclusionCulling then flags = flags + instances.RASTER_OCCLUSION end
	end

	if drawn then
		flags = flags + instances.RASTER_DRAW

		if material:GetDoubleSided() then
			flags = flags + instances.RASTER_DOUBLE_SIDED
		end

		if visual.UseOcclusionCulling then flags = flags + instances.RASTER_OCCLUSION end
	end

	if flags ~= 0 and material:HasHeightMap() then
		flags = flags + instances.RASTER_HEIGHT_MAP
	end

	local transform = entry.transform
	instances.SetRaster(
		item.id,
		bridge.GetEntryBox(entry, matrix) or visual:GetWorldAABB(),
		visual:GetCullDistance(),
		flags,
		transform and transform:GetPreviousWorldMatrix() or matrix,
		entry.source_aabb,
		translucent and
			material:GetRefraction() > 0 and
			material:GetRefractionThickness() or
			0
	)

	if flags ~= 0 then
		meshes.EnsureRaster(mesh_row)
		draw.SetRow(item.id, mesh, material, entry.polygon3d, translucent, mesh_row)
	else
		draw.ClearRow(item.id)
	end

	item.raster = (drawn or translucent) or nil
end

function bridge.UpdateVisual(visual, is_dynamic)
	if not visual:IsValid() or visual.scene_removed then
		cpu_drawn[visual] = nil
		release(visual)
		return
	end

	local list = visual.scene_instances or {}
	local count = 0
	local changed = false
	local emitter_changed = false
	local emissive = false
	local hidden = not visual.Visible
	local has_cpu_entry = false

	for _, entry in ipairs(visual:GetLODRenderEntries()) do
		local mesh = entry.polygon3d.mesh
		local mesh_row = mesh and
			mesh.Type ~= "null" and
			meshes.Get(mesh, entry.polygon3d.Dynamic == true)

		if mesh_row then
			count = count + 1
			local material = visual:GetResolvedMaterial(entry)
			local flags, mask = instances.GetMaterialFlags(material)
			local material_row = materials.GetID(material)
			local matrix = entry.transform:GetWorldMatrix()
			local item = list[count]
			local r, g, b = materials.GetEmissive(material)

			if r + g + b > 0 and (entry.lod_level or 0) == 0 then emissive = true end

			if hidden or not visual.InSceneBVH then mask = 0 end

			if not visual.CastShadows or material:GetRayShadowOpacity() < 0.5 then
				flags = flags + instances.FLAG_NO_SHADOW
			end

			if entry.lod_billboard then flags = flags + instances.FLAG_BILLBOARD end

			if entry.lod_before_billboard then
				flags = flags + instances.FLAG_BEFORE_BILLBOARD
			end

			if item and item.mesh_row == mesh_row then
				if item.matrix ~= matrix then
					instances.SetMatrix(item.id, matrix)
					item.matrix = matrix
					changed = true
				end

				local material_changed = instances.SetMaterial(item.id, material_row)
				local mask_changed = instances.SetMask(item.id, mask, flags)
				changed = material_changed or mask_changed or changed
				emitter_changed = material_changed or mask_changed or emitter_changed
			else
				changed = true
				emitter_changed = true

				if item then
					draw.ClearRow(item.id)
					instances.Remove(item.id)
				end

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

			if item.hidden ~= hidden then emitter_changed = true end

			item.entry = entry
			item.material = material
			item.hidden = hidden
			set_raster(visual, item, entry, material, mesh, mesh_row, matrix)
		else
			has_cpu_entry = true
		end
	end

	cpu_drawn[visual] = has_cpu_entry or nil

	for i = #list, count + 1, -1 do
		draw.ClearRow(list[i].id)
		instances.Remove(list[i].id)
		list[i] = nil
		changed = true
		emitter_changed = true
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
		if emitter_changed or (emissive_visuals[visual] or false) ~= emissive then
			bridge.emitter_version = bridge.emitter_version + 1
		end

		emissive_visuals[visual] = emissive or nil
	end
end

function bridge.IsRasterEntry(visual, entry)
	local list = visual.scene_instances

	if not list then return false end

	for i = 1, #list do
		if list[i].entry == entry then return list[i].raster == true end
	end

	return false
end

function bridge.RemoveVisual(visual)
	cpu_drawn[visual] = nil
	release(visual)
end

function bridge.GetCPUDrawnVisuals()
	return cpu_drawn
end

function bridge.RefreshDynamic()
	for visual in pairs(dynamic) do
		local list = visual.scene_instances
		local changed = false

		for i = 1, #list do
			local item = list[i]
			local matrix = item.entry.transform:GetWorldMatrix()
			instances.SetPrevMatrix(item.id, item.entry.transform:GetPreviousWorldMatrix() or matrix)

			if item.matrix ~= matrix then
				instances.SetMatrix(item.id, matrix)
				item.matrix = matrix
				changed = true
			end
		end

		if changed then
			local aabb = snapshot(visual)
			local previous = visual.scene_aabb

			if not (previous and aabb and not moved(previous, aabb)) then
				mark_dirty(previous)
				visual.scene_aabb = aabb
				mark_dirty(aabb)
				grow_bounds(aabb)
			end

			set_lod_bounds(visual, list)
			local visual_box = visual:GetWorldAABB()

			for i = 1, #list do
				local box = bridge.GetEntryBox(list[i].entry, list[i].matrix) or visual_box

				if box then instances.SetRasterBox(list[i].id, box) end
			end
		end
	end
end

return bridge
