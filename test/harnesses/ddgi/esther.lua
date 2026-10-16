-- Dear Esther crystal cave flicker. env: EST_OUT (tmp/est/out) EST_FRAMES (12) EST_PV ("pvar=value ...") EST_EV (15) EST_WAIT (seconds after settling, 5)
-- saves EST_FRAMES consecutive frames of the view (GI only when EST_GI=1), score them with fireflies_score.py
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local View = import("goluwa/render3d/view.lua")
local weather = import("goluwa/render3d/weather.lua")
local commands = import("goluwa/cli/commands.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local pvars = import("goluwa/cli/pvars.lua")
local out_dir = os.getenv("EST_OUT") or "tmp/est/out"
local frames = tonumber(os.getenv("EST_FRAMES") or "") or 12
local wait = tonumber(os.getenv("EST_WAIT") or "") or 5
pvars.SetSession("r_aa", "none")
pvars.SetSession("r_motion_blur", false)
pvars.SetSession("ddgi_debug_gi", os.getenv("EST_GI") == "1")

for k, v in (os.getenv("EST_PV") or ""):gmatch("(%S+)=(%S+)") do
	local value = tonumber(v)

	if v == "true" then value = true elseif v == "false" then value = false elseif value == nil then value = v end

	pvars.SetSession(k, value)
end

commands.RunString("map esther")
os.execute("mkdir -p " .. out_dir)
local ready_at, last_time, good, settled_at = nil, system.GetTime(), 0, nil
local saved = 0
event.AddListener("BVHSceneReady", "est_ready", function()
	ready_at = system.GetTime()
end)
event.AddListener("Update", "est_cycle", function()
	local now = system.GetTime()
	local dt = now - last_time
	last_time = now

	if dt < 0.15 then good = good + 1 else good = 0 end

	if not settled_at then
		if ready_at and not scene_loading.IsLoading() and good > 90 and now - ready_at > 4 then
			weather.SetSunRotation(Quat(-0.491719, 0.158594, -0.158594, 0.841373))
			View.New{
				Priority = 100,
				Position = Vec3(44.412922, -13.809696, -19.467478),
				Rotation = Quat():SetAngles(Ang3(0.336599, -2.659134, 0)),
				FOV = 1.5707963267949,
				ExposureLock = tonumber(os.getenv("EST_EV") or "") or false,
			}:Activate()
			settled_at = now
		end

		return
	end

	if now - settled_at < wait or saved >= frames then return end

	local index = saved
	saved = saved + 1
	Screenshot(function(texture)
		texture:SaveWithoutAlpha(string.format("%s/f%03d.png", out_dir, index))

		if index == frames - 1 then system.ShutDown(0) end
	end, {update_events = 0})
end)
