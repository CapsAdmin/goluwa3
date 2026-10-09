local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local scene = import("goluwa/entities/scene.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local game = import("goluwa/source_engine/game.lua")
local static_geometry = import("goluwa/source_engine/static_geometry.lua")
local collision = import("goluwa/source_engine/bsp_collision.lua")
local units = import("goluwa/source_engine/units.lua")
local AABB = import("goluwa/structs/aabb.lua")
local file_path = import("goluwa/filesystem/path.lua")
local system = import("goluwa/system.lua")
local tasks = import("goluwa/tasks.lua")
local timer = import("goluwa/timer.lua")
local VisibilityGroup = RENDER_3D and import("goluwa/entities/components/visibility_group.lua")
local META = objects.CreateTemplate("static_world")
META:StartStorable()
META:GetSet("Pak", "", {ReadOnly = true})
META:GetSet("Colliders", true, {callback = "RefreshColliders"})
META:EndStorable()
-- A static world gathers the brush and displacement components below it, batches their triangles per material and
-- visibility group and, with Colliders on, builds one static rigid body from them. Sources register themselves
-- and tell the world when they changed, the world applies changes at most every FLUSH_INTERVAL seconds.
local FLUSH_INTERVAL = 0.1
local COLLISION_SETTLE_TIME = 0.3
local EDIT_SETTLE_TIME = 0.5
local EDIT_BOUNDS_PADDING = 2

function META.GetActive()
	return META.active
end

-- the nearest static world above an entity
function META.Find(entity)
	local parent = entity:GetParent()

	while parent and parent:IsValid() do
		local world = parent.static_world

		if world then return world end

		parent = parent:GetParent()
	end
end

function META:Initialize()
	self.sources = {}
	self.source_list = {}
	self.waiting_decals = {}
	self:ResetRuntime()
end

-- everything that is rebuilt by Build, the registered sources stay
function META:ResetRuntime()
	self.dirty = {}
	self.removed = {}
	self.collision_dirty = {}
	self.edits = {}
	self.edit_dirty = {}
	self.brush_list = {}
	self.displacement_list = {}
	self.mesh_list = {}
	self.records = {}
	self.batch_primitives = {}
	self.collision_primitives = {}
	self.collision_model = nil
	self.decal_spans = {}
	self.visual_entities = {}
	self.visual_list = {}
	self.last_flush = 0
	self.built = false
end

function META:Clear()
	for _, child in ipairs(self.Owner:GetChildrenList()) do
		if child:IsValid() and child.static_generated then child:Remove() end
	end

	if self.Owner:HasComponent("rigid_body") then
		self.Owner:RemoveComponent("rigid_body")
	end

	if RENDER_3D then VisibilityGroup.SetActive(nil) end

	self:ResetRuntime()

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

-- the visibility group entity a source belongs to, nil when it is not inside of one
function META:GetGroup(entity)
	local parent = entity:GetParent()

	while parent and parent:IsValid() and parent ~= self.Owner do
		if parent.visibility_group then return parent end

		parent = parent:GetParent()
	end
end

function META:CreateRecord(component)
	local record = component:CreateRecord()
	record.component = component
	record.group = self:GetGroup(component.Owner)
	component:UpdateRecord(record)
	self.records[component] = record
	list.insert(self:GetList(record.kind), record)
	return record
end

function META:GetList(kind)
	if kind == "brush" then return self.brush_list end

	if kind == "displacement" then return self.displacement_list end

	return self.mesh_list
end

function META:AddSource(component)
	if self.sources[component] then return end

	self.sources[component] = true
	list.insert(self.source_list, component)

	if self.built then self.dirty[component] = true end
end

function META:RemoveSource(component)
	if not self.sources[component] then return end

	self.sources[component] = nil
	self.dirty[component] = nil
	self.collision_dirty[component] = nil
	local record = self.records[component]

	if record then
		self:CancelEdit(component, record)
		self.records[component] = nil
		list.insert(self.removed, record)
	end
end

-- Appends the triangles of a record to the batches of state.
function META:EmitRecord(state, record)
	if record.kind == "brush" then
		static_geometry.EmitBrush(state, record)
	elseif record.kind == "displacement" then
		static_geometry.EmitDisplacement(state, record, static_geometry.ComputeDisplacementNormals(record))
	else
		static_geometry.EmitMesh(state, record)
	end
end

-- A source changed. Sources that are already in the batches are edited: their triangles leave the shared batches
-- and are drawn from a small mesh of their own that is rebuilt every frame, once nothing changed for a while
-- they go back into the shared batches. Sources without a record yet are emitted on the next flush.
function META:MarkDirty(component)
	if not self.built then return end

	local record = self.records[component]

	if not record then
		self.dirty[component] = true
		return
	end

	self.collision_dirty[component] = system.GetElapsedTime()

	if not RENDER_2D then
		component:UpdateRecord(record)
		self:EmitRecord(self.batch_state, record)
		return
	end

	if not self.edits[component] then self:BeginEdit(component, record) end

	self.edit_dirty[component] = true
end

function META:BeginEdit(component, record)
	local touched = {}
	self:ReleaseSpans(record.spans, touched)
	record.spans = {}
	self:RefreshBatches(touched)
	local entity = Entity.New{Name = "edit", Parent = record.group or self.Owner}
	entity:SetTransient(true)
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	entity.static_generated = true
	self.edits[component] = {
		state = static_geometry.NewState("edit"),
		primitives = {},
		bounds = {},
		entity = entity,
		time = system.GetElapsedTime(),
	}
end

function META:CancelEdit(component, record)
	local edit = self.edits[component]

	if not edit then return end

	if edit.entity:IsValid() then edit.entity:Remove() end

	self.edits[component] = nil
	self.edit_dirty[component] = nil
	record.spans = {}
end

function META:UpdateEdit(component, edit)
	local record = self.records[component]
	component:UpdateRecord(record)

	for _, batch in ipairs(edit.state.batches) do
		batch.mesh:Clear()
	end

	self:EmitRecord(edit.state, record)
	local visual = edit.entity.visual

	for _, batch in ipairs(edit.state.batches) do
		local primitive = edit.primitives[batch]
		local mesh = batch.mesh

		if #mesh.Vertices > 0 then
			mesh:BuildTangents()

			if primitive and mesh:UpdateVertices() then
				local aabb, bounds = mesh.AABB, edit.bounds[batch]

				if
					aabb.min_x < bounds.min_x or
					aabb.min_y < bounds.min_y or
					aabb.min_z < bounds.min_z or
					aabb.max_x > bounds.max_x or
					aabb.max_y > bounds.max_y or
					aabb.max_z > bounds.max_z
				then
					edit.bounds[batch] = self:PadEditBounds(primitive, aabb)
					visual:BuildAABB()
				end
			else
				mesh:BuildBoundingBox()
				mesh:Upload(nil)

				if primitive then
					primitive.visual_primitive:SetPolygon3D(mesh)
				else
					primitive = visual:CreatePrimitiveEntity(
						mesh,
						batch.material,
						file_path.RemoveExtensionFromPath(file_path.GetFileNameFromPath(batch.material:GetName()))
					)
					edit.primitives[batch] = primitive
				end

				edit.bounds[batch] = self:PadEditBounds(primitive, mesh.AABB)
				visual:BuildAABB()
			end
		elseif primitive then
			primitive:Remove()
			edit.primitives[batch] = nil
			edit.bounds[batch] = nil
		end
	end
end

-- The culling bounds of an edit mesh are padded so moving it does not change them every frame.
function META:PadEditBounds(primitive, aabb)
	local bounds = AABB(
		aabb.min_x - EDIT_BOUNDS_PADDING,
		aabb.min_y - EDIT_BOUNDS_PADDING,
		aabb.min_z - EDIT_BOUNDS_PADDING,
		aabb.max_x + EDIT_BOUNDS_PADDING,
		aabb.max_y + EDIT_BOUNDS_PADDING,
		aabb.max_z + EDIT_BOUNDS_PADDING
	)
	primitive.visual_primitive:SetLocalAABB(bounds)
	return bounds
end

function META:EndEdit(component, edit)
	edit.entity:Remove()
	self.edits[component] = nil
	local record = self.records[component]
	component:UpdateRecord(record)
	self:EmitRecord(self.batch_state, record)
	local touched = {}

	for _, span in ipairs(record.spans) do
		span.entry.mesh:BuildTangents(span.first, span.first + span.count - 1)
		touched[span.entry] = true
	end

	self:RefreshBatches(touched)
end

function META:AddDecal(decal)
	if self.built then
		decal:Attach(self)
	else
		list.insert(self.waiting_decals, decal)
	end
end

function META:Build()
	local owner = self.Owner
	self:ResetRuntime()
	local source_list, seen = {}, {}

	for _, component in ipairs(self.source_list) do
		if self.sources[component] and not seen[component] then
			seen[component] = true
			list.insert(source_list, component)
			self:CreateRecord(component)
		end
	end

	self.source_list = source_list
	local result = static_geometry.Build(self.brush_list, self.displacement_list, self.mesh_list, owner:GetName())
	self.batch_state = result.state

	for _, decal in ipairs(self.waiting_decals) do
		if decal.Owner:IsValid() then decal:Attach(self) end
	end

	self.waiting_decals = {}
	static_geometry.Finalize(result)

	if RENDER_2D then
		for _, batch in ipairs(result.batches) do
			self:AttachBatch(batch)
		end

		for _, visual_entity in ipairs(self.visual_list) do
			visual_entity.visual:BuildAABB()
		end
	end

	if self.Colliders then self:BuildColliders() end

	self.built = true
	META.active = self
	self:AddGlobalEvent("Update")
	logn(
		"static world built: ",
		#self.brush_list,
		" brushes, ",
		#self.displacement_list,
		" displacements, ",
		#self.mesh_list,
		" meshes, ",
		#result.batches,
		" batches"
	)
end

function META:OnRemove()
	if META.active == self then META.active = nil end

	if self.Pak ~= "" then game.UnmountMapPak(self.Pak) end

	if RENDER_3D then VisibilityGroup.SetActive(nil) end
end

-- the entity drawing the batches of a visibility group
function META:GetBatchVisual(batch)
	local container = batch.visibility_group or self.Owner
	local visual_entity = self.visual_entities[container]

	if not visual_entity then
		visual_entity = Entity.New{Name = "world", Parent = container}
		visual_entity:SetTransient(true)
		visual_entity:AddComponent("transform")
		visual_entity:AddComponent("visual")
		visual_entity.static_generated = true
		self.visual_entities[container] = visual_entity
		list.insert(self.visual_list, visual_entity)
	end

	return visual_entity
end

function META:AttachBatch(batch)
	self.batch_primitives[batch] = self:GetBatchVisual(batch).visual:CreatePrimitiveEntity(
		batch.mesh,
		batch.material,
		file_path.RemoveExtensionFromPath(file_path.GetFileNameFromPath(batch.material:GetName()))
	)
end

-- Frees the vertices of spans. Spans at the end of their batch are cut off, others are collapsed to a point.
function META:ReleaseSpans(spans, touched)
	for i = #spans, 1, -1 do
		local span = spans[i]
		local mesh = span.entry.mesh
		local vertices = mesh.Vertices
		local last = span.first + span.count - 1

		if last + 1 == mesh.i and span.first > 1 then
			for k = last, span.first, -1 do
				vertices[k] = nil
			end

			mesh.i = span.first
		else
			local anchor = vertices[span.first].pos

			for k = span.first, last do
				vertices[k].pos = anchor
			end
		end

		touched[span.entry] = true
	end
end

function META:RefreshBatch(batch)
	if batch.is_new then
		static_geometry.UploadBatch(batch)
		self:AttachBatch(batch)
		self:GetBatchVisual(batch).visual:BuildAABB()
	else
		batch.mesh:Upload(nil)
		self.batch_primitives[batch].visual_primitive:SetPolygon3D(batch.mesh)
	end
end

function META:RefreshBatches(touched)
	for batch in pairs(touched) do
		if #batch.mesh.Vertices > 0 or not batch.is_new then self:RefreshBatch(batch) end
	end
end

-- Replaces the triangles of a decal. fragments is a list of {group, polygon of {pos, u, v}}.
function META:SetDecalFragments(owner, fragments)
	local touched = {}
	local old_spans = self.decal_spans[owner]

	if old_spans then self:ReleaseSpans(old_spans, touched) end

	local spans = {}

	for _, fragment in ipairs(fragments) do
		local batch = static_geometry.GetBatch(
			self.batch_state,
			owner.Material:match("^materials/(.*)%.vmt$"),
			fragment.group,
			"overlay"
		)
		local first, count = static_geometry.AddPolygon(batch.mesh, fragment.polygon)
		batch.mesh:BuildTangents(first, first + count - 1)
		list.insert(spans, {entry = batch, first = first, count = count})
		touched[batch] = true
	end

	self.decal_spans[owner] = spans

	if self.built then self:RefreshBatches(touched) end
end

function META:RemoveDecal(owner)
	local spans = self.decal_spans[owner]

	if not spans then return end

	local touched = {}
	self:ReleaseSpans(spans, touched)
	self.decal_spans[owner] = nil
	self:RefreshBatches(touched)
end

function META:BuildColliders()
	local shapes, model, primitives = static_geometry.BuildColliders(self.brush_list, self.displacement_list, self.mesh_list)
	model.Owner = self.Owner
	self.collision_model = model
	self.collision_primitives = primitives
	self.model_shape = shapes[1] and shapes[1].Model == model and shapes[1] or {Model = model}
	self.collision_shapes = shapes

	if shapes[1] then self:AddRigidBody() end
end

function META:AddRigidBody()
	self.Owner:AddComponent(
		"rigid_body",
		{
			Shapes = self.collision_shapes,
			MotionType = "static",
			Friction = 0.85,
			Restitution = 0,
			WorldGeometry = true,
		}
	)
end

function META:RefreshColliders()
	if not self.built then return end

	if self.Owner:HasComponent("rigid_body") then
		self.Owner:RemoveComponent("rigid_body")
	end

	self.collision_primitives = {}
	self.collision_model = nil
	self.collision_shapes = nil

	if self.Colliders then self:BuildColliders() end
end

-- brings the collision of one record in line with its current shape
function META:UpdateCollider(record)
	local model = self.collision_model

	if not model then return end

	if record.kind == "brush" then
		local primitive = self.collision_primitives[record]

		if not record.collide then
			if primitive then self:RemoveCollider(record) end

			return
		end

		local planes = {}

		for i, side in ipairs(record.sides) do
			planes[i] = units.PlaneToEngine(side)
		end

		if primitive then
			if not collision.update_brush_primitive(primitive, planes) then return end
		else
			primitive = collision.build_brush_primitive(planes)

			if not primitive or not primitive.aabb then return end

			self.collision_primitives[record] = primitive
			list.insert(model.Primitives, primitive)
		end

		model.AABB:Expand(primitive.aabb)
		model.raycast_primitive_acceleration = nil

		if not list.has_value(self.collision_shapes, self.model_shape) then
			list.insert(self.collision_shapes, 1, self.model_shape)
		end
	else
		local shape = record.collision_shape

		if record.kind == "mesh" and not record.collide then
			if shape then self:RemoveCollider(record) end

			return
		end

		local fresh = record.kind == "mesh" and
			collision.build_triangle_soup_shape(record.positions) or
			collision.build_displacement_collision_shape(record.positions, record.dims)

		if shape then
			shape.Polygon3D = fresh.Polygon3D
		else
			record.collision_shape = fresh
			list.insert(self.collision_shapes, fresh)
		end
	end

	if self.Owner.rigid_body then
		self.Owner.rigid_body:OnGeometryChanged()
	else
		self:AddRigidBody()
	end
end

function META:RemoveCollider(record)
	if not self.collision_model then return end

	if record.kind == "brush" then
		local primitive = self.collision_primitives[record]

		if not primitive then return end

		self.collision_primitives[record] = nil
		list.remove_value(self.collision_model.Primitives, primitive)
		self.collision_model.raycast_primitive_acceleration = nil
	else
		if not record.collision_shape then return end

		list.remove_value(self.collision_shapes, record.collision_shape)
		record.collision_shape = nil
	end

	if self.Owner.rigid_body then self.Owner.rigid_body:OnGeometryChanged() end
end

function META:OnUpdate()
	local now = system.GetElapsedTime()

	if (self.removed[1] or next(self.dirty)) and now - self.last_flush >= FLUSH_INTERVAL then
		self.last_flush = now
		self:Flush(now)
	end

	for component, edit in pairs(self.edits) do
		if self.edit_dirty[component] then
			self.edit_dirty[component] = nil
			edit.time = now
			self:UpdateEdit(component, edit)
		elseif now - edit.time > EDIT_SETTLE_TIME then
			self:EndEdit(component, edit)
		end
	end

	if next(self.collision_dirty) then
		for component, time in pairs(self.collision_dirty) do
			if now - time > COLLISION_SETTLE_TIME then
				self.collision_dirty[component] = nil
				local record = self.records[component]

				if record then self:UpdateCollider(record) end
			end
		end
	end
end

function META:Flush(now)
	local touched = {}
	local removed = self.removed
	self.removed = {}

	for _, record in ipairs(removed) do
		self:ReleaseSpans(record.spans, touched)
		self:RemoveCollider(record)
		list.remove_value(self:GetList(record.kind), record)
	end

	local dirty = self.dirty
	self.dirty = {}

	for component in pairs(dirty) do
		local record = self.records[component]

		if record then
			self:ReleaseSpans(record.spans, touched)
			component:UpdateRecord(record)
		else
			record = self:CreateRecord(component)
		end

		self:EmitRecord(self.batch_state, record)

		for _, span in ipairs(record.spans) do
			span.entry.mesh:BuildTangents(span.first, span.first + span.count - 1)
			touched[span.entry] = true
		end

		self.collision_dirty[component] = now
	end

	if RENDER_2D then self:RefreshBatches(touched) end
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
		local best_record, best_t = nil, (max_distance or math.huge) / units.meters

		for _, record in ipairs(self.brush_list) do
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
					best_record, best_t = record, t_enter
				end
			end
		end

		if best_record then return best_record, best_t * units.meters end
	end

	function META:PickDisplacement(origin, direction, max_distance)
		local o = units.PositionFromEngine(origin)
		local ox, oy, oz = o.x, o.y, o.z
		local dx, dy, dz = -direction.z, -direction.x, direction.y
		local best_record, best_t = nil, (max_distance or math.huge) / units.meters

		for _, record in ipairs(self.displacement_list) do
			if ray_box(ox, oy, oz, dx, dy, dz, record.mins, record.maxs, best_t) then
				local positions, dims = record.positions, record.dims

				for x = 1, dims - 1 do
					for y = 1, dims - 1 do
						local a = y * dims + x
						local b = (y - 1) * dims + x
						local c = a + 1
						local d = b + 1
						local t1 = ray_triangle(ox, oy, oz, dx, dy, dz, positions[a], positions[c], positions[b])
						local t2 = ray_triangle(ox, oy, oz, dx, dy, dz, positions[c], positions[d], positions[b])

						if t1 and t1 < best_t then best_record, best_t = record, t1 end

						if t2 and t2 < best_t then best_record, best_t = record, t2 end
					end
				end
			end
		end

		if best_record then return best_record, best_t * units.meters end
	end

	function META:PickMesh(origin, direction, max_distance)
		local o = units.PositionFromEngine(origin)
		local ox, oy, oz = o.x, o.y, o.z
		local dx, dy, dz = -direction.z, -direction.x, direction.y
		local best_record, best_t = nil, (max_distance or math.huge) / units.meters

		for _, record in ipairs(self.mesh_list) do
			if ray_box(ox, oy, oz, dx, dy, dz, record.mins, record.maxs, best_t) then
				local positions = record.positions

				for i = 1, #positions, 3 do
					local t = ray_triangle(ox, oy, oz, dx, dy, dz, positions[i], positions[i + 1], positions[i + 2])

					if t and t < best_t then best_record, best_t = record, t end
				end
			end
		end

		if best_record then return best_record, best_t * units.meters end
	end
end

function META:PickGeometry(origin, direction)
	local best, best_distance

	for _, pick in ipairs{self.PickBrush, self.PickDisplacement, self.PickMesh} do
		local record, distance = pick(self, origin, direction)

		if record and (not best or distance <= best_distance + 0.05) then
			best, best_distance = record, distance
		end
	end

	if best then return best.component.Owner, best_distance end
end

return META:Register()
