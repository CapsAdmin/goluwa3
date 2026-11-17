local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local draw = import("goluwa/render3d/scene/draw.lua")
local scene_parts = import("goluwa/render3d/scene/parts.lua")
local cluster_lod = import("goluwa/render3d/cluster_lod/cluster_lod.lua")
local lod = import("goluwa/render3d/lod.lua")
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
local GI_SETTLE_FRAMES = 30
local NOT_GI_BITS = bit.bnot(instances.MASK_GI_BITS)
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

local MAX_BEND_COPIES = 512

local function unpart(item)
	if item.part then
		scene_parts.Release(item.part)
		item.part = nil
	end
end

local function set_part(item, mesh_row, material, polygon)
	local part = scene_parts.Acquire(mesh_row, material, polygon, MAX_BEND_COPIES)

	if item.part == part then
		scene_parts.Release(part)
		return
	end

	unpart(item)
	item.part = part
	instances.SetPart(item.id, part.id)
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
		unpart(list[i])
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

local function is_character_gear(entity)
	while entity do
		if entity.character_movement or entity.weapon_holder then return true end

		entity = entity.Parent
	end

	return false
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

		if material:GetRasterBothFaces() then
			flags = flags + instances.RASTER_DOUBLE_SIDED
		end

		if visual.UseOcclusionCulling then flags = flags + instances.RASTER_OCCLUSION end
	end

	if drawn then
		flags = flags + instances.RASTER_DRAW

		if material:GetRasterBothFaces() then
			flags = flags + instances.RASTER_DOUBLE_SIDED
		end

		if visual.UseOcclusionCulling then flags = flags + instances.RASTER_OCCLUSION end
	end

	if flags ~= 0 and material:MarchesRelief() then
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
		draw.SetRow(item.id, mesh, material, entry.polygon3d, drawn, translucent, mesh_row)
	else
		draw.ClearRow(item.id)
	end

	item.raster = (drawn or translucent) or nil
end

local function item_mask(item, frame)
	item.gi_on = not item.gi_never and
		(
			item.gi_always or
			frame - item.moved_frame >= GI_SETTLE_FRAMES
		)
	return item.gi_on and item.gi_mask or bit.band(item.gi_mask, NOT_GI_BITS)
end

local function get_visual_radius(visual)
	local box = visual:GetWorldAABB()

	if not box then return 0 end

	local ex, ey, ez = box.max_x - box.min_x, box.max_y - box.min_y, box.max_z - box.min_z
	return math.sqrt(ex * ex + ey * ey + ez * ez) * 0.5
end

local function get_matrix_scale(m)
	return math.sqrt(
		math.max(
			m.m00 * m.m00 + m.m01 * m.m01 + m.m02 * m.m02,
			m.m10 * m.m10 + m.m11 * m.m11 + m.m12 * m.m12,
			m.m20 * m.m20 + m.m21 * m.m21 + m.m22 * m.m22
		)
	)
end

local function sync_entry(
	visual,
	list,
	index,
	entry,
	mesh_row,
	hidden,
	is_dynamic,
	frame,
	level,
	last,
	near,
	far,
	extra_flags,
	rt_only
)
	local material = visual:GetResolvedMaterial(entry)
	local flags, mask = instances.GetMaterialFlags(material)
	local material_row = materials.GetID(material)
	local matrix = entry.transform:GetWorldMatrix()
	local matrix_version = entry.transform:GetWorldMatrixVersion()
	local item = list[index]
	local changed, emitter_changed, emissive = false, false, false

	if not rt_only then
		local r, g, b = materials.GetEmissive(material)

		if r + g + b > 0 and (entry.lod_level or 0) == 0 then emissive = true end
	end

	local gear = false

	if hidden or not visual.InSceneBVH then
		mask = 0
	elseif is_character_gear(visual.Owner) then
		gear = true
		mask = bit.bor(mask, instances.MASK_SELF)
	end

	if not visual.CastShadows or material:GetRayShadowOpacity() < 0.5 then
		flags = flags + instances.FLAG_NO_SHADOW
	end

	if entry.lod_billboard then flags = flags + instances.FLAG_BILLBOARD end

	if entry.lod_before_billboard then
		flags = flags + instances.FLAG_BEFORE_BILLBOARD
	end

	flags = flags + extra_flags

	if item and item.mesh_row == mesh_row then
		if item.matrix_version ~= matrix_version then
			instances.SetMatrix(item.id, matrix)
			item.matrix = matrix
			item.matrix_version = matrix_version
			item.moved_frame = frame
			changed = true
		end

		item.gi_mask = mask
		item.gi_flags = flags
		item.gi_always = not is_dynamic or nil
		item.gi_never = gear or nil
		local material_changed = instances.SetMaterial(item.id, material_row)
		local mask_changed = instances.SetMask(item.id, item_mask(item, frame), flags)
		changed = material_changed or mask_changed or changed
		emitter_changed = material_changed or mask_changed or emitter_changed

		if
			item.lod_level ~= level or
			item.lod_last ~= last or
			item.lod_near ~= near or
			item.lod_far ~= far
		then
			instances.SetLOD(item.id, level, last, near, far)
			item.lod_level, item.lod_last, item.lod_near, item.lod_far = level, last, near, far
			changed = true
		end
	else
		changed = true
		emitter_changed = true

		if item then
			draw.ClearRow(item.id)
			unpart(item)
			instances.Remove(item.id)
		end

		item = item or {}
		item.moved_frame = frame
		item.gi_mask = mask
		item.gi_flags = flags
		item.gi_always = not is_dynamic or nil
		item.gi_never = gear or nil
		item.id = instances.Add(
			mesh_row,
			material_row,
			matrix,
			item_mask(item, frame),
			flags,
			level,
			last,
			near,
			far
		)
		item.level = level or 0
		item.lod_level, item.lod_last, item.lod_near, item.lod_far = level, last, near, far
		item.mesh_row = mesh_row
		item.matrix = matrix
		item.matrix_version = matrix_version
		item.entry = entry
		list[index] = item
	end

	if item.hidden ~= hidden then emitter_changed = true end

	item.entry = entry
	item.material = material
	item.hidden = hidden
	return item, material, changed, emitter_changed, emissive
end

local polygon_visuals = setmetatable({}, {__mode = "k"})

local function track_polygon(polygon3d, visual)
	local visuals = polygon_visuals[polygon3d]

	if not visuals then
		visuals = setmetatable({}, {__mode = "k"})
		polygon_visuals[polygon3d] = visuals
	end

	visuals[visual] = true
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
	local frame = system.GetFrameNumber()
	local radius

	for _, entry in ipairs(visual:GetLODRenderEntries()) do
		local polygon3d = entry.polygon3d
		local mesh = polygon3d.mesh
		local mesh_row = mesh and mesh.Type ~= "null" and meshes.Get(mesh, polygon3d.Dynamic == true)

		if mesh_row then
			local cuts, ratios
			local level, last, near, far = entry.lod_level, entry.lod_last, entry.lod_near, entry.lod_far
			local extra_flags = 0
			local state = cluster_lod.GetStatus(polygon3d)

			if state then
				track_polygon(polygon3d, visual)
				if
					state.ready and
					state.cuts[1] and
					(
						not entry.lod_last or
						entry.lod_last == 0
					)
					and
					cluster_lod.IsMaterialEligible(visual:GetResolvedMaterial(entry))
				then
					radius = radius or get_visual_radius(visual)

					if radius > 0 then
						cuts, ratios = state.cuts, {}
						local scale = get_matrix_scale(entry.transform:GetWorldMatrix())
						local previous = 0

						for i = 1, #cuts do
							previous = math.max(previous, cluster_lod.GetCutDistance(cuts[i], scale) / radius)
							ratios[i] = previous
						end

						level, last, near, far = 0, #cuts, 0, ratios[1]
						extra_flags = instances.FLAG_RT_LOD
					end
				end
			end

			count = count + 1
			local item, material, item_changed, item_emitter_changed, item_emissive = sync_entry(
				visual,
				list,
				count,
				entry,
				mesh_row,
				hidden,
				is_dynamic,
				frame,
				level,
				last,
				near,
				far,
				extra_flags,
				false
			)
			changed = item_changed or changed
			emitter_changed = item_emitter_changed or emitter_changed
			emissive = item_emissive or emissive
			set_part(item, mesh_row, material, polygon3d)
			set_raster(visual, item, entry, material, mesh, mesh_row, entry.transform:GetWorldMatrix())

			if not state and cluster_lod.GetStatus(polygon3d) then
				track_polygon(polygon3d, visual)
			end

			if cuts then
				for i = 1, #cuts do
					local cut = cuts[i]
					cut.row = cut.row or meshes.GetCut(mesh_row, cut.index_buffer, cut.triangles)
					count = count + 1
					local _, _, cut_changed, cut_emitter_changed = sync_entry(
						visual,
						list,
						count,
						entry,
						cut.row,
						hidden,
						is_dynamic,
						frame,
						i,
						#cuts,
						ratios[i],
						ratios[i + 1] or lod.NEVER,
						instances.FLAG_RT_LOD,
						true
					)
					changed = cut_changed or changed
					emitter_changed = cut_emitter_changed or emitter_changed
				end
			end
		else
			has_cpu_entry = true
		end
	end

	cpu_drawn[visual] = has_cpu_entry or nil

	for i = #list, count + 1, -1 do
		draw.ClearRow(list[i].id)
		unpart(list[i])
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

local function refresh_cluster_visuals(polygon3d)
	local visuals = polygon3d and polygon_visuals[polygon3d]

	if not visuals then return end

	for visual in pairs(visuals) do
		if visual:IsValid() and visual.scene_instances then
			bridge.UpdateVisual(visual, dynamic[visual])
		end
	end
end

cluster_lod.OnReady(refresh_cluster_visuals)

cluster_lod.OnRTErrorChanged(function()
	for _, visuals in pairs(polygon_visuals) do
		for visual in pairs(visuals) do
			if visual:IsValid() and visual.scene_instances then
				bridge.UpdateVisual(visual, dynamic[visual])
			end
		end
	end
end)

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
	local frame = system.GetFrameNumber()

	for visual in pairs(dynamic) do
		local list = visual.scene_instances
		local changed = false

		for i = 1, #list do
			local item = list[i]
			local transform = item.entry.transform

			if
				item.settled and
				not transform.WorldMatrixDirty and
				item.matrix_version == transform.WorldMatrixVersion
			then
				if item.settled_epoch == RigidBody.ActivityEpoch then
					goto continue_item
				elseif transform:IsRenderSettled() then
					item.settled_epoch = RigidBody.ActivityEpoch

					goto continue_item
				end
			end

			local matrix = transform:GetWorldMatrix()
			local matrix_version = transform:GetWorldMatrixVersion()
			-- called every frame even when the row is not written: it rolls the transform's render history
			local previous = transform:GetPreviousWorldMatrix() or matrix
			local previous_version = item.seen_version or matrix_version

			if item.prev_version ~= previous_version then
				instances.SetPrevMatrix(item.id, previous)
				item.prev_version = previous_version
			end

			item.seen_version = matrix_version
			local moved_now = item.matrix_version ~= matrix_version

			if moved_now then
				instances.SetMatrix(item.id, matrix)
				item.matrix = matrix
				item.matrix_version = matrix_version
				item.moved_frame = frame
				changed = true
			end

			if
				not item.gi_never and
				item.gi_on ~= (
					frame - item.moved_frame >= GI_SETTLE_FRAMES
				)
			then
				instances.SetMask(item.id, item_mask(item, frame), item.gi_flags)
			end

			item.settled = not moved_now and
				item.prev_version == item.seen_version and
				(
					item.gi_never or
					item.gi_on == (
						frame - item.moved_frame >= GI_SETTLE_FRAMES
					)
				)

			::continue_item::
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

function bridge.RefreshBounds(visual)
	local list = visual.scene_instances

	if not list then return end

	local visual_box = visual:GetWorldAABB()

	for i = 1, #list do
		local box = bridge.GetEntryBox(list[i].entry, list[i].matrix) or visual_box

		if box then instances.SetRasterBox(list[i].id, box) end
	end
end

return bridge
