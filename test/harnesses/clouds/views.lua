local system = import("goluwa/system.lua")
local Shot = import("goluwa/render3d/shot.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local views = {}

for v in (os.getenv("VIEWS") or "0,2,0,15,0"):gmatch("[^;]+") do
	local x, y, z, p, yw, fov = v:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),?([^,]*)")
	views[#views + 1] = {
		Position = Vec3(tonumber(x), tonumber(y), tonumber(z)),
		Rotation = QuatDeg3(tonumber(p), tonumber(yw), 0),
		FOV = math.rad(tonumber(fov) or 80),
		ExposureLock = tonumber(os.getenv("EV") or ""),
	}
end

local out = os.getenv("OUT") or "test/harnesses/clouds/v"
local i = 0

Shot.Sequence(
	views,
	function(texture, info)
		i = i + 1
		print(texture:SaveWithoutAlpha(out .. i .. ".png"))
	end,
	{settle = tonumber(os.getenv("SETTLE") or 2)},
	function()
		system.ShutDown(0)
	end
)
