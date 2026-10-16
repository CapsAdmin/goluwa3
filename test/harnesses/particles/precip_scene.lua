-- rain or snow in a yard: a hut with a roof and a door, a lamp, a post to look at it from
-- luajit glw --3d --background --validate lua "import('test/harnesses/particles/precip_scene.lua')"
-- KIND=rain|snow|none RATE=10 ELEVATION=35 (sun, negative is night) LAMP=1 GI=1 EV=14 SETTLE=4 WIND=0,0,0
-- OUT=tmp/shots/precip.png VIEWS=yard,hut,up (comma list)
local test_scene = import("goluwa/render3d/test_scene.lua")
local weather = import("goluwa/render3d/weather.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local kind = test_scene.GetString("KIND", "rain")
local rate = test_scene.GetNumber("RATE", 10)
local elevation = test_scene.GetNumber("ELEVATION", 35)
local ev = test_scene.GetNumber("EV", elevation > 0 and 14 or 5)
local settle = test_scene.GetNumber("SETTLE", 4)
local out = test_scene.GetString("OUT", "tmp/shots/precip")

if os.getenv("GI") == "0" then pvars.SetSession("r_pass_ddgi", false) end

test_scene.Reset{sun = {elevation = elevation, azimuth = 30}, clouds = {}}
test_scene.Ground{size = 120, material = test_scene.Matte(0.35)}
test_scene.Room{
	pos = Vec3(0, 0, 8),
	size = Vec3(6, 3, 6),
	material = test_scene.Matte(0.6),
	openings = {{wall = "-z", x = 0, y = 1, width = 1.6, height = 2}},
}
test_scene.Box{name = "pillar", pos = Vec3(-4, 1.5, 3), size = Vec3(0.6, 3, 0.6), material = test_scene.Matte(0.5)}

if os.getenv("LAMP") ~= "0" then
	local lamp = Entity.New{Name = "lamp"}
	lamp:AddComponent("transform")
	lamp.transform:SetPosition(Vec3(-3, 2.6, 3))
	local light = lamp:AddComponent("light_point")
	light:SetColor(Color(1, 0.75, 0.45, 1))
	light:SetLumen(4000)
	test_scene.GetRoot():AddChild(lamp)
end

if kind == "rain" then weather.SetRain(rate) elseif kind == "snow" then weather.SetSnow(rate) end

local wind = os.getenv("WIND")

if wind then
	local x, y, z = wind:match("([^,]+),([^,]+),([^,]+)")
	weather.SetWind(Vec3(tonumber(x), tonumber(y), tonumber(z)))
end

local views = {
	yard = {name = "yard", pos = Vec3(0, 1.7, -4), ang = {-5, 180, 0}, ev = ev},
	hut = {name = "hut", pos = Vec3(0, 1.5, 6), ang = {0, 0, 0}, ev = ev},
	up = {name = "up", pos = Vec3(-6, 1.7, 3), ang = {35, -90, 0}, ev = ev},
	sun = {name = "sun", pos = Vec3(0, 1.7, -4), ang = {25, 30, 0}, ev = ev},
}
local list = {}

for name in (os.getenv("VIEWS") or "yard,hut"):gmatch("[^,]+") do
	local view = table.copy(views[name])
	view.name = out:gsub("^tmp/shots/", "") .. "_" .. name
	list[#list + 1] = view
end

test_scene.Run{views = list, settle = settle}
