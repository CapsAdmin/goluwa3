-- how much of the precipitation's box around the camera the shelter map hides, at several wind speeds: the
-- foliage world with rain (SCENE=debug the wind debug scene, SNOW=1 snow), the shelter map downloaded and every sample
-- point tested as precipitation.lua's is_precipitation_sheltered does.
-- luajit glw --3d --background lua test/harnesses/wind/shelter_check.lua
local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local get_height

if os.getenv("SCENE") == "debug" then
	import("addons/examples/lua/examples/render3d/wind_debug.lua")

	get_height = function()
		return 0
	end
else
	get_height = import("addons/examples/lua/examples/render3d/foliage_world.lua").GetHeight
end

local BOX_SIZE = 20
local SPEEDS = {0, 5, 10, 20, 40}
if os.getenv("SNOW") then weather.SetSnow(5) else weather.SetRain(5) end
local start = system.GetElapsedTime()
local index = 0
local next_time = start + 8

local function measure()
	local map = weather.shelter_map
	local texture = map:GetDepthTexture(1)
	local data = texture:Download()
	local depths = ffi.cast("uint16_t *", data.pixels)
	local w, h = data.width, data.height
	local m = map:GetLightSpaceMatrix(1)
	local camera = render3d.GetCamera():GetPosition()
	local depth_per_meter = math.sqrt(m.m02 ^ 2 + m.m12 ^ 2 + m.m22 ^ 2)
	local sheltered, total, outside = 0, 0, 0
	math.randomseed(1)

	for _ = 1, 4000 do
		local p = camera + Vec3(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * BOX_SIZE

		if p.y > get_height(p.x, p.z) + 0.2 then
			-- the floats as glsl's mat4 reads them, a column is m{c}0..m{c}3
			local x = m.m00 * p.x + m.m10 * p.y + m.m20 * p.z + m.m30
			local y = m.m01 * p.x + m.m11 * p.y + m.m21 * p.z + m.m31
			local z = m.m02 * p.x + m.m12 * p.y + m.m22 * p.z + m.m32
			local ww = m.m03 * p.x + m.m13 * p.y + m.m23 * p.z + m.m33
			local u, v, d = x / ww * 0.5 + 0.5, y / ww * 0.5 + 0.5, z / ww
			total = total + 1

			if u < 0 or u > 1 or v < 0 or v > 1 or d < 0 or d > 1 then
				outside = outside + 1
			else
				local stored = depths[math.min(math.floor(v * h), h - 1) * w + math.min(math.floor(u * w), w - 1)] / 65535

				if stored < d - 0.05 * depth_per_meter then sheltered = sheltered + 1 end
			end
		end
	end

	print(("wind %2d m/s  sheltered %5.1f%%  outside the map %4.1f%%  (%d points above the ground)"):format(SPEEDS[index], sheltered / total * 100, outside / total * 100, total))
end

event.AddListener("Update", "shelter_check", function()
	if system.GetElapsedTime() < next_time then return end

	if index > 0 then measure() end

	index = index + 1

	if not SPEEDS[index] then
		system.ShutDown(0)
		return
	end

	weather.SetWind(Vec3(1, 0, 0.35):GetNormalized() * SPEEDS[index])
	next_time = system.GetElapsedTime() + 2
end)
