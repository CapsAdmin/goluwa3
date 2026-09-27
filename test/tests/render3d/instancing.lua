local T = import("test/environment.lua")
local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local InstanceBatcher = import("goluwa/render3d/instance_batcher.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local objects = import("goluwa/objects/objects.lua")
local FloatPtr = ffi.typeof("float *")

-- identical cubes share a deduplicated mesh, so different sizes give different
-- meshes
local function create_cube(size)
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(size or 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	return polygon3d
end

local function create_matrix(x)
	local m = Matrix44():Identity()
	m:SetTranslation(x, 0, 0)
	return m
end

-- records what the batcher asks to draw
local draws

local function draw_single(context, batch)
	draws[#draws + 1] = {
		kind = "single",
		context = context,
		mesh = batch.mesh,
		material = batch.material,
		count = batch.count,
	}
end

local function draw_instanced(context, batch, instance_buffers, first_instance)
	draws[#draws + 1] = {
		kind = "instanced",
		context = context,
		mesh = batch.mesh,
		material = batch.material,
		count = batch.count,
		instance_buffers = instance_buffers,
		first_instance = first_instance,
	}
end

local function create_batcher(prev_matrices)
	draws = {}
	return InstanceBatcher.New{
		label = "test instances",
		prev_matrices = prev_matrices,
		draw_single = draw_single,
		draw_instanced = draw_instanced,
	}
end

local function find_draw(mesh, material)
	for _, draw in ipairs(draws) do
		if draw.mesh == mesh and draw.material == material then return draw end
	end
end

local function matrix_matches_buffer(matrix, instance_buffer, instance_index)
	local expected = ffi.new("float[16]")
	matrix:CopyToFloatPointer(expected)
	local ptr = ffi.cast(FloatPtr, instance_buffer.data) + instance_index * 16

	for i = 0, 15 do
		if ptr[i] ~= expected[i] then return false end
	end

	return true
end

T.Test3D("Graphics render3d instance batcher groups by mesh and material", function()
	local batcher = create_batcher()
	local cube_a = create_cube(1)
	local cube_b = create_cube(2)
	T(cube_a:GetMesh() ~= cube_b:GetMesh())["=="](true)
	local material_a = Material.New()
	local material_b = Material.New()
	local context = {}

	for i = 1, 3 do
		batcher:Queue(cube_a, cube_a:GetMesh(), material_a, create_matrix(i))
	end

	batcher:Queue(cube_a, cube_a:GetMesh(), material_b, create_matrix(4))
	batcher:Queue(cube_b, cube_b:GetMesh(), material_a, create_matrix(5))
	batcher:Queue(cube_b, cube_b:GetMesh(), material_a, create_matrix(6))
	local instanced, single = batcher:Flush(context, 1)
	T(instanced)["=="](2)
	T(single)["=="](1)
	T(#draws)["=="](3)
	T(find_draw(cube_a:GetMesh(), material_a).count)["=="](3)
	T(find_draw(cube_a:GetMesh(), material_a).kind)["=="]("instanced")
	T(find_draw(cube_a:GetMesh(), material_b).kind)["=="]("single")
	T(find_draw(cube_b:GetMesh(), material_a).count)["=="](2)
	T(draws[1].context)["=="](context)
	batcher:Remove()
end)

T.Test3D("Graphics render3d instance batcher shares batches between materials with the same upload key", function()
	local batcher = create_batcher()
	local cube = create_cube()
	local material_a = Material.New()
	local material_b = Material.New()
	material_a.upload_cache_key = "shared"
	material_b.upload_cache_key = "shared"
	batcher:Queue(cube, cube:GetMesh(), material_a, create_matrix(1))
	batcher:Queue(cube, cube:GetMesh(), material_b, create_matrix(2))
	local instanced, single = batcher:Flush(nil, 1)
	T(instanced)["=="](1)
	T(single)["=="](0)
	T(draws[1].count)["=="](2)
	batcher:Remove()
end)

T.Test3D("Graphics render3d instance batcher appends flushes of one submission and restarts on the next", function()
	local batcher = create_batcher(true)
	local cube = create_cube()
	local material = Material.New()
	local first_worlds = {create_matrix(1), create_matrix(2), create_matrix(3)}
	local second_worlds = {create_matrix(4), create_matrix(5)}
	local prev_world = create_matrix(10)

	for _, world in ipairs(first_worlds) do
		batcher:Queue(cube, cube:GetMesh(), material, world, prev_world)
	end

	batcher:Flush(nil, 1)

	for _, world in ipairs(second_worlds) do
		batcher:Queue(cube, cube:GetMesh(), material, world, prev_world)
	end

	batcher:Flush(nil, 1)
	T(#draws)["=="](2)
	T(draws[1].first_instance)["=="](0)
	T(draws[2].first_instance)["=="](3)
	-- both flushes are in the buffers the draws reference, the first one wasn't
	-- overwritten by the second
	T(draws[1].instance_buffers)["=="](draws[2].instance_buffers)
	local buffers = draws[2].instance_buffers
	T(#buffers)["=="](2)

	for i, world in ipairs(first_worlds) do
		T(matrix_matches_buffer(world, buffers[1], i - 1))["=="](true)
		T(matrix_matches_buffer(prev_world, buffers[2], i - 1))["=="](true)
	end

	for i, world in ipairs(second_worlds) do
		T(matrix_matches_buffer(world, buffers[1], 3 + i - 1))["=="](true)
	end

	batcher:Queue(cube, cube:GetMesh(), material, create_matrix(7))
	batcher:Queue(cube, cube:GetMesh(), material, create_matrix(8))
	batcher:Flush(nil, 2)
	T(draws[3].first_instance)["=="](0)
	batcher:Remove()
end)

T.Test3D("Graphics render3d instance batcher keeps outgrown buffers until the next submission", function()
	local batcher = create_batcher()
	local cube = create_cube()
	local material = Material.New()

	for i = 1, 40 do
		batcher:Queue(cube, cube:GetMesh(), material, create_matrix(i))
	end

	batcher:Flush(nil, 1)
	local first_buffer = draws[1].instance_buffers[1]
	T(first_buffer.vertex_count < 40 + 100)["=="](true)

	for i = 1, 100 do
		batcher:Queue(cube, cube:GetMesh(), material, create_matrix(i))
	end

	batcher:Flush(nil, 1)
	local second_buffer = draws[2].instance_buffers[1]
	T(second_buffer ~= first_buffer)["=="](true)
	T(draws[2].first_instance)["=="](0)
	-- the first flush's draw was recorded against it and hasn't run yet
	T(first_buffer:IsValid())["=="](true)
	batcher:Queue(cube, cube:GetMesh(), material, create_matrix(1))
	batcher:Queue(cube, cube:GetMesh(), material, create_matrix(2))
	batcher:Flush(nil, 2)
	T(first_buffer:IsValid())["=="](false)
	T(second_buffer:IsValid())["=="](true)
	T(draws[3].instance_buffers[1])["=="](second_buffer)
	batcher:Remove()
	T(second_buffer:IsValid())["=="](false)
end)

T.Test3D("Graphics render3d instance batcher skips removed meshes", function()
	local batcher = create_batcher()
	local cube = create_cube(1)
	local removed = create_cube(3)
	local material = Material.New()
	batcher:Queue(cube, cube:GetMesh(), material, create_matrix(1))
	batcher:Queue(removed, removed:GetMesh(), material, create_matrix(2))
	batcher:Queue(removed, removed:GetMesh(), material, create_matrix(3))
	removed:GetMesh():Remove()
	local instanced, single = batcher:Flush(nil, 1)
	T(instanced)["=="](0)
	T(single)["=="](1)
	T(draws[1].mesh)["=="](cube:GetMesh())
	batcher:Remove()
end)

T.Test3D("Graphics render3d instance batcher lets go of meshes after a flush", function()
	local batcher = create_batcher()
	local material = Material.New()

	do
		local cube = create_cube(4)
		batcher:Queue(cube, cube:GetMesh(), material, create_matrix(1))
		batcher:Queue(cube, cube:GetMesh(), material, create_matrix(2))
		batcher:Flush(nil, 1)
		cube:GetMesh():Remove()
		cube:Remove()
	end

	draws = {}
	objects.CheckRemovedObjects()
	collectgarbage()
	collectgarbage()
	T(next(batcher.batches))["=="](nil)
	batcher:Remove()
end)

do
	local function attach_visual(entity, polygon3d, material)
		entity:AddComponent("visual")
		local primitive = Entity.New{
			Name = entity:GetName() .. "_primitive",
			Parent = entity,
		}
		primitive:AddComponent("transform")
		local visual_primitive = primitive:AddComponent("visual_primitive")
		visual_primitive:SetPolygon3D(polygon3d)
		visual_primitive:SetMaterial(material)
		entity.visual:BuildAABB()
		-- conditional rendering draws directly instead of queueing
		entity.visual:SetUseOcclusionCulling(false)
		return entity.visual
	end

	local function spawn(name, x, polygon3d, material)
		local entity = Entity.New({Name = name})
		entity:AddComponent("transform")
		entity.transform:SetPosition(Vec3(x, 0, -6))
		attach_visual(entity, polygon3d, material)
		return entity
	end

	-- with gpu culling the static batches are drawn by the gpu and never reach
	-- the cpu queue
	local function draw_without_gpu_culling(draw)
		local camera = render3d.GetCamera()
		camera:SetFOV(math.rad(90))
		camera:SetNearZ(0.1)
		camera:SetFarZ(100)
		camera:SetPosition(Vec3(0, 0, 0))
		camera:SetRotation(Quat():Identity())
		local was_enabled = gpu_culling.IsEnabled()
		gpu_culling.SetEnabled(false)
		local ok, err = pcall(draw)
		gpu_culling.SetEnabled(was_enabled)

		if not ok then error(err, 0) end
	end

	T.Test3D("Graphics render3d instancing keeps distinct VMT materials out of a shared batch", function(draw)
		local polygon3d = create_cube()
		local material_a = Material.New()
		material_a.vmt_path = "materials/tests/shared.vmt"
		material_a:SetColorMultiplier(Color(1, 0, 0, 1))
		local material_b = Material.New()
		material_b.vmt_path = material_a.vmt_path
		material_b:SetColorMultiplier(Color(0, 1, 0, 1))
		local entity_a = spawn("instanced_material_a", -1.5, polygon3d, material_a)
		local entity_b = spawn("instanced_material_b", 1.5, polygon3d, material_b)
		draw_without_gpu_culling(draw)
		local stats = gbuffer_instancing.GetStats()
		T(stats.queued_instances)["=="](2)
		T(stats.instanced_draws)["=="](0)
		T(stats.singleton_draws)["=="](2)
		entity_a:Remove()
		entity_b:Remove()
	end)

	T.Test3D("Graphics render3d instancing batches entries sharing a mesh and material", function(draw)
		local polygon3d = create_cube()
		local material = Material.New()
		local entities = {}

		for i = 1, 5 do
			entities[i] = spawn("instanced_shared_" .. i, i * 2 - 6, polygon3d, material)
		end

		local other = spawn("instanced_other", 0, polygon3d, Material.New())
		draw_without_gpu_culling(draw)
		local stats = gbuffer_instancing.GetStats()
		T(stats.queued_instances)["=="](6)
		T(stats.instanced_draws)["=="](1)
		T(stats.singleton_draws)["=="](1)

		for _, entity in ipairs(entities) do
			entity:Remove()
		end

		other:Remove()
	end)
end
