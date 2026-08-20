local T = import("test/environment.lua")
local raycast = import("goluwa/physics/raycast.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local AABB = import("goluwa/structs/aabb.lua")

do
	-- Build a raycast model source entry from a polygon. The physics engine
	-- must not depend on render3d, so tests drive raycasts through
	-- CreateModelSource instead of visual components.
	--
	-- model.AABB is the local-space bounds used for local ray culling.
	-- model:GetWorldAABB() (or model.AABB) is the broad bound used by the
	-- source BVH; pass a world_offset when the owner transform moves it.
	local function make_model(ent, poly, world_offset)
		local aabb = poly.AABB
		local model = {
			Owner = ent,
			Visible = true,
			AABB = aabb,
			Primitives = {
				{
					polygon3d = poly,
					aabb = aabb,
				},
			},
		}

		if world_offset then
			model.GetWorldAABB = function()
				return {
					min_x = aabb.min_x + world_offset.x,
					min_y = aabb.min_y + world_offset.y,
					min_z = aabb.min_z + world_offset.z,
					max_x = aabb.max_x + world_offset.x,
					max_y = aabb.max_y + world_offset.y,
					max_z = aabb.max_z + world_offset.z,
				}
			end
		end

		return model
	end

	local function make_source(models)
		return raycast.CreateModelSource(models)
	end

	local function make_triangle(normal)
		local poly = Polygon3D.New()
		local nz = normal.z
		poly:AddVertex{pos = Vec3(-1, -1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, nz)}
		poly:AddVertex{pos = Vec3(1, -1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, nz)}
		poly:AddVertex{pos = Vec3(0, 1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, nz)}
		poly:BuildBoundingBox()
		return poly
	end

	local function make_cube_entity(name, position)
		local ent = Entity.New({Name = name})
		ent:AddComponent("transform")

		if position then ent.transform:SetPosition(position) end

		local poly = Polygon3D.New()
		poly:CreateCube(0.5, 1)
		poly:BuildBoundingBox()
		return ent, poly
	end

	T.TestPhysics("Raycast basic triangle hit", function()
		local ent = Entity.New({Name = "test_triangle"})
		ent:AddComponent("transform")
		local poly = make_triangle(Vec3(0, 0, 1))
		local source = make_source{make_model(ent, poly)}
		-- Cast ray at triangle from +Z toward -Z
		local hits = raycast.CastFromSource(source, Vec3(0, 0, 2), Vec3(0, 0, -1), 10)
		T(#hits)["=="](1)
		T(hits[1].entity)["=="](ent)
		T(hits[1].distance)[">="](1.9)
		T(hits[1].distance)["<="](2.1)
		ent:Remove()
	end)

	T.TestPhysics("Raycast miss", function()
		local ent = Entity.New({Name = "test_triangle"})
		ent:AddComponent("transform")
		local poly = make_triangle(Vec3(0, 0, -1))
		local source = make_source{make_model(ent, poly)}
		-- Cast ray away from triangle
		local origin = Vec3(0, 0, -2)
		local direction = Vec3(1, 0, 0) -- Perpendicular to triangle
		local hits = raycast.CastFromSource(source, origin, direction, 10)
		T(#hits)["=="](0)
		ent:Remove()
	end)

	T.TestPhysics("Raycast cube", function()
		local ent = Entity.New({Name = "test_cube"})
		ent:AddComponent("transform")
		local poly = Polygon3D.New()
		poly:CreateCube(1, 1)
		poly:BuildBoundingBox()
		local source = make_source{make_model(ent, poly)}
		-- Cast ray at center of cube from different directions
		local tests = {
			{origin = Vec3(0, 0, -3), dir = Vec3(0, 0, 1), name = "front"},
			{origin = Vec3(0, 0, 3), dir = Vec3(0, 0, -1), name = "back"},
			{origin = Vec3(3, 0, 0), dir = Vec3(-1, 0, 0), name = "right"},
			{origin = Vec3(-3, 0, 0), dir = Vec3(1, 0, 0), name = "left"},
			{origin = Vec3(0, 3, 0), dir = Vec3(0, -1, 0), name = "top"},
			{origin = Vec3(0, -3, 0), dir = Vec3(0, 1, 0), name = "bottom"},
		}

		for _, test in ipairs(tests) do
			local hits = raycast.CastFromSource(source, test.origin, test.dir, 10)
			T(#hits, test.name)[">="](1)
		end

		ent:Remove()
	end)

	T.TestPhysics("Raycast with transform", function()
		-- Create entity with triangle mesh at offset position
		local ent = Entity.New({Name = "test_triangle"})
		ent:AddComponent("transform")
		-- Position entity to the right
		local position = Vec3(5, 0, 0)
		ent.transform:SetPosition(position)
		local poly = make_triangle(Vec3(0, 0, -1))
		local source = make_source{make_model(ent, poly, position)}
		-- Cast ray at origin (should miss)
		local hits1 = raycast.CastFromSource(source, Vec3(0, 0, -2), Vec3(0, 0, 1), 10)
		T(#hits1)["=="](0)
		-- Cast ray at offset position (should hit)
		local hits2 = raycast.CastFromSource(source, Vec3(5, 0, -2), Vec3(0, 0, 1), 10)
		T(#hits2)["=="](1)
		T(hits2[1].entity)["=="](ent)
		ent:Remove()
	end)

	T.TestPhysics("Raycast multiple entities", function()
		-- Create two entities at different positions
		local ent1, poly1 = make_cube_entity("cube1", Vec3(0, 0, 0))
		local ent2, poly2 = make_cube_entity("cube2", Vec3(0, 0, 3))
		local source = make_source{
			make_model(ent1, poly1),
			make_model(ent2, poly2, Vec3(0, 0, 3)),
		}
		-- Cast ray through both
		local origin = Vec3(0, 0, -5)
		local direction = Vec3(0, 0, 1)
		local hits = raycast.CastFromSource(source, origin, direction, 20)
		-- Should hit both entities, sorted by distance
		T(#hits)["=="](2)
		T(hits[1].entity)["=="](ent1) -- Closer one first
		T(hits[2].entity)["=="](ent2)
		T(hits[1].distance)["<"](hits[2].distance)
		ent1:Remove()
		ent2:Remove()
	end)

	T.TestPhysics("Raycast with filter", function()
		-- Create two entities
		local ent1, poly1 = make_cube_entity("include_me", Vec3(0, 0, 0))
		local ent2, poly2 = make_cube_entity("exclude_me", Vec3(0, 0, 3))
		local source = make_source{
			make_model(ent1, poly1),
			make_model(ent2, poly2, Vec3(0, 0, 3)),
		}
		-- Cast ray with filter that only includes entities with the right name
		local origin = Vec3(0, 0, -5)
		local direction = Vec3(0, 0, 1)
		local hits = raycast.CastFromSource(
			source,
			origin,
			direction,
			20,
			function(entity)
				return entity:GetName() == "include_me"
			end
		)
		-- Should only hit first entity
		T(#hits)["=="](1)
		T(hits[1].entity)["=="](ent1)
		ent1:Remove()
		ent2:Remove()
	end)

	T.TestPhysics("Raycast CastClosest", function()
		local ent = Entity.New({Name = "test_cube"})
		ent:AddComponent("transform")
		local poly = Polygon3D.New()
		poly:CreateCube(1, 1)
		poly:BuildBoundingBox()
		local source = make_source{make_model(ent, poly)}
		-- Cast and get only closest
		local hit = raycast.CastClosestFromSource(source, Vec3(0, 0, -5), Vec3(0, 0, 1), 10)
		T(hit)["~="](nil)
		T(hit.entity)["=="](ent)
		ent:Remove()
	end)

	T.TestPhysics("Raycast CastAny", function()
		local ent = Entity.New({Name = "test_cube"})
		ent:AddComponent("transform")
		local poly = Polygon3D.New()
		poly:CreateCube(1, 1)
		poly:BuildBoundingBox()
		local source = make_source{make_model(ent, poly)}
		-- Check if ray hits anything
		local hit = raycast.CastClosestFromSource(source, Vec3(0, 0, -5), Vec3(0, 0, 1), 10)
		T(hit ~= nil)["=="](true)
		-- Check miss
		local miss = raycast.CastClosestFromSource(source, Vec3(10, 0, -5), Vec3(0, 0, 1), 10)
		T(miss == nil)["=="](true)
		ent:Remove()
	end)

	T.TestPhysics("Raycast ground normal faces ray", function()
		local ent = Entity.New({Name = "test_ground"})
		ent:AddComponent("transform")
		local poly = Polygon3D.New()
		poly:AddVertex{pos = Vec3(-2, 0, -2), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
		poly:AddVertex{pos = Vec3(0, 0, 2), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
		poly:AddVertex{pos = Vec3(2, 0, -2), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
		poly:BuildBoundingBox()
		local source = make_source{make_model(ent, poly)}
		local hit = raycast.CastClosestFromSource(source, Vec3(0, 2, 0), Vec3(0, -1, 0), 10)
		T(hit)["~="](nil)
		T(hit.entity)["=="](ent)
		T(hit.normal.y)[">"](0.9)
		ent:Remove()
	end)

	T.TestPhysics("Raycast custom model source", function()
		local ent = Entity.New({Name = "test_source"})
		ent:AddComponent("transform")
		local poly = Polygon3D.New()
		poly:AddVertex{pos = Vec3(-1, -1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)}
		poly:AddVertex{pos = Vec3(1, -1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)}
		poly:AddVertex{pos = Vec3(0, 1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)}
		poly:BuildBoundingBox()
		local source = raycast.CreateModelSource{
			{
				Owner = ent,
				Visible = true,
				WorldSpaceVertices = true,
				AABB = poly.AABB,
				Primitives = {
					{
						polygon3d = poly,
						aabb = poly.AABB,
					},
				},
			},
		}
		local hit = raycast.CastClosestFromSource(source, Vec3(0, 0, 2), Vec3(0, 0, -1), 10)
		T(hit)["~="](nil)
		T(hit.entity)["=="](ent)
		T(hit.distance)[">="](1.9)
		T(hit.distance)["<="](2.1)
		ent:Remove()
	end)

	T.TestPhysics("Raycast convex brush primitive source", function()
		local ent = Entity.New({Name = "test_brush_source"})
		ent:AddComponent("transform")
		local source = raycast.CreateModelSource{
			{
				Owner = ent,
				Visible = true,
				WorldSpaceVertices = true,
				AABB = AABB(-1, -1, -1, 1, 1, 1),
				Primitives = {
					{
						brush_planes = {
							{normal = Vec3(1, 0, 0), dist = 1},
							{normal = Vec3(-1, 0, 0), dist = 1},
							{normal = Vec3(0, 1, 0), dist = 1},
							{normal = Vec3(0, -1, 0), dist = 1},
							{normal = Vec3(0, 0, 1), dist = 1},
							{normal = Vec3(0, 0, -1), dist = 1},
						},
						aabb = AABB(-1, -1, -1, 1, 1, 1),
					},
				},
			},
		}
		local hit = raycast.CastClosestFromSource(source, Vec3(0, 2, 0), Vec3(0, -1, 0), 10)
		T(hit)["~="](nil)
		T(hit.entity)["=="](ent)
		T(hit.distance)[">="](0.9)
		T(hit.distance)["<="](1.1)
		T(hit.normal.y)[">"](0.9)
		ent:Remove()
	end)

	T.TestPhysics("Raycast convex brush immediate inside hit", function()
		local ent = Entity.New({Name = "test_brush_inside"})
		ent:AddComponent("transform")
		local source = raycast.CreateModelSource{
			{
				Owner = ent,
				Visible = true,
				WorldSpaceVertices = true,
				AABB = AABB(-1, -1, -1, 1, 1, 1),
				Primitives = {
					{
						brush_planes = {
							{normal = Vec3(1, 0, 0), dist = 1},
							{normal = Vec3(-1, 0, 0), dist = 1},
							{normal = Vec3(0, 1, 0), dist = 1},
							{normal = Vec3(0, -1, 0), dist = 1},
							{normal = Vec3(0, 0, 1), dist = 1},
							{normal = Vec3(0, 0, -1), dist = 1},
						},
						aabb = AABB(-1, -1, -1, 1, 1, 1),
					},
				},
			},
		}
		local hit = raycast.CastClosestFromSource(source, Vec3(0.95, 0, 0), Vec3(1, 0, 0), 10)
		T(hit)["~="](nil)
		T(hit.entity)["=="](ent)
		T(hit.distance)[">="](0)
		T(hit.distance)["<="](0.0001)
		T(hit.normal.x)[">"](0.9)
		ent:Remove()
	end)
end
