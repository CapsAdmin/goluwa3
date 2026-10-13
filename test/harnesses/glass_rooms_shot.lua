local scene = import("test/harnesses/glass_rooms.lua")
local Shot = import("goluwa/render3d/shot.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local pvars = import("goluwa/cli/pvars.lua")
local views = {}

for pair in (os.getenv("PVARS") or ""):gmatch("[^,]+") do
	local key, value = pair:match("^([^=]+)=(.*)$")

	if value == "true" then value = true elseif value == "false" then value = false else value = tonumber(value) or value end

	pvars.SetSession(key, value)
end

if os.getenv("GLASS_OFF") then pvars.SetSession("r_glass_light", false) end


local rooms = {}

for _, room in ipairs(scene.rooms) do
	if not os.getenv("ONLY") or room.name:find(os.getenv("ONLY")) then rooms[#rooms + 1] = room end
end

scene.rooms = rooms

for i, room in ipairs(scene.rooms) do
	views[i] = room.view and {
		Position = room.view.Position,
		Rotation = room.view.Rotation,
		FOV = room.view.FOV,
		ExposureLock = room.ev,
	} or room.closeup and {
		Position = Vec3(room.ox, 2.6, -6.5),
		Rotation = QuatDeg3(-38, 180, 0),
		FOV = math.rad(70),
		ExposureLock = room.ev,
	} or room.inside and {
		Position = Vec3(room.ox + 4.4, 1.8, -4.4),
		Rotation = QuatDeg3(-8, tonumber(os.getenv("INSIDE_YAW") or "135"), 0),
		FOV = math.rad(85),
		ExposureLock = room.ev,
	} or {
		Position = Vec3(room.ox, 2.2, -9.5),
		Rotation = QuatDeg3(-12, 180, 0),
		FOV = math.rad(75),
		ExposureLock = room.ev,
	}
end

Shot.Sequence(views, function(texture, info, i)
	print(texture:SaveWithoutAlpha((os.getenv("GLASS_OUT") or "tmp/glass_rooms") .. "_" .. scene.rooms[i].name .. ".png"), info.seconds)
end, {settle = tonumber(os.getenv("SETTLE") or "4")}, function()
	system.ShutDown(0)
end)
