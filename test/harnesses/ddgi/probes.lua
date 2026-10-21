-- dumps the probes of one cascade of the gi_reflections scene around a point as a top down slice (rows are z, columns x):
-- mean irradiance luma of each probe (dots are disabled or not written probes). PRB_POS "x,y,z" (the room's centre), PRB_RADIUS cells (8),
-- PRB_CASCADE (0), PRB_WARM frames (400), PRB_PV "pvar=value ..."
local pvars = import("goluwa/cli/pvars.lua")
local Event = import("goluwa/event.lua")
local System = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local View = import("goluwa/render3d/view.lua")
local weather = import("goluwa/render3d/weather.lua")
pvars.SetSession("r_aa", "none")

for k, v in (os.getenv("PRB_PV") or ""):gmatch("(%S+)=(%S+)") do
	local value = tonumber(v)

	if v == "true" then value = true elseif v == "false" then value = false elseif value == nil then value = v end

	pvars.SetSession(k, value)
end

local x, y, z = (os.getenv("PRB_POS") or "-40,2,-100"):match("([^,]+),([^,]+),([^,]+)")
x, y, z = tonumber(x), tonumber(y), tonumber(z)
local radius = tonumber(os.getenv("PRB_RADIUS") or "") or 8
local cascade_index = tonumber(os.getenv("PRB_CASCADE") or "") or 0
local warm = tonumber(os.getenv("PRB_WARM") or "") or 400
if os.getenv("GIR_LUA") then assert(loadstring(os.getenv("GIR_LUA")))() end
import(os.getenv("GIR_SCENE") or "addons/examples/lua/examples/render3d/gi_reflections.lua")
weather.SetSunRotation(Quat(-0.480592, 0.157274, -0.157274, 0.848269))
View.New{Priority = 100, HideAvatars = true, Position = Vec3(x, y, z), Rotation = Quat():SetAngles(import("goluwa/structs/ang3.lua")(0, 0, 0)), FOV = 1.5, ExposureLock = 9}:Activate()
local frame = 0
Event.AddListener("Update", "prb", function()
	frame = frame + 1

	if frame ~= warm then return end

	local state = ddgi.GetFrameState()
	local c = state.cascades[cascade_index + 1]
	local data = render3d.pipelines.ddgi_probe_data:GetFramebuffer(1):GetAttachment(1):Download()
	local irr = render3d.pipelines.ddgi_irradiance:GetFramebuffer(1):GetAttachment(1):Download()
	local P = ddgi.PROBES_PER_AXIS
	print(string.format("cascade %d spacing %.3f base %d %d %d size %d %d %d count %d", cascade_index, c.spacing, c.x, c.y, c.z, c.size.x, c.size.y, c.size.z, state.cascade_count))
	local cy = math.floor(y / c.spacing + 0.5)

	local function wrap(v, n) return ((v % n) + n) % n end

	for dy = -1, 1 do
		local wy = cy + dy
		print(string.format("-- y = %.2f", wy * c.spacing))

		for wz = math.floor(z / c.spacing) - radius, math.floor(z / c.spacing) + radius do
			local row = {}

			for wx = math.floor(x / c.spacing) - radius, math.floor(x / c.spacing) + radius do
				local sx, sy, sz = wrap(wx, c.size.x), wrap(wy, c.size.y), wrap(wz, c.size.z)
				local index = sx + c.size.x * (sy + c.size.y * sz)
				local tx, ty = index % (P * P), math.floor(index / (P * P)) + P * cascade_index
				local r, g, b, w = data:GetPixelFloat(tx, ty)
				local flags = math.floor((w - 1) * 0.5)
				local disabled = flags >= 2 and math.floor(flags / 2) % 2 == 1 or (flags >= 4)
				local sum, n = 0, 0

				for j = 1, 6 do
					for i = 1, 6 do
						local ir, ig, ib = irr:GetPixelFloat(tx * 8 + i, ty * 8 + j)
						sum = sum + (ir + ig + ib) / 3
						n = n + 1
					end
				end

				local luma = sum / n
				local current = w >= 1 and math.floor(r + 0.5) == wx and math.floor(g + 0.5) == wy and math.floor(b + 0.5) == wz
				if os.getenv("PRB_INFO") then
					local oz = (b - wz) * c.spacing
					row[#row + 1] = (not current) and "?" or string.format("%s%.0f/%.2f/%+.2f", flags >= 2 and "D" or "", luma, w - 1 - 2 * flags, oz)
				else
					row[#row + 1] = (not current) and "  ?  " or (flags >= 2 and "  .  " or string.format("%5.2f", luma))
				end
			end

			print(string.format("z%7.2f ", wz * c.spacing) .. table.concat(row, " "))
		end
	end

	System.ShutDown(0)
end)
