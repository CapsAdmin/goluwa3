local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Terrain = import("goluwa/terrain/terrain.lua")
local TerrainSource = import("goluwa/terrain/source.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")
local trace = import("goluwa/physics/trace.lua")
local Entity = import("goluwa/entities/entity.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function analytic_height(x, z)
	return 10 + math.sin(x * 0.1) * 3 + math.cos(z * 0.07) * 2
end

local function create_cpu_source()
	local source = TerrainSource.New{MinHeight = 0, MaxHeight = 20}
	source.requests = 0

	function source:RequestChunk(request, callback)
		self.requests = self.requests + 1
		local samples = request.samples
		local step = request.size / (samples - 1)
		local heights = HeightmapShape.SamplesFromFunction(samples, samples, function(x, z)
			return analytic_height(request.min_x + x * step, request.min_z + z * step)
		end)
		callback{request = request, heights = heights}
	end

	return source
end

local function create_terrain()
	local terrain = Terrain.New{
		Name = "terrain_test",
		Source = create_cpu_source(),
		Physics = {chunk_size = 32, samples = 17, radius = 1},
	}
	terrain.Root = Entity.New{Name = terrain.Name}
	terrain.Root:AddComponent("transform")
	terrain.Physics = import("goluwa/terrain/physics.lua").New(terrain, terrain.PhysicsConfig)
	return terrain
end

T.TestPhysics("Terrain streams heightmap colliders around anchors", function()
	local terrain = create_terrain()
	terrain.Physics:Update(Vec3(5, 50, 5))
	terrain:ProcessBuildQueue()
	terrain:ProcessBuildQueue()
	terrain:ProcessBuildQueue()
	terrain:ProcessBuildQueue()
	terrain:ProcessBuildQueue()
	local collider_count = 0

	for _, collider in pairs(terrain.Physics.Colliders) do
		if collider.entity then collider_count = collider_count + 1 end
	end

	T(collider_count)["=="](9)
	T(terrain.Source.requests)["=="](9)
	terrain.Physics:Update(Vec3(5 + 32 * 4, 50, 5))
	terrain:ProcessBuildQueue()
	terrain:ProcessBuildQueue()
	terrain:ProcessBuildQueue()
	terrain:ProcessBuildQueue()
	terrain:ProcessBuildQueue()
	collider_count = 0

	for _, collider in pairs(terrain.Physics.Colliders) do
		if collider.entity then collider_count = collider_count + 1 end
	end

	T(collider_count)["=="](9)
	local live_chunks = 0

	for _ in pairs(terrain.Chunks) do
		live_chunks = live_chunks + 1
	end

	T(live_chunks)["=="](9)
	terrain:Stop()
	T(next(terrain.Chunks) == nil)["=="](true)
end)

T.TestPhysics("Terrain colliders trace at the source height", function()
	local terrain = create_terrain()
	terrain.Physics:Update(Vec3(0, 50, 0))

	for _ = 1, 5 do
		terrain:ProcessBuildQueue()
	end

	for _, probe in ipairs{{3.5, 7.25}, {-12, 20}, {25, -9}, {-30, -30}} do
		local hit = trace.RayCast(Vec3(probe[1], 100, probe[2]), Vec3(0, -1, 0), 200)
		T(hit ~= nil)["=="](true)
		T(math.abs(hit.position.y - analytic_height(probe[1], probe[2])))["<"](0.35)
	end

	terrain:Stop()
end)

T.TestPhysics("Dynamic bodies rest on streamed terrain and pull colliders along", function()
	local terrain = create_terrain()
	terrain.Physics:Update(Vec3(0, 50, 0))

	for _ = 1, 5 do
		terrain:ProcessBuildQueue()
	end

	local ent = Entity.New{Name = "terrain_test_ball"}
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(4, 20, 4))
	local body = ent:AddComponent("rigid_body", {Shape = SphereShape.New(0.5)})

	for _ = 1, 20 do
		test_helpers.Simulate(30, 1 / 60)
		terrain.Physics:Update(Vec3(0, 50, 0))

		for _ = 1, 5 do
			terrain:ProcessBuildQueue()
		end
	end

	local position = body:GetPosition()
	local ground = analytic_height(position.x, position.z)
	T(position.y - ground)[">"](0.2)
	T(position.y - ground)["<"](1.5)
	local ball_key = math.floor(position.x / 32) .. ":" .. math.floor(position.z / 32)
	T(terrain.Physics.Colliders[ball_key] ~= nil)["=="](true)
	ent:Remove()
	terrain:Stop()
end)
