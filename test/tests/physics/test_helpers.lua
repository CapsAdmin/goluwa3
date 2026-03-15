local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local module = {}

function module.SimulatePhysics(physics, steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

function module.CreateFlatGround(name, extent)
	extent = extent or 8
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-extent, 0, -extent), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, extent), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(extent, 0, -extent), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	return ground
end

function module.AddTriangle(poly, a, b, c)
	poly:AddVertex{pos = a, uv = Vec2(0, 0)}
	poly:AddVertex{pos = b, uv = Vec2(1, 0)}
	poly:AddVertex{pos = c, uv = Vec2(0.5, 1)}
end

function module.CreateMockBody(data)
	data = data or {}
	return {
		GetMass = function()
			return data.Mass or 0
		end,
		GetDensity = function()
			return data.Density or 0
		end,
		GetAutomaticMass = function()
			return data.AutomaticMass == true
		end,
		IsDynamic = function()
			if data.IsDynamic ~= nil then return data.IsDynamic end

			return true
		end,
	}
end

return module