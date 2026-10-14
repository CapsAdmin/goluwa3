local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ViewPriority = import("goluwa/render3d/view_priority.lua")
local HALF_ANGLE = math.rad(55)

local function create(forward)
	local priority = ViewPriority.New()
	priority:Update(Vec3(0, 0, 0), forward or Vec3(0, 0, 1), HALF_ANGLE)
	return priority
end

local function tile(priority, x, z, size)
	return priority:Rank(x, 0, z, x + size, 10, z + size)
end

T.Test("View priority ranks what is in view before what is behind at the same distance", function()
	local priority = create()
	T(tile(priority, -32, 200, 64) < tile(priority, -32, -264, 64))["=="](true)
end)

T.Test("View priority ranks the nearer first inside the view", function()
	local priority = create()
	T(tile(priority, -32, 100, 64) < tile(priority, -32, 400, 64))["=="](true)
end)

T.Test("View priority keeps a tile under the camera first even when it is behind", function()
	local priority = create()
	T(tile(priority, -32, -64, 64))["=="](0)
	T(tile(priority, -32, -64, 64) < tile(priority, -32, 300, 64))["=="](true)
end)

T.Test("View priority counts everything as in view when looking down", function()
	local priority = create(Vec3(0, -1, 0.01))
	local ahead = tile(priority, -32, 200, 64)
	local behind = tile(priority, -32, -264, 64)
	T(math.abs(ahead - behind) < 1e-6)["=="](true)
end)

T.Test("View priority looks ahead along a speed but not past a jump", function()
	local priority = ViewPriority.New()
	local system = import("goluwa/system.lua")
	local elapsed = system.GetElapsedTime()
	priority:Update(Vec3(0, 0, 0), Vec3(0, 0, 1), HALF_ANGLE)
	system.SetElapsedTime(elapsed + 0.1)
	priority:Update(Vec3(0, 0, 100), Vec3(0, 0, 1), HALF_ANGLE)
	T(priority.predicted_z > 100)["=="](true)
	system.SetElapsedTime(elapsed + 0.2)
	priority:Update(Vec3(0, 0, 50000), Vec3(0, 0, 1), HALF_ANGLE)
	T(priority.predicted_z)["=="](50000)
	system.SetElapsedTime(elapsed)
end)
