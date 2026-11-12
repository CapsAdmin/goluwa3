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
