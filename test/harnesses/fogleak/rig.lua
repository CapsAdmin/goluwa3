local Shot = import("goluwa/render3d/shot.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
import("test/harnesses/fogleak/hall.lua")
local ev = tonumber(os.getenv("EV") or 8)
local positions = {}

for z in (os.getenv("ZS") or "-1,-30,-60,-75"):gmatch("[^,]+") do
	positions[#positions + 1] = tonumber(z)
end

local y = tonumber(os.getenv("CAM_Y") or 6)
local pitch = tonumber(os.getenv("PITCH") or 0)
local yaw = tonumber(os.getenv("YAW") or 0)
local x = tonumber(os.getenv("CAM_X") or 0)
local list, densities = {}, {}

for _, z in ipairs(positions) do
	for _, d in ipairs{0, 0.5} do
		list[#list + 1] = {Position = Vec3(x, y, z), Rotation = QuatDeg3(pitch, yaw, 0), ExposureLock = ev}
		densities[#densities + 1] = d
	end
end

local function mean(tex, x0, y0, x1, y1)
	local s, n = 0, 0

	for py = y0, y1, 8 do
		for px = x0, x1, 8 do
			local r, g, b = tex:GetPixel(px, py)
			s = s + r + g + b
			n = n + 3
		end
	end

	return s / n
end

local prev
atmosphere.fog_density = densities[1]

Shot.Sequence(
	list,
	function(tex, info, i)
		local w, h = tex.width, tex.height
		local center = mean(
			tex,
			math.floor(w * 0.45),
			math.floor(h * 0.2),
			math.floor(w * 0.55),
			math.floor(h * 0.5)
		)
		local all = mean(tex, 0, 0, w - 1, h - 1)
		local tag = string.format("z%d_d%s", list[i].Position.z, densities[i])
		tex:SaveWithoutAlpha("test/harnesses/fogleak/rig_" .. tag .. ".png")
		print(string.format("RIG %-12s center %6.2f all %6.2f", tag, center, all))

		if densities[i + 1] then atmosphere.fog_density = densities[i + 1] end
	end,
	{settle = tonumber(os.getenv("SETTLE") or 3)},
	function()
		system.ShutDown(0)
	end
)
