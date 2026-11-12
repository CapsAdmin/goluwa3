local Entity = import("goluwa/entities/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local foliage_field = import("goluwa/foliage_field.lua")
local TerrainPhysics = {}
TerrainPhysics.__index = TerrainPhysics

function TerrainPhysics.New(terrain, config)
	local self = setmetatable({}, TerrainPhysics)
	self.Terrain = terrain
	self.ChunkSize = config.chunk_size or 64
	self.Samples = config.samples or 65
	self.Radius = config.radius or 2
	self.Friction = config.friction or 0.8
	self.Restitution = config.restitution or 0
	self.Colliders = {}
	self.Root = Entity.New{Name = terrain.Name .. "_physics", Parent = terrain.Root}
	self.Root:AddComponent("transform")
	self.anchors = {}
	foliage_field.SetTerrain(terrain.Source.Data)
	return self
end

function TerrainPhysics:GatherAnchors(camera_position)
	local anchors = self.anchors
	list.clear(anchors)

	if camera_position then anchors[1] = camera_position end

	for _, body in ipairs(RigidBody.Instances) do
		if body:IsDynamic() and body:GetAwake() then
			anchors[#anchors + 1] = body:GetPosition()
		end
	end

	return anchors
end

function TerrainPhysics:BuildRequest(chunk_x, chunk_z)
	return {
		min_x = chunk_x * self.ChunkSize,
		min_z = chunk_z * self.ChunkSize,
		size = self.ChunkSize,
		generation = self.Terrain.Generation,
		samples = self.Samples,
	}
end

function TerrainPhysics:CreateCollider(key, chunk_x, chunk_z, chunk)
	local entity = Entity.New{
		Name = string.format("%s_collider_%d_%d", self.Terrain.Name, chunk_x, chunk_z),
		Parent = self.Root,
	}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3((chunk_x + 0.5) * self.ChunkSize, 0, (chunk_z + 0.5) * self.ChunkSize))
	entity.terrain_data = self.Terrain.Source.Data
	entity:AddComponent(
		"rigid_body",
		{
			MotionType = "static",
			WorldGeometry = true,
			Friction = self.Friction,
			Restitution = self.Restitution,
			Shape = HeightmapShape.New{
				Samples = chunk.heights,
				SamplesX = chunk.request.samples,
				SamplesZ = chunk.request.samples,
				Size = Vec2(self.ChunkSize, self.ChunkSize),
			},
		}
	)
	return entity
end

function TerrainPhysics:Update(camera_position)
	local anchors = self:GatherAnchors(camera_position)
	local desired = {}
	local radius = self.Radius
	local chunk_size = self.ChunkSize

	for i = 1, #anchors do
		local anchor = anchors[i]
		local center_x = math.floor(anchor.x / chunk_size)
		local center_z = math.floor(anchor.z / chunk_size)

		for dz = -radius, radius do
			for dx = -radius, radius do
				local chunk_x = center_x + dx
				local chunk_z = center_z + dz
				local key = chunk_x .. ":" .. chunk_z

				if not desired[key] then
					desired[key] = {
						chunk_x = chunk_x,
						chunk_z = chunk_z,
						distance = math.max(math.abs(dx), math.abs(dz)),
					}
				end
			end
		end
	end

	for key, collider in pairs(self.Colliders) do
		if not desired[key] then
			if collider.entity then collider.entity:Remove() end

			if collider.chunk_key then self.Terrain:ReleaseChunk(collider.chunk_key) end

			if collider.rebuild_key then self.Terrain:ReleaseChunk(collider.rebuild_key) end

			self.Colliders[key] = nil
		end
	end

	for key, want in pairs(desired) do
		if not self.Colliders[key] then
			local collider = {chunk_x = want.chunk_x, chunk_z = want.chunk_z}
			self.Colliders[key] = collider
			collider.chunk_key = self.Terrain:AcquireChunk(
				self:BuildRequest(want.chunk_x, want.chunk_z),
				function(chunk)
					if self.Colliders[key] ~= collider then return end

					collider.entity = self:CreateCollider(key, want.chunk_x, want.chunk_z, chunk)
				end,
				want.distance
			)
		end
	end
end

-- colliders over a box are built again and swapped once their chunk is ready
function TerrainPhysics:Invalidate(box)
	local chunk_size = self.ChunkSize

	for key, collider in pairs(self.Colliders) do
		local min_x, min_z = collider.chunk_x * chunk_size, collider.chunk_z * chunk_size

		if
			collider.entity and
			min_x < box.max_x and
			box.min_x < min_x + chunk_size and
			min_z < box.max_z and
			box.min_z < min_z + chunk_size
		then
			local old_rebuild = collider.rebuild_key
			local generation = self.Terrain.Generation
			collider.rebuild_generation = generation
			collider.rebuild_key = self.Terrain:AcquireChunk(
				self:BuildRequest(collider.chunk_x, collider.chunk_z),
				function(chunk)
					if self.Colliders[key] ~= collider or collider.rebuild_generation ~= generation then
						return
					end

					collider.entity:Remove()
					collider.entity = self:CreateCollider(key, collider.chunk_x, collider.chunk_z, chunk)
					self.Terrain:ReleaseChunk(collider.chunk_key)
					collider.chunk_key = collider.rebuild_key
					collider.rebuild_key = nil
				end,
				-1
			)

			if old_rebuild then self.Terrain:ReleaseChunk(old_rebuild) end
		end
	end
end

function TerrainPhysics:Remove()
	foliage_field.SetTerrain(nil)

	for key, collider in pairs(self.Colliders) do
		if collider.entity then collider.entity:Remove() end

		if collider.chunk_key then self.Terrain:ReleaseChunk(collider.chunk_key) end

		if collider.rebuild_key then self.Terrain:ReleaseChunk(collider.rebuild_key) end

		self.Colliders[key] = nil
	end

	if self.Root:IsValid() then self.Root:Remove() end
end

return TerrainPhysics
