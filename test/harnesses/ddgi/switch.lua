-- how fast the gi follows a local light switching off and on. A closed room (thick walls) with one point light and a sun
-- below the horizon. The light goes off at SW_OFF frames and on again at SW_ON, the mean of the gi texture is printed every 6
-- frames (percent of the lit level) and the frames until it is within 10 percent of the new level.
-- env: SW_PV "pvar=value ...", SW_OFF (600), SW_ON (1200), SW_END (1800)
local pvars = import("goluwa/cli/pvars.lua")
pvars.SetSession("r_aa", "none")
pvars.SetSession("r_motion_blur", false)
pvars.SetSession("ddgi_debug_gi", true)

for k, v in (os.getenv("SW_PV") or ""):gmatch("(%S+)=(%S+)") do
	local value = tonumber(v)

	if v == "true" then value = true elseif v == "false" then value = false elseif value == nil then value = v end

	pvars.SetSession(k, value)
end

local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local Event = import("goluwa/event.lua")
local System = import("goluwa/system.lua")
local View = import("goluwa/render3d/view.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local off_frame = tonumber(os.getenv("SW_OFF") or "") or 600
local on_frame = tonumber(os.getenv("SW_ON") or "") or 1200
local end_frame = tonumber(os.getenv("SW_END") or "") or 1800
local grey = shapes.Material{Color = Color(0.5, 0.5, 0.5, 1), Roughness = 0.9, Metallic = 0}

local function box(name, position, size)
	return shapes.Box{Name = name, Position = position, Size = size, Material = grey, Collision = false, RigidBody = false}
end

local t, w, h = 0.4, 8, 4
box("ground", Vec3(0, -0.5, 0), Vec3(200, 1, 200))
box("back", Vec3(0, h / 2, -w / 2), Vec3(w + 2 * t, h, t))
box("front", Vec3(0, h / 2, w / 2), Vec3(w + 2 * t, h, t))
box("left", Vec3(-w / 2, h / 2, 0), Vec3(t, h, w + 2 * t))
box("right", Vec3(w / 2, h / 2, 0), Vec3(t, h, w + 2 * t))
box("ceiling", Vec3(0, h, 0), Vec3(w + 2 * t, t, w + 2 * t))
box("pillar", Vec3(-1.5, 1, -1), Vec3(0.8, 2, 0.8))

for _, light in ipairs(render3d.GetLights()) do
	if light.Type == "light_sun" then light.Owner.transform:SetRotation(QuatDeg3(80, 0, 0)) end
end

local lamp = Entity.New{Name = "switch_lamp"}
lamp:AddComponent("transform")
lamp.transform:SetPosition(Vec3(1.5, 2.5, 1))
local light = lamp:AddComponent("light_point")
light:SetLumen(3000)
light:SetColor(Color(1, 0.9, 0.8, 1))
light:SetRange(12)
View.New{Priority = 100, HideAvatars = true, Position = Vec3(-3.4, 3.4, -3.4), Rotation = QuatDeg3(-30, -135, 0), FOV = math.rad(85), ExposureLock = 9}:Activate()
local frame = 0
local values = {}

local function mean()
	local downloaded = ddgi.GetScreenTexture():Download()
	local sum, count = 0, 0

	for y = 0, downloaded.height - 1, 8 do
		for x = 0, downloaded.width - 1, 8 do
			local r, g, b = downloaded:GetPixelFloat(x, y)
			sum = sum + (r + g + b) / 3
			count = count + 1
		end
	end

	return sum / count
end

Event.AddListener("Update", "sw", function()
	frame = frame + 1

	if frame == off_frame then light:SetLumen(0) end

	if frame == on_frame then light:SetLumen(3000) end

	if frame >= off_frame - 60 and frame % 6 == 0 then values[#values + 1] = {frame, mean(), System.GetTime()} end

	if frame >= end_frame then
		local lit = values[1][2]
		local off_level, on_level
		-- the level just before the switch and the level at its end
		for _, v in ipairs(values) do
			if v[1] == on_frame - 6 then off_level = v[2] end
		end
		on_level = values[#values][2]
		local function settle(from, to, start_frame, stop_frame)
			local last_bad = start_frame

			for _, v in ipairs(values) do
				if v[1] >= start_frame and v[1] < stop_frame and math.abs(v[2] - to) > 0.1 * math.abs(from - to) then last_bad = v[1] end
			end

			local t0, t1
			for _, v in ipairs(values) do
				if v[1] == start_frame then t0 = v[3] end
				if v[1] == last_bad then t1 = v[3] end
			end
			return (t1 or t0) - t0, last_bad - start_frame + 6
		end
		local off_seconds, off_frames = settle(lit, off_level, off_frame, on_frame)
		local on_seconds, on_frames = settle(off_level, on_level, on_frame, end_frame)
		print(string.format("SWITCH lit=%.3f off=%.3f  off settles in %.2f s (%d frames), on settles in %.2f s (%d frames), %.0f fps", lit, off_level, off_seconds, off_frames, on_seconds, on_frames, (end_frame - off_frame) / (values[#values][3] - values[1][3] + 1e-9) * 0 + (#values * 6) / (values[#values][3] - values[1][3])))
		local line = {}
		for _, v in ipairs(values) do
			if v[1] >= off_frame and v[1] < off_frame + 300 and (v[1] - off_frame) % 30 == 0 then line[#line + 1] = string.format("%d", 100 * v[2] / lit) end
		end
		print("SWITCH off curve (percent of lit, every 30 frames): " .. table.concat(line, " "))
		System.ShutDown(0)
	end
end)
