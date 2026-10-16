-- DDGI validation scenes, run through validate_run.sh. VAL_SCENE picks one, everything else is the engine's defaults:
-- GI-only view, no AA, no motion blur, real update intervals. After VAL_WAIT seconds (5) it saves VAL_FRAMES (12)
-- consecutive frames to VAL_OUT/f000.png and on.
--   slit      small room, sun through a 0.2 m gap       (boiling: a and b should match)
--   door      small room, sun through a door            (boiling)
--   emitters  sealed room, no sun, tiny emissive cubes  (boiling, and they must light the room)
--   crystals  sealed room, no sun, 1 cm very bright emitters spread over the walls like the esther cave crystals
--   seal_box  sealed room of thick boxes, sun outside   (leak: the inside must stay dark)
--   seal_plane  same with 2 cm walls (single plane like)
--   seal_lights sealed room of thick boxes, point lights around it outside
local pvars = import("goluwa/cli/pvars.lua")
local scene = os.getenv("VAL_SCENE") or "slit"
local out_dir = os.getenv("VAL_OUT") or ("tmp/val/" .. scene)
local wait = tonumber(os.getenv("VAL_WAIT") or "") or 5
pvars.SetSession("r_aa", "none")
pvars.SetSession("r_motion_blur", false)
pvars.SetSession("r_pass_ambient_occlusion", false)
pvars.SetSession("ddgi_debug_gi", true)

for k, v in (os.getenv("VAL_PV") or ""):gmatch("(%S+)=(%S+)") do
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
local weather = import("goluwa/render3d/weather.lua")

local function box(name, position, size, material)
	return shapes.Box{Name = name, Position = position, Size = size, Material = material, Collision = false, RigidBody = false}
end

local white = shapes.Material{Color = Color(0.8, 0.8, 0.8, 1), Roughness = 0.9, Metallic = 0}
local grey = shapes.Material{Color = Color(0.5, 0.5, 0.5, 1), Roughness = 0.9, Metallic = 0}
local emissive = shapes.Material{
	Color = Color(1, 0.7, 0.4, 1),
	Roughness = 0.9,
	Metallic = 0,
	AlbedoAlphaIsEmissive = true,
	EmissiveMultiplier = Color(1, 1, 1, 40),
}
box("ground", Vec3(0, -0.5, 0), Vec3(200, 1, 200), white)

-- a room 8 x 8 x 4 m, walls t thick, openings cut by leaving the front wall in pieces
local function room(t, front)
	local w, h = 8, 4
	-- the pieces overlap each other and the ground, so the room has no cracks
	box("back", Vec3(0, h / 2, -w / 2), Vec3(w + 2 * t, h, t), grey)
	box("left", Vec3(-w / 2, h / 2, 0), Vec3(t, h, w + 2 * t), grey)
	box("right", Vec3(w / 2, h / 2, 0), Vec3(t, h, w + 2 * t), grey)
	box("ceiling", Vec3(0, h, 0), Vec3(w + 2 * t, t, w + 2 * t), grey)

	if front == "slit" then
		box("front_left", Vec3(-2.1, h / 2, w / 2), Vec3(3.8, h, t), grey)
		box("front_right", Vec3(2.1, h / 2, w / 2), Vec3(3.8, h, t), grey)
	elseif front == "door" then
		box("front_left", Vec3(-2.4, h / 2, w / 2), Vec3(3.2, h, t), grey)
		box("front_right", Vec3(2.4, h / 2, w / 2), Vec3(3.2, h, t), grey)
		box("front_top", Vec3(0, 3.1, w / 2), Vec3(1.6, 1.8, t), grey)
	else
		box("front", Vec3(0, h / 2, w / 2), Vec3(w + 2 * t, h, t), grey)
	end
end

local sun_pitch = -40


if scene == "slit" then
	room(0.4, "slit")
elseif scene == "daynight" then
	room(0.4, "door")
elseif scene == "door" then
	room(0.4, "door")
elseif scene == "emitters" then
	room(0.4, "closed")
	sun_pitch = 80

	for i = 1, 6 do
		box("emitter" .. i, Vec3(-3 + i, 0.1 + (i % 3) * 0.4, -2 + (i % 2) * 3), Vec3(0.1, 0.1, 0.1), emissive)
	end
elseif scene == "crystals" then
	room(0.4, "closed")
	sun_pitch = 80
	local crystal = shapes.Material{
		Color = Color(0.4, 0.8, 1, 1),
		Roughness = 0.5,
		Metallic = 0,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, tonumber(os.getenv("VAL_CRYSTAL") or "") or 40000),
	}
	math.randomseed(7)

	for i = 1, 60 do
		local side = i % 4
		local u, v = math.random() * 7 - 3.5, 0.3 + math.random() * 3.4
		local p = side == 0 and Vec3(u, v, -3.75) or side == 1 and Vec3(u, v, 3.75) or side == 2 and Vec3(-3.75, v, u) or Vec3(3.75, v, u)
		box("crystal" .. i, p, Vec3(0.01, 0.01, 0.01), crystal)
	end
elseif scene == "seal_box" then
	room(0.4, "closed")
elseif scene == "seal_plane" then
	room(tonumber(os.getenv("VAL_T") or "") or 0.02, "closed")
elseif scene == "seal_lights" then
	room(0.4, "closed")
	sun_pitch = 80

	for i, p in ipairs{Vec3(0, 2, 7), Vec3(0, 2, -7), Vec3(7, 2, 0), Vec3(-7, 2, 0), Vec3(0, 6, 0)} do
		local ent = Entity.New{Name = "outside_light" .. i}
		ent:AddComponent("transform")
		ent.transform:SetPosition(p)
		local c = ent:AddComponent("light_point")
		c:SetColor(Color(1, 0.9, 0.8, 1))
		c:SetLumen(20000)
		c:SetRange(12)
	end
end

for _, light in ipairs(render3d.GetLights()) do
	if light.Type == "light_sun" then
		light.Owner.transform:SetRotation(QuatDeg3(sun_pitch, 0, 0))
	end
end

View.New{
	Priority = 100,
	HideAvatars = true,
	Position = Vec3(-3.4, 3.4, -3.4),
	Rotation = QuatDeg3(-30, -135, 0),
	FOV = math.rad(85),
	ExposureLock = tonumber(os.getenv("VAL_EV") or "") or (sun_pitch == 80 and 9 or 11),
}:Activate()
os.execute("mkdir -p " .. out_dir)
local frames = tonumber(os.getenv("VAL_FRAMES") or "") or 12
local stride = tonumber(os.getenv("VAL_STRIDE") or "") or 1
local saved = 0
local last_frame = -1000
local flipped = false

Event.AddListener("Update", "ddgi_validate", function()
	local now = System.GetElapsedTime()

	-- daynight: the sun goes under the horizon at VAL_WAIT and the frames that follow show how fast the gi follows
	if scene == "daynight" and not flipped and now >= wait then
		flipped = true

		import("goluwa/render3d/directional_shadows.lua").GetPrimarySun(render3d.GetLights()).Owner.transform:SetRotation(QuatDeg3(80, 0, 0))
	end

	if now < wait or saved >= frames or System.GetFrameNumber() < last_frame + stride then return end

	last_frame = System.GetFrameNumber()
	local index = saved
	saved = saved + 1
	Screenshot(function(texture)
		texture:SaveWithoutAlpha(string.format("%s/f%03d.png", out_dir, index))

		if index == frames - 1 then System.ShutDown(0) end
	end, {update_events = 0})
end)
