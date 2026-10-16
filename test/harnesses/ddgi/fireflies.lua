local pvars = import("goluwa/cli/pvars.lua")
local scene = os.getenv("FLY_SCENE") or "sun"
local out_dir = os.getenv("FLY_OUT") or "tmp/fly/out"
local warm = tonumber(os.getenv("FLY_WARM") or "") or 60
local count = tonumber(os.getenv("FLY_FRAMES") or "") or 40
pvars.SetSession("r_aa", "none")
pvars.SetSession("r_motion_blur", false)
if os.getenv("FLY_AO") == nil then pvars.SetSession("r_pass_ambient_occlusion", false) end
pvars.SetSession("ddgi_debug_gi", os.getenv("FLY_RAW") == nil)

if os.getenv("FLY_DEFAULT_INTERVALS") == nil then
	pvars.SetSession("ddgi_update_interval_max", 1)
end

for k, v in (os.getenv("FLY_PV") or ""):gmatch("(%S+)=(%S+)") do
	local value = tonumber(v)

	if v == "true" then value = true elseif v == "false" then value = false elseif value == nil then value = v end

	pvars.SetSession(k, value)
end

local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Event = import("goluwa/event.lua")
local System = import("goluwa/system.lua")
local View = import("goluwa/render3d/view.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")

local function parse3(str)
	local a, b, c = str:match("([^,]+),([^,]+),([^,]+)")
	return tonumber(a), tonumber(b), tonumber(c)
end

local function box(name, position, size, material)
	return shapes.Box{Name = name, Position = position, Size = size, Material = material, Collision = false, RigidBody = false}
end

local white = shapes.Material{Color = Color(0.8, 0.8, 0.8, 1), Roughness = 0.9, Metallic = 0}
local grey = shapes.Material{Color = Color(0.5, 0.5, 0.5, 1), Roughness = 0.9, Metallic = 0}
local lamp = shapes.Material{
	Color = Color(1, 0.7, 0.4, 1),
	Roughness = 0.9,
	Metallic = 0,
	AlbedoAlphaIsEmissive = true,
	EmissiveMultiplier = Color(1, 1, 1, tonumber(os.getenv("FLY_LAMP") or "") or 40),
}
if scene == "demo" then
	import("addons/examples/lua/examples/render3d/particles_demo.lua")
else
box("ground", Vec3(0, -0.5, 0), Vec3(200, 1, 200), white)

do
	local t, w, h = 0.4, 8, 4
	box("back", Vec3(0, h / 2, -w / 2), Vec3(w + t, h, t), grey)
	box("left", Vec3(-w / 2, h / 2, 0), Vec3(t, h, w), grey)
	box("right", Vec3(w / 2, h / 2, 0), Vec3(t, h, w), grey)
	box("ceiling", Vec3(0, h + t / 2, 0), Vec3(w + t, t, w + t), grey)
	if scene == "slit" then
		-- a 0.2 m gap the sun comes through
		box("front_left", Vec3(-2.1, h / 2, w / 2), Vec3(4, h, t), grey)
		box("front_right", Vec3(2.1, h / 2, w / 2), Vec3(4, h, t), grey)
	else
		box("front_left", Vec3(-2.4, h / 2, w / 2), Vec3(3.2, h, t), grey)
		box("front_right", Vec3(2.4, h / 2, w / 2), Vec3(3.2, h, t), grey)
		box("front_top", Vec3(0, 3.1, w / 2), Vec3(1.6, 1.8, t), grey)
	end
	box("pillar", Vec3(-1.5, 1, -1), Vec3(0.8, 2, 0.8), white)
end

end

if scene == "lamp" then
	box("lamp", Vec3(1.5, 0.15, -2), Vec3(0.2, 0.2, 0.2), lamp)
end

for _, light in ipairs(scene == "demo" and {} or render3d.GetLights()) do
	if light.Type == "light_sun" then
		light.Owner.transform:SetRotation(scene == "lamp" and QuatDeg3(80, 0, 0) or QuatDeg3(-40, 0, 0))
	end
end

View.New{
	Priority = 100,
	HideAvatars = true,
	Position = Vec3(parse3(os.getenv("FLY_POS") or "-3.4,3.4,-3.4")),
	Rotation = QuatDeg3(parse3(os.getenv("FLY_ANG") or "-30,-135,0")),
	FOV = math.rad(85),
	ExposureLock = tonumber(os.getenv("FLY_EV") or "") or (scene == "lamp" and 9 or scene == "slit" and 11 or 13),
}:Activate()
os.execute("mkdir -p " .. out_dir)
local frame = 0
local saved = 0
Event.AddListener("Update", "fly", function()
	frame = frame + 1

	if frame > warm and saved < count then
		local index = saved
		saved = saved + 1
		Screenshot(function(texture)
			texture:SaveWithoutAlpha(string.format("%s/f%03d.png", out_dir, index))

			if index == count - 1 then
				logf("[fly] saved %d frames to %s\n", count, out_dir)
				System.ShutDown(0)
			end
		end, {update_events = 0})
	end
end)
