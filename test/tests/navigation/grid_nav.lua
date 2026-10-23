local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local GridNav = import("goluwa/navigation/grid_nav.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function create_box(x1, y1, z1, x2, y2, z2, world)
	return Entity.New{
		transform = {
			Position = Vec3((x1 + x2) / 2, (y1 + y2) / 2, (z1 + z2) / 2),
			Scale = Vec3(x2 - x1, y2 - y1, z2 - z1),
		},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = world,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
end

local function create_nav()
	return GridNav.New(0.3, 1.4, 0.35, 1.2)
end

T.TestPhysics("grid nav walks a straight line over flat ground", function()
	create_box(-20, -1, -20, 20, 0, 20, true)
	local path = create_nav():FindPath(Vec3(0, 0, 0), Vec3(10, 0, 0))
	T(path.complete)["=="](true)

	for _, point in ipairs(path.points) do
		T(math.abs(point.z) < 1e-6)["=="](true)
	end

	T(math.abs(path.length - 10) < 0.6)["=="](true)
	T(math.abs(path.points[#path.points].x - 10) < 1e-6)["=="](true)
end)

T.TestPhysics("grid nav goes around a wall in the world", function()
	create_box(-20, -1, -20, 20, 0, 20, true)
	create_box(4.8, 0, -4, 5.2, 2, 4, true)
	local path = create_nav():FindPath(Vec3(0, 0, 0), Vec3(10, 0, 0))
	T(path.complete)["=="](true)
	local widest = 0

	for _, point in ipairs(path.points) do
		widest = math.max(widest, math.abs(point.z))
	end

	T(widest > 4)["=="](true)
	T(path.length < 20)["=="](true)
end)

T.TestPhysics("grid nav goes around a rigid body that is not world geometry and forgets it when it is gone", function()
	create_box(-20, -1, -20, 20, 0, 20, true)
	local wall = create_box(4.8, 0, -4, 5.2, 2, 4, false)
	local nav = create_nav()
	local blocked = nav:FindPath(Vec3(0, 0, 0), Vec3(10, 0, 0))
	T(blocked.complete)["=="](true)
	T(blocked.length > 12)["=="](true)
	wall:Remove()
	local open = nav:FindPath(Vec3(0, 0, 0), Vec3(10, 0, 0))
	T(math.abs(open.length - 10) < 0.6)["=="](true)
end)

T.TestPhysics("grid nav climbs steps but not walls and does not walk off ledges", function()
	create_box(-20, -1, -20, 20, 0, 20, true)
	create_box(3, 0, -20, 20, 0.3, 20, true)
	create_box(8, 0, -20, 20, 3, 20, true)
	local nav = create_nav()
	local path = nav:FindPath(Vec3(0, 0, 0), Vec3(6, 0.3, 0))
	T(path.complete)["=="](true)
	T(math.abs(path.points[#path.points].y - 0.3) < 0.05)["=="](true)
	local wall = nav:FindPath(Vec3(0, 0, 0), Vec3(12, 3, 0))
	T(wall.complete)["=="](false)
end)

T.TestPhysics("grid nav knows a goal on a separate island is unreachable", function()
	create_box(0, -1, 0, 10, 0, 10, true)
	create_box(20, -1, 0, 30, 0, 10, true)
	local path = create_nav():FindPath(Vec3(2, 0, 2), Vec3(25, 0, 5))
	T(path.complete)["=="](false)
	T(path.exhausted)["=="](true)
end)

T.TestPhysics("grid nav avoids cells that are blocked", function()
	create_box(-20, -1, -20, 20, 0, 20, true)
	local nav = create_nav()
	local blocked = {}

	for iz = -8, 8 do
		blocked[GridNav.ColumnKey(10, iz)] = true
	end

	local around = nav:FindPath(Vec3(0, 0, 0), Vec3(10, 0, 0), nil, blocked)
	T(around.complete)["=="](true)
	T(around.length > 12)["=="](true)
	local goal = nav:FindPath(Vec3(0, 0, 0), Vec3(10, 0, 0), nil, {[GridNav.ColumnKey(20, 0)] = true})
	T(goal.complete)["=="](false)
end)

T.TestPhysics("grid nav finds the same path in slices as in one go", function()
	create_box(-20, -1, -20, 20, 0, 20, true)
	create_box(4.8, 0, -4, 5.2, 2, 4, true)
	local nav = create_nav()
	local whole = nav:FindPath(Vec3(0, 0, 0), Vec3(10, 0, 0))
	nav:Invalidate()
	local search = nav:BeginSearch(Vec3(0, 0, 0), Vec3(10, 0, 0))
	local slices = 0

	while not nav:Step(search, 0) do
		slices = slices + 1
	end

	T(slices > 1)["=="](true)
	T(search.path.complete)["=="](true)
	T(math.abs(search.path.length - whole.length) < 1e-6)["=="](true)
end)

T.TestPhysics("grid nav gives random points on the ground", function()
	create_box(-20, -1, -20, 20, 0, 20, true)
	local nav = create_nav()

	for _ = 1, 10 do
		local point = nav:GetRandomPoint(Vec3(0, 1, 0), 10, 4)
		T(point ~= nil)["=="](true)
		T(math.abs(point.y) < 0.01)["=="](true)
		T(math.sqrt(point.x ^ 2 + point.z ^ 2) <= 10.001)["=="](true)
	end
end)
