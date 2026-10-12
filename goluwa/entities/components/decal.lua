local objects = import("goluwa/objects/objects.lua")
local decal_geometry = import("goluwa/source_engine/decal_geometry.lua")
local decal_projection = import("goluwa/render3d/decal_projection.lua")
local decal_receivers = import("goluwa/render3d/decal_receivers.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local units = import("goluwa/source_engine/units.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local META = objects.CreateTemplate("decal")
META:StartStorable()
META:GetSet("Material", "", {asset = "materials", callback = "OnMaterialChanged"})
-- brush projects on the brushes and displacements of a source static world, in source units. The other projections
-- work in engine space and use the decal transform as the box [-1, 1] on every axis: planar is a quad, terrain drapes
-- over the height of the static world, objects clips the triangles of visuals that receive decals, terrain_objects is
-- both and road is a strip along Points on the terrain.
META:GetSet("Projection", "brush", {callback = "OnFrameChanged"})
META:GetSet("Frame", Vec4(-16, -16, 16, 16), {callback = "OnFrameChanged"})
META:GetSet("URange", Vec2(0, 1), {callback = "OnFrameChanged"})
META:GetSet("VRange", Vec2(0, 1), {callback = "OnFrameChanged"})
META:GetSet("SortPriority", 0, {callback = "OnFrameChanged"})
-- road: ten numbers per point, position, back handle and forward handle in engine space and the width
META:GetSet("Points", nil, {type = "table", callback = "OnFrameChanged"})
META:GetSet("Width", 1, {callback = "OnFrameChanged"})
META:GetSet("TileLength", 1, {callback = "OnFrameChanged"})
-- road: the length in meters over which the road fades in and out at its ends
META:GetSet("FadeLength", 1, {callback = "OnFrameChanged"})
-- 1 hangs the height map below the decal polygon, 0.5 centers it on the polygon
META:GetSet("HeightMidlevel", 1, {callback = "OnMaterialChanged"})
META:GetSet("SharpAlpha", false, {callback = "OnMaterialChanged"})
META:EndStorable()
local REBUILD_SETTLE_TIME = 0.2
local PROJECTION_BUDGET = 0.004
-- how far the decal geometry sits above the surface in meters, plus a little per sort priority
local PROJECTION_OFFSETS = {
	planar = 0.005,
	objects = 0.005,
	terrain_objects = 0.005,
	terrain = 0.02,
	road = 0.03,
}
local PRIORITY_OFFSET = 0.002
-- decals of the same priority that overlap are layered in the order they are placed, each a little above the last. The
-- steps stay inside one priority step so the priority always wins
local LAYER_OFFSET = 0.00025
local MAX_LAYERS = 7
local LAYER_CELL_SIZE = 8
local MIN_FACING = 0.2
local ROAD_STEP = 1

function META:ReadTransform()
	local transform = self.Owner.transform
	self.Origin = units.PositionFromEngine(transform:GetWorldPosition())
	self.Normal, self.UAxis = decal_geometry.RotationToAxes(transform:GetRotation())
end

function META:OnDeserialized()
	local world = static_world.Find(self.Owner)

	if world then world:AddDecal(self) end
end

function META:Attach(world)
	self.world = world

	if self.Projection == "brush" then
		self:ReadTransform()
		self:FindTargets()
		self:Rebuild()
	else
		self:QueueProjection()
	end
end

function META:Rebuild()
	self.world:SetDecalFragments(self, decal_geometry.Project(self))
end

-- the key of the batch of the decal and its material, the material is nil when the batch can create it from the key
function META:GetBatchMaterial()
	local texname = self.Material:match("^materials/(.*)%.vmt$")

	if texname then return texname end

	local slots, material = Material.GetOverrideFromPath(self.Material)
	material = slots and slots[0] or material
	material:SetDithered(true)
	material:SetDecalFade(true)
	material:SetHeightMidlevel(self.HeightMidlevel)
	material:SetSharpAlpha(self.SharpAlpha)
	return self.Material, material
end

function META:OnMaterialChanged()
	if not self.world then return end

	if self.Projection == "brush" then self:Rebuild() else self:QueueProjection() end
end

function META:FindTargets()
	self.Targets = decal_geometry.FindTargets(self, self.world.brush_list, self.world.displacement_list)
end

function META:OnFrameChanged()
	if not self.world then return end

	if self.Projection == "brush" then
		self:FindTargets()
		self:Rebuild()
	else
		self:QueueProjection()
	end
end

do
	local function cell_key(x, z)
		return (x + 32768) * 65536 + z + 32768
	end

	-- how many decals that do not have a higher priority are already placed over this one, and registers this one
	function META:TakeLayer(placed)
		local matrix = self.Owner.transform:GetWorldMatrix()
		local x, z = matrix.m30, matrix.m32
		local radius = math.sqrt(matrix.m00 * matrix.m00 + matrix.m01 * matrix.m01 + matrix.m02 * matrix.m02)
		local layer = 0
		local cell_x, cell_z = math.floor(x / LAYER_CELL_SIZE), math.floor(z / LAYER_CELL_SIZE)

		if self.layer_entry then self.layer_entry.removed = true end

		for i = cell_x - 1, cell_x + 1 do
			for j = cell_z - 1, cell_z + 1 do
				for _, other in ipairs(placed[cell_key(i, j)] or {}) do
					local dx, dz = other.x - x, other.z - z
					local reach = (other.radius + radius) * 0.8

					if
						not other.removed and
						other.priority <= self.SortPriority and
						dx * dx + dz * dz < reach * reach
					then
						layer = layer + 1
					end
				end
			end
		end

		local key = cell_key(cell_x, cell_z)
		local cell = placed[key]

		if not cell then
			cell = {}
			placed[key] = cell
		end

		self.layer_entry = {x = x, z = z, radius = radius, priority = self.SortPriority}
		cell[#cell + 1] = self.layer_entry
		return math.min(layer, MAX_LAYERS)
	end
end

function META:BuildFrame(layer)
	local matrix = self.Owner.transform:GetWorldMatrix()
	local right = Vec3(matrix.m00, matrix.m01, matrix.m02)
	local up = Vec3(matrix.m10, matrix.m11, matrix.m12)
	local back = Vec3(matrix.m20, matrix.m21, matrix.m22)
	local half_x, half_y, half_z = right:GetLength(), up:GetLength(), back:GetLength()
	return {
		origin = Vec3(matrix.m30, matrix.m31, matrix.m32),
		right = right / half_x,
		up = up / half_y,
		back = back / half_z,
		half_x = half_x,
		half_y = half_y,
		half_z = half_z,
		u_range = self.URange,
		v_range = self.VRange,
		offset = PROJECTION_OFFSETS[self.Projection] + self.SortPriority * PRIORITY_OFFSET + layer * LAYER_OFFSET,
		min_facing = MIN_FACING,
	}
end

function META:BuildRoad()
	local values = self.Points
	local points = {}

	for i = 1, #values, 10 do
		points[#points + 1] = {
			pos = Vec3(values[i], values[i + 1], values[i + 2]),
			back = Vec3(values[i + 3], values[i + 4], values[i + 5]),
			forw = Vec3(values[i + 6], values[i + 7], values[i + 8]),
			width = values[i + 9],
		}
	end

	return {
		points = points,
		width = self.Width,
		tile_length = self.TileLength,
		fade_length = math.max(self.FadeLength, 0.01),
		step = ROAD_STEP,
	}
end

-- the fragments of a non brush decal, receivers is only used by the projections that clip against visuals
function META:Project(receivers, layer)
	local projection = self.Projection

	if projection == "road" then
		local height = assert(self.world.TerrainHeight, "road without terrain height")
		return decal_projection.Road(self:BuildRoad(), height, PROJECTION_OFFSETS.road + self.SortPriority * PRIORITY_OFFSET)
	end

	local frame = self:BuildFrame(layer)

	if projection == "planar" then return decal_projection.Planar(frame) end

	local fragments = {}

	if projection == "terrain" or projection == "terrain_objects" then
		fragments = decal_projection.Terrain(frame, assert(self.world.TerrainHeight, "terrain decal without terrain height"))
	end

	if projection == "objects" or projection == "terrain_objects" then
		list.extend(fragments, decal_projection.Objects(frame, receivers))
	end

	return fragments
end

do
	local pending = {}
	local head = 1
	local queued = {}
	local receivers
	local placed = {}
	local LISTENER = "decal_projection"

	local function process()
		if scene_loading.IsLoading() then return end

		local touched_by_world = {}
		local deadline = system.GetElapsedTime() + PROJECTION_BUDGET
		local last = #pending

		while head <= last and system.GetElapsedTime() < deadline do
			local decal = pending[head]
			pending[head] = nil
			head = head + 1

			if queued[decal] then
				local world = decal.world
				local projection = decal.Projection

				if projection == "planar" or projection == "objects" or world.TerrainHeight then
					queued[decal] = nil

					if projection == "objects" or projection == "terrain_objects" then
						receivers = receivers or decal_receivers.New()
					end

					local touched = touched_by_world[world]

					if not touched then
						touched = {}
						touched_by_world[world] = touched
					end

					world:SetDecalFragments(decal, decal:Project(receivers, decal.Projection ~= "road" and decal:TakeLayer(placed) or 0), touched)
				else
					pending[#pending + 1] = decal
				end
			end
		end

		for world, touched in pairs(touched_by_world) do
			world:RefreshBatches(touched)
		end

		if head > #pending and not next(queued) then
			pending, head, receivers, placed = {}, 1, nil, {}
			event.RemoveListener("Update", LISTENER)
		end
	end

	function META:QueueProjection()
		if queued[self] then return end

		queued[self] = true
		pending[#pending + 1] = self
		event.AddListener("Update", LISTENER, process)
	end

	function META:OnRemove()
		queued[self] = nil

		if self.world and self.world:IsValid() then self.world:RemoveDecal(self) end
	end
end

function META:Activate()
	if self.active then return end

	self.active = true
	self.last_position = self.Owner.transform:GetWorldPosition()
	self.last_rotation = self.Owner.transform:GetRotation():Copy()
	self:AddGlobalEvent("Update")
end

function META:OnUpdate()
	local transform = self.Owner.transform
	local position, rotation = transform:GetWorldPosition(), transform:GetRotation()

	if position ~= self.last_position or rotation ~= self.last_rotation then
		self.last_position = position
		self.last_rotation = rotation:Copy()
		self.rebuild_time = system.GetElapsedTime()
	elseif
		self.rebuild_time and
		system.GetElapsedTime() - self.rebuild_time > REBUILD_SETTLE_TIME
	then
		self.rebuild_time = nil

		if self.Projection == "brush" then self:ReadTransform() end

		self:OnFrameChanged()
	end
end

return META:Register()
