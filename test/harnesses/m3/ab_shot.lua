-- screenshots a fixed list of views with frozen time and locked exposure: AB_OUT=dir AB_TAG=name [AB_CULL=1]
local m3 = import("test/harnesses/m3/harness.lua")
local system = import("goluwa/system.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local fs = import("goluwa/filesystem/fs.lua")
local pvars = import("goluwa/cli/pvars.lua")
local out = os.getenv("AB_OUT")
local tag = os.getenv("AB_TAG") or "run"
local hold = tonumber(os.getenv("AB_HOLD") or "260")
local ev = tonumber(os.getenv("AB_EV") or "7")
os.execute("mkdir -p " .. out)
local spawn = m3.spawn
local views = {
	{"spawn0", spawn, 0, 0},
	{"spawn90", spawn, 0, 90},
	{"spawn180", spawn, 0, 180},
	{"spawn270", spawn, 0, 270},
	{"down45", spawn, -25, 45},
	{"up225", spawn, 20, 225},
	{"fwd0", spawn + QuatDeg3(0, 0, 0):GetForward() * 6, 0, 20},
	{"fwd180", spawn + QuatDeg3(0, 180, 0):GetForward() * 6, -5, 200},
}
local idx, frame, state = 0, 0, "next"
local cur
m3.Run(function(_, now)
	if state == "next" then
		idx = idx + 1
		if idx > #views then return false end
		local v = views[idx]
		if cur then cur:Remove() end
		cur = View.New{Priority = 200, Position = v[2], Rotation = QuatDeg3(v[3], v[4], 0), ExposureLock = ev}:Activate()
		frame = 0
		state = "hold"
		return
	end
	if state == "hold" then
		frame = frame + 1
		system.SetElapsedTime(1000 + frame / 60)
		if frame >= hold then
			state = "wait"
			Screenshot(function(texture)
				print("SAVED", texture:SaveWithoutAlpha(out .. "/" .. tag .. "_" .. views[idx][1] .. ".png"))
				state = "next"
			end)
		end
	end
end)
