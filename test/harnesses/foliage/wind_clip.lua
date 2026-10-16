-- a clip of foliage in a strong wind, frames into tmp/foliage_wind/, to make a gif of:
-- luajit glw --3d --background lua test/harnesses/foliage/wind_clip.lua
-- ffmpeg -framerate 15 -i tmp/foliage_wind/%03d.png -vf scale=960:-1 tmp/foliage_wind.gif
-- MODEL, SPACING and COLUMNS as for scene.lua, POS and LOOK the camera, WIND x,z in m/s
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local weather = import("goluwa/render3d/weather.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local vfs = import("goluwa/vfs.lua")
import("test/harnesses/foliage/scene.lua")

local function vec(str, default)
	local x, y, z = (str or default):match("([^,]+),([^,]+),([^,]+)")
	return Vec3(tonumber(x), tonumber(y), tonumber(z))
end

local wind_x, wind_z = (os.getenv("WIND") or "9,3"):match("([^,]+),([^,]+)")
weather.SetWind(Vec3(tonumber(wind_x), 0, tonumber(wind_z)))
local from, to = vec(os.getenv("POS"), "0,6,24"), vec(os.getenv("LOOK"), "0,5,0")
local dir = (to - from):GetNormalized()
local rotation = Quat()
rotation:Identity()
rotation:RotateYaw(math.atan2(-dir.x, -dir.z))
rotation:RotatePitch(math.asin(dir.y))
View.New{Priority = 100, Position = from, Rotation = rotation, FOV = math.rad(60), ExposureLock = tonumber(os.getenv("EV") or "14")}:Activate()
assert(vfs.CreateDirectoriesFromPath("os:tmp/foliage_wind/"))
local FRAMES = tonumber(os.getenv("FRAMES") or "45")
local start = system.GetElapsedTime()
local next_shot, frame, pending = 3, 0, false

event.AddListener("Update", "foliage_wind_clip", function()
	local now = system.GetElapsedTime() - start

	if pending or now < next_shot then return end

	pending = true
	Screenshot(function(texture)
		frame = frame + 1
		texture:SaveWithoutAlpha(("tmp/foliage_wind/%03d.png"):format(frame))
		pending = false
		next_shot = next_shot + 1 / 15

		if frame >= FRAMES then system.ShutDown(0) end
	end)
end)
