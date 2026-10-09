local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local scene = import("goluwa/entities/scene.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local game = import("goluwa/source_engine/game.lua")
local world_pack = import("goluwa/source_engine/world_pack.lua")
local static_geometry = import("goluwa/source_engine/static_geometry.lua")
local collision = import("goluwa/source_engine/bsp_collision.lua")
local units = import("goluwa/source_engine/units.lua")
local file_path = import("goluwa/filesystem/path.lua")
local tasks = import("goluwa/tasks.lua")
local timer = import("goluwa/timer.lua")
local VisibilityGroup = RENDER_3D and import("goluwa/entities/components/visibility_group.lua")
local META = objects.CreateTemplate("static_world")
META:StartStorable()
META:GetSet("Pak", "")
META:GetSet("Texinfos", nil)
META:GetSet("Brushes", nil)
META:GetSet("Displacements", nil)
META:GetSet("SkyClip", nil)
META:EndStorable()

-- the big numeric tables are stored as packed float strings, plain nested tables would exceed what a chunk can hold
function META:GetBrushes()
	return self.Brushes and world_pack.PackBrushes(self.Brushes)
end

function META:SetBrushes(value)
	self.Brushes = value and (value.sides and world_pack.UnpackBrushes(value) or value)
end

function META:GetDisplacements()
	return self.Displacements and world_pack.PackDisplacements(self.Displacements)
end

function META:SetDisplacements(value)
	self.Displacements = value and (value.data and world_pack.UnpackDisplacements(value) or value)
end

META.waiting = {}
META.waiting_decals = {}

function META.GetActive()
	return META.active
end

function META.WaitForBuild(component)
	list.insert(META.waiting, component)
end

function META.WaitForDecals(component)
	list.insert(META.waiting_decals, component)
end

function META:Clear()
	local owner = self.Owner

	for _, child in ipairs(owner:GetChildren()) do
		if child.static_generated then child:Remove() end
	end

	for _, entity in pairs(self.brush_entities or {}) do
		if entity:IsValid() and not entity.brush.editing then entity:Remove() end
	end

	for _, entity in pairs(self.displacement_entities or {}) do
		if entity:IsValid() and not entity.displacement.editing then entity:Remove() end
	end

	if owner:HasComponent("rigid_body") then owner:RemoveComponent("rigid_body") end

	if RENDER_3D then VisibilityGroup.SetActive(nil) end

	self.groups = {}
	self.brush_entities = {}
	self.displacement_entities = {}
	self.brush_records = {}
	self.displacement_records = {}
	self.batch_primitives = {}
	self.collision_primitives = {}
	self.collision_model = nil
	self.decal_spans = {}
	self.visual_entities = {}
	self.sky_visual_entities = {}
	self.built = false

	if META.active == self then META.active = nil end
end

function META:OnDeserialized()
	if self.Pak ~= "" then game.MountMapPak(self.Pak) end

	self:Reload()
end

function META:Reload()
	self:Clear()
	self.load_id = (self.load_id or 0) + 1
	local load_id = self.load_id
	local world = self

	scene.WhenIdle(function()
		timer.Delay(0, function()
			if not world:IsValid() or world.load_id ~= load_id then return end

			local task = tasks.CreateTask()
			scene_loading.HoldTask(task)

			function task:OnStart()
				if world:IsValid() and world.load_id == load_id then world:Build() end
			end

			task:Start()
		end)
	end)
end

function META:GetContainer(id)
	if not id then return self.Owner end

	local group = self.groups[id]

	if group then return group end

	local name = "visibility_group_" .. id

	for _, child in ipairs(self.Owner:GetChildren()) do
		if child:GetName() == name then
			group = child

			break
		end
	end

	group = group or Entity.New{Name = name, Parent = self.Owner}

	if not group:HasComponent("transform") then group:AddComponent("transform") end

	if RENDER_3D and not group:HasComponent("visibility_group") then
		group:AddComponent("visibility_group")
	end

	self.groups[id] = group
	return group
end

function META:Build()
	local owner = self.Owner
	local world = {
		Texinfos = self.Texinfos or {},
		Brushes = self.Brushes or {},
		Displacements = self.Displacements or {},
	}
	local result = static_geometry.Build(world, owner:GetName())
	self.brush_records = result.brushes
	self.displacement_records = result.displacements
	self.batch_state = result.state

	for _, component in ipairs(META.waiting_decals) do
		if component.Owner:IsValid() then component:Attach(self) end
	end

	META.waiting_decals = {}
	static_geometry.Finalize(result)

	if RENDER_2D then
		for _, batch in ipairs(result.batches) do
			self:AttachBatch(batch)
		end

		for _, visual_entity in pairs(self.visual_entities) do
			visual_entity.visual:BuildAABB()
		end

		for _, visual_entity in pairs(self.sky_visual_entities) do
			visual_entity.visual:BuildAABB()
		end
	end

	local body, model, brush_primitives = static_geometry.BuildPhysics(result)

	if body then
		model.Owner = owner
		self.collision_model = model
		self.collision_primitives = brush_primitives
		owner:AddComponent("rigid_body", body)
	end

	self.built = true
	META.active = self
	local waiting = META.waiting
	META.waiting = {}

	for _, component in ipairs(waiting) do
		if component.Owner:IsValid() then component:Attach(self) end
	end

	logn(
		"static world built: ",
		#self.brush_records,
		" brushes, ",
		#self.displacement_records,
		" displacements, ",
		#result.batches,
		" batches"
	)
end

function META:OnRemove()
	if META.active == self then META.active = nil end

	if self.Pak ~= "" then game.UnmountMapPak(self.Pak) end

	if RENDER_3D then VisibilityGroup.SetActive(nil) end
end

function META:AttachBatch(batch)
	local container = self:GetContainer(batch.visibility_group)
	local visual_entities = batch.sky and self.sky_visual_entities or self.visual_entities
	local visual_entity = visual_entities[container]

	if not visual_entity then
		visual_entity = Entity.New{Name = batch.sky and "sky" or "world", Parent = container}
		visual_entity:SetTransient(true)
		visual_entity:AddComponent("transform")
		visual_entity:AddComponent("visual")
		visual_entity.static_generated = true
		visual_entities[container] = visual_entity

		if batch.sky then visual_entity.visual:SetClipBounds(self.SkyClip) end
	end

	self.batch_primitives[batch] = visual_entity.visual:CreatePrimitiveEntity(
		batch.mesh,
		batch.material,
		file_path.RemoveExtensionFromPath(file_path.GetFileNameFromPath(batch.material:GetName()))
	)
end

function META:HideSpans(spans, dirty)
	for _, span in ipairs(spans) do
		local vertices = span.entry.mesh.Vertices
		local anchor = vertices[span.first].pos

		for i = span.first, span.first + span.count - 1 do
			vertices[i].pos = anchor
		end

		dirty[span.entry] = true
	end
end

function META:RefreshBatch(batch)
	if batch.is_new then
		static_geometry.UploadBatch(batch)
		self:AttachBatch(batch)(batch.sky and self.sky_visual_entities or self.visual_entities)[self:GetContainer(batch.visibility_group)].visual:BuildAABB()
	else
		batch.mesh:Upload(nil)
		self.batch_primitives[batch].visual_primitive:SetPolygon3D(batch.mesh)
	end
end

-- Replaces the triangles of a decal. fragments is a list of {group, polygon of {pos, u, v}}.
function META:SetDecalFragments(owner, fragments)
	local dirty = {}
	local old_spans = self.decal_spans[owner]

	if old_spans then self:HideSpans(old_spans, dirty) end

	local spans = {}

	for _, fragment in ipairs(fragments) do
		local batch = static_geometry.GetBatch(self.batch_state, owner.Texname, fragment.group, "overlay")
		local first, count = static_geometry.AddPolygon(batch.mesh, fragment.polygon)
		list.insert(spans, {entry = batch, first = first, count = count})
		dirty[batch] = true
	end

	self.decal_spans[owner] = spans

	if self.built then
		for batch in pairs(dirty) do
			self:RefreshBatch(batch)
		end
	end
end

function META:HideRecord(record)
	if record.hidden then return end

	record.hidden = true
	local dirty = {}
	self:HideSpans(record.spans, dirty)

	for entry in pairs(dirty) do
		self:RefreshBatch(entry)
	end
end

function META:UpdateBrushCollision(index, planes)
	local primitive = self.collision_primitives[index]

	if not primitive or not collision.update_brush_primitive(primitive, planes) then
		return
	end

	self.collision_model.AABB:Expand(primitive.aabb)
	self.collision_model.raycast_primitive_acceleration = nil
	self.Owner.rigid_body:OnGeometryChanged()
end

function META:UpdateDisplacementCollision(index, points)
	local record = self.displacement_records[index]
	local shape = record.collision_shape

	if not shape then return end

	shape.Polygon3D = collision.build_displacement_polygon(points, record.dims).Polygon3D
	self.Owner.rigid_body:OnGeometryChanged()
end

function META:GetBrushEntity(index)
	local entity = self.brush_entities[index]

	if entity then return entity end

	local record = self.brush_records[index]
	entity = Entity.New{Name = "brush " .. index, Parent = self:GetContainer(record.group)}
	entity:AddComponent("transform")
	entity:SetTransient(false)
	entity:AddComponent("brush")
	entity.brush:Setup(self, record)
	return entity
end

function META:GetDisplacementEntity(index)
	local entity = self.displacement_entities[index]

	if entity then return entity end

	local record = self.displacement_records[index]
	entity = Entity.New{Name = "displacement " .. index, Parent = self:GetContainer(record.group)}
	entity:AddComponent("transform")
	entity:SetTransient(false)
	entity:AddComponent("displacement")
	entity.displacement:Setup(self, record)
	return entity
end

do
	local function ray_box(ox, oy, oz, dx, dy, dz, mins, maxs, t_max)
		local t_enter, t_exit = 0, t_max

		for axis = 1, 3 do
			local o_a, d_a, min_a, max_a

			if axis == 1 then
				o_a, d_a, min_a, max_a = ox, dx, mins.x, maxs.x
			elseif axis == 2 then
				o_a, d_a, min_a, max_a = oy, dy, mins.y, maxs.y
			else
				o_a, d_a, min_a, max_a = oz, dz, mins.z, maxs.z
			end

			if d_a > -1e-9 and d_a < 1e-9 then
				if o_a < min_a or o_a > max_a then return false end
			else
				local t1, t2 = (min_a - o_a) / d_a, (max_a - o_a) / d_a

				if t1 > t2 then t1, t2 = t2, t1 end

				if t1 > t_enter then t_enter = t1 end

				if t2 < t_exit then t_exit = t2 end
			end
		end

		return t_enter <= t_exit, t_enter
	end

	local function ray_triangle(ox, oy, oz, dx, dy, dz, p1, p2, p3)
		local e1x, e1y, e1z = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
		local e2x, e2y, e2z = p3.x - p1.x, p3.y - p1.y, p3.z - p1.z
		local hx, hy, hz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
		local a = e1x * hx + e1y * hy + e1z * hz

		if a > -1e-9 and a < 1e-9 then return nil end

		local f = 1 / a
		local sx, sy, sz = ox - p1.x, oy - p1.y, oz - p1.z
		local u = f * (sx * hx + sy * hy + sz * hz)

		if u < 0 or u > 1 then return nil end

		local qx, qy, qz = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
		local v = f * (dx * qx + dy * qy + dz * qz)

		if v < 0 or u + v > 1 then return nil end

		local t = f * (e2x * qx + e2y * qy + e2z * qz)

		if t > 1e-9 then return t end

		return nil
	end

	function META:PickBrush(origin, direction, max_distance)
		local o = units.PositionFromEngine(origin)
		local ox, oy, oz = o.x, o.y, o.z
		local dx, dy, dz = -direction.z, -direction.x, direction.y
		local best_index, best_t = nil, (max_distance or math.huge) / units.meters

		for index, record in ipairs(self.brush_records) do
			local hit, t_enter = ray_box(ox, oy, oz, dx, dy, dz, record.mins, record.maxs, best_t)

			if record.visible and hit then
				local t_exit = best_t

				for _, side in ipairs(record.sides) do
					local normal = side.normal
					local denom = dx * normal.x + dy * normal.y + dz * normal.z
					local signed = ox * normal.x + oy * normal.y + oz * normal.z - side.dist

					if denom > -1e-9 and denom < 1e-9 then
						if signed > 0 then
							t_exit = -1

							break
						end
					else
						local t = -signed / denom

						if denom < 0 then
							if t > t_enter then t_enter = t end
						elseif t < t_exit then
							t_exit = t
						end

						if t_enter > t_exit then break end
					end
				end

				if t_enter <= t_exit and t_enter < best_t then
					best_index, best_t = index, t_enter
				end
			end
		end

		if best_index then return best_index, best_t * units.meters end
	end

	function META:PickDisplacement(origin, direction, max_distance)
		local o = units.PositionFromEngine(origin)
		local ox, oy, oz = o.x, o.y, o.z
		local dx, dy, dz = -direction.z, -direction.x, direction.y
		local best_index, best_t = nil, (max_distance or math.huge) / units.meters

		for index, record in ipairs(self.displacement_records) do
			if
				not record.sky and
				ray_box(ox, oy, oz, dx, dy, dz, record.mins, record.maxs, best_t)
			then
				local positions, dims = record.positions, record.dims

				for x = 1, dims - 1 do
					for y = 1, dims - 1 do
						local a = y * dims + x
						local b = (y - 1) * dims + x
						local c = a + 1
						local d = b + 1
						local t1 = ray_triangle(ox, oy, oz, dx, dy, dz, positions[a], positions[c], positions[b])
						local t2 = ray_triangle(ox, oy, oz, dx, dy, dz, positions[c], positions[d], positions[b])

						if t1 and t1 < best_t then best_index, best_t = index, t1 end

						if t2 and t2 < best_t then best_index, best_t = index, t2 end
					end
				end
			end
		end

		if best_index then return best_index, best_t * units.meters end
	end
end

function META:PickGeometry(origin, direction)
	local brush_index, brush_distance = self:PickBrush(origin, direction)
	local displacement_index, displacement_distance = self:PickDisplacement(origin, direction)

	if
		displacement_index and
		(
			not brush_index or
			displacement_distance <= brush_distance + 0.05
		)
	then
		return self:GetDisplacementEntity(displacement_index), displacement_distance
	end

	if brush_index then return self:GetBrushEntity(brush_index), brush_distance end
end

return META:Register()
