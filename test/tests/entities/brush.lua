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

T.Test3D("subtracting a brush splits another into the convex pieces around it", function()
	local Brush = import("goluwa/entities/components/brush.lua")
	local brush_geometry = import("goluwa/source_engine/brush_geometry.lua")
	local entity = create_world()
	local target = Brush.CreateBox(entity, Vec3(0, 0, 0), Vec3(64, 64, 64), "brick/brickwall001a").brush
	local hole = Brush.CreateBox(entity, Vec3(16, -8, 16), Vec3(48, 72, 48), "dev/dev_measuregeneric01").brush
	local apart = Brush.CreateBox(entity, Vec3(100, 0, 0), Vec3(164, 64, 64), "dev/dev_measuregeneric01").brush
	T(math.abs(brush_geometry.GetVolume(target.sides) - 64 ^ 3))["<"](0.5)
	T(brush_geometry.Subtract(target.sides, apart.sides) == nil)["=="](true)
	local pieces = brush_geometry.Subtract(target.sides, hole.sides)
	T(#pieces)["=="](4)
	local volume = 0

	for _, sides in ipairs(pieces) do
		volume = volume + brush_geometry.GetVolume(sides)

		for _, side in ipairs(sides) do
			T(side.texname)["=="]("brick/brickwall001a")
		end
	end

	T(math.abs(volume - (64 ^ 3 - 32 * 64 * 32)))["<"](1)
	entity:Remove()
end)

T.Test3D("carving a door into a wall replaces the wall with the pieces around the door", function()
	local Brush = import("goluwa/entities/components/brush.lua")
	local entity, world = create_world()

	T.WaitUntil(function()
		return world.built
	end)

	local wall = Brush.CreateBox(entity, Vec3(0, 0, 0), Vec3(8, 256, 128), "brick/brickwall001a")
	local door = Brush.CreateBox(entity, Vec3(-8, 96, -8), Vec3(16, 160, 96), "dev/dev_measuregeneric01")
	local results = door.brush:Carve()
	T(#results)["=="](1)
	T(results[1].target == wall)["=="](true)
	T(#results[1].pieces)["=="](3)

	for _, piece in ipairs(results[1].pieces) do
		T(piece:GetParent() == entity)["=="](true)
		T(world.sources[piece.brush])["=="](true)
	end

	entity:Remove()
end)
