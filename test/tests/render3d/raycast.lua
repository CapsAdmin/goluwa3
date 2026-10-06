local T = import("test/environment.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local AABB = import("goluwa/structs/aabb.lua")

do
	local function get_local_aabb(model)
		return model.AABB
	end

	local function get_render_entries(model)
		return model.Primitives
	end

	local function make_model(ent, poly, world_offset)
		local aabb = poly.AABB
		local model = {
			Owner = ent,
			Visible = true,
			AABB = aabb,
			GetAABB = get_local_aabb,
			GetRenderEntries = get_render_entries,
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
		else
			model.GetWorldAABB = get_local_aabb
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
		shapes.BuildCube(poly, 0.5, 1)
		poly:BuildBoundingBox()
		return ent, poly
	end

	T.Test("Raycast basic triangle hit", function()
		local ent = Entity.New({Name = "test_triangle"})
		ent:AddComponent("transform")
		local poly = make_triangle(Vec3(0, 0, 1))
		local source = make_source{make_model(ent, poly)}
		local hits = raycast.CastFromSource(source, Vec3(0, 0, 2), Vec3(0, 0, -1), 10)
		T(#hits)["=="](1)
		T(hits[1].entity)["=="](ent)
		T(hits[1].distance)[">="](1.9)
		T(hits[1].distance)["<="](2.1)
		ent:Remove()
	end)

	T.Test("Raycast miss", function()
		local ent = Entity.New({Name = "test_triangle"})
		ent:AddComponent("transform")
		local poly = make_triangle(Vec3(0, 0, -1))
		local source = make_source{make_model(ent, poly)}
		local origin = Vec3(0, 0, -2)
		local direction = Vec3(1, 0, 0)
		local hits = raycast.CastFromSource(source, origin, direction, 10)
		T(#hits)["=="](0)
		ent:Remove()
	end)

	T.Test("Raycast cube", function()
		local ent = Entity.New({Name = "test_cube"})
		ent:AddComponent("transform")
		local poly = Polygon3D.New()
		shapes.BuildCube(poly, 1, 1)
		poly:BuildBoundingBox()
		local source = make_source{make_model(ent, poly)}
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

	T.Test("Raycast with transform", function()
		local ent = Entity.New({Name = "test_triangle"})
		ent:AddComponent("transform")
		local position = Vec3(5, 0, 0)
		ent.transform:SetPosition(position)
		local poly = make_triangle(Vec3(0, 0, -1))
		local source = make_source{make_model(ent, poly, position)}
		local hits1 = raycast.CastFromSource(source, Vec3(0, 0, -2), Vec3(0, 0, 1), 10)
		T(#hits1)["=="](0)
		local hits2 = raycast.CastFromSource(source, Vec3(5, 0, -2), Vec3(0, 0, 1), 10)
		T(#hits2)["=="](1)
		T(hits2[1].entity)["=="](ent)
		ent:Remove()
	end)

	T.Test("Raycast multiple entities", function()
		local ent1, poly1 = make_cube_entity("cube1", Vec3(0, 0, 0))
		local ent2, poly2 = make_cube_entity("cube2", Vec3(0, 0, 3))
		local source = make_source{
			make_model(ent1, poly1),
			make_model(ent2, poly2, Vec3(0, 0, 3)),
		}
		local origin = Vec3(0, 0, -5)
		local direction = Vec3(0, 0, 1)
		local hits = raycast.CastFromSource(source, origin, direction, 20)
		T(#hits)["=="](2)
		T(hits[1].entity)["=="](ent1)
		T(hits[2].entity)["=="](ent2)
		T(hits[1].distance)["<"](hits[2].distance)
		ent1:Remove()
		ent2:Remove()
	end)

	T.Test("Raycast with filter", function()
		local ent1, poly1 = make_cube_entity("include_me", Vec3(0, 0, 0))
		local ent2, poly2 = make_cube_entity("exclude_me", Vec3(0, 0, 3))
		local source = make_source{
			make_model(ent1, poly1),
			make_model(ent2, poly2, Vec3(0, 0, 3)),
		}
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
		T(#hits)["=="](1)
		T(hits[1].entity)["=="](ent1)
		ent1:Remove()
		ent2:Remove()
	end)

	T.Test("Raycast CastClosest", function()
		local ent = Entity.New({Name = "test_cube"})
		ent:AddComponent("transform")
		local poly = Polygon3D.New()
		shapes.BuildCube(poly, 1, 1)
		poly:BuildBoundingBox()
		local source = make_source{make_model(ent, poly)}
		local hit = raycast.CastClosestFromSource(source, Vec3(0, 0, -5), Vec3(0, 0, 1), 10)
		T(hit)["~="](nil)
		T(hit.entity)["=="](ent)
		ent:Remove()
	end)

	T.Test("Raycast CastAny", function()
		local ent = Entity.New({Name = "test_cube"})
		ent:AddComponent("transform")
		local poly = Polygon3D.New()
		shapes.BuildCube(poly, 1, 1)
		poly:BuildBoundingBox()
		local source = make_source{make_model(ent, poly)}
		local hit = raycast.CastClosestFromSource(source, Vec3(0, 0, -5), Vec3(0, 0, 1), 10)
		T(hit ~= nil)["=="](true)
		local miss = raycast.CastClosestFromSource(source, Vec3(10, 0, -5), Vec3(0, 0, 1), 10)
		T(miss == nil)["=="](true)
		ent:Remove()
	end)

	T.Test("Raycast ground normal faces ray", function()
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

	T.Test("Raycast custom model source", function()
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
				GetWorldAABB = get_local_aabb,
				GetAABB = get_local_aabb,
				GetRenderEntries = get_render_entries,
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

	T.Test("Raycast convex brush primitive source", function()
		local ent = Entity.New({Name = "test_brush_source"})
		ent:AddComponent("transform")
		local source = raycast.CreateModelSource{
			{
				Owner = ent,
				Visible = true,
				WorldSpaceVertices = true,
				GetWorldAABB = get_local_aabb,
				GetAABB = get_local_aabb,
				GetRenderEntries = get_render_entries,
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

	T.Test("Raycast convex brush immediate inside hit", function()
		local ent = Entity.New({Name = "test_brush_inside"})
		ent:AddComponent("transform")
		local source = raycast.CreateModelSource{
			{
				Owner = ent,
				Visible = true,
				WorldSpaceVertices = true,
				GetWorldAABB = get_local_aabb,
				GetAABB = get_local_aabb,
				GetRenderEntries = get_render_entries,
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

T.Test3D("Raycast hits real visual meshes from outside but not their back faces", function()
	local box = shapes.Box{Position = Vec3(0, 0, 0), Size = Vec3(2, 2, 2), RigidBody = false}
	local outside = raycast.CastClosest(Vec3(0, 0, 10), Vec3(0, 0, -1), 100)
	T(outside ~= nil)["=="](true)
	T(outside.entity)["=="](box)
	T(math.abs(outside.distance - 9))["<"](0.001)
	local inside = raycast.CastClosest(Vec3(0, 0, 0), Vec3(0, 0, -1), 100)
	T(inside)["=="](nil)
	box:Remove()
end)

T.Test3D("Raycast reads one based polygon indices", function()
	local poly = Polygon3D.New()

	for _, x in ipairs{0, 10, 20} do
		poly:AddVertex{pos = Vec3(x - 1, -1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)}
		poly:AddVertex{pos = Vec3(x + 1, -1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)}
		poly:AddVertex{pos = Vec3(x, 1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)}
	end

	poly.indices = {7, 8, 9, 1, 2, 3, 4, 5, 6}
	poly:BuildBoundingBox()
	local ent = Entity.New({Name = "indexed"})
	ent:AddComponent("transform")
	local source = raycast.CreateModelSource{
		{
			Owner = ent,
			Visible = true,
			AABB = poly.AABB,
			GetWorldAABB = function()
				return poly.AABB
			end,
			GetAABB = function()
				return poly.AABB
			end,
			GetRenderEntries = function(self)
				return self.Primitives
			end,
			Primitives = {{polygon3d = poly, aabb = poly.AABB}},
		},
	}

	for _, x in ipairs{0, 10, 20} do
		local hit = raycast.CastClosestFromSource(source, Vec3(x, 0, 5), Vec3(0, 0, -1), 20)
		T(hit ~= nil)["=="](true)
		T(math.abs(hit.distance - 5))["<"](0.001)
	end

	T(raycast.CastClosestFromSource(source, Vec3(5, 0, 5), Vec3(0, 0, -1), 20))["=="](nil)
	ent:Remove()
end)
