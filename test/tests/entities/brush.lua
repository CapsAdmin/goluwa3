local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function create_world()
	local entity = Entity.New{Name = "brush_test_world", Parent = Entity.World}
	entity:SetTransient(false)
	entity:AddComponent("transform"):SetPosition(Vec3(5, 6, 7))
	return entity, entity:AddComponent("static_world")
end

T.Test3D("a static world added at runtime stays at the origin and builds the brushes made in it", function()
	local entity, world = create_world()
	T(entity.transform:GetPosition():GetLength())["<"](0.0001)

	T.WaitUntil(function()
		return world.built
	end)

	local Brush = import("goluwa/entities/components/brush.lua")
	local brush_entity = Brush.CreateBox(entity, Vec3(-32, -32, 0), Vec3(32, 32, 64), "dev/dev_measuregeneric01")

	T.WaitUntil(function()
		return world.records[brush_entity.brush] ~= nil
	end)

	T(#world.brush_list)["=="](1)
	entity:Remove()
end)

T.Test3D("a brush is stretched about its center to a size in meters", function()
	local entity = create_world()
	local Brush = import("goluwa/entities/components/brush.lua")
	local brush_entity = Brush.CreateBox(entity, Vec3(-32, -32, 0), Vec3(32, 32, 64), "dev/dev_measuregeneric01")
	local brush = brush_entity.brush
	local size = brush:GetSize()
	T(math.abs(size.x - 64 * 0.01905))["<"](0.0001)
	T(brush:SetSize(Vec3(3, 2, 1)))["=="](true)
	size = brush:GetSize()
	T(math.abs(size.x - 3))["<"](0.001)
	T(math.abs(size.y - 2))["<"](0.001)
	T(math.abs(size.z - 1))["<"](0.001)
	T(#brush.sides)["=="](6)
	local mid_z = 0

	for _, vertex in ipairs(brush:GetVertices()) do
		mid_z = mid_z + vertex.z / 8
	end

	T(math.abs(mid_z - 32))["<"](0.001)
	T(brush.sides[1].texname)["=="]("dev/dev_measuregeneric01")
	entity:Remove()
end)
