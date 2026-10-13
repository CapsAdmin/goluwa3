-- same process A/B: AB_MODES="name:lua code;name:lua code" run in order per view, screenshots to AB_OUT
local m3 = import("test/harnesses/m3/harness.lua")
local system = import("goluwa/system.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local glass_tint = import("goluwa/render3d/glass_tint.lua")
local pvars = import("goluwa/cli/pvars.lua")
local out = os.getenv("AB_OUT")
local hold = tonumber(os.getenv("AB_HOLD") or "200")
local ev = tonumber(os.getenv("AB_EV") or "7")
os.execute("mkdir -p " .. out)
local modes = {}
for spec in (os.getenv("AB_MODES") or ""):gmatch("[^|]+") do
	local name, code = spec:match("^([^=]+)=(.*)$")
	modes[#modes + 1] = {name = name, fn = assert(loadstring("local glass_tint, pvars = ... " .. code))}
end
local spawn = m3.spawn
local views = {
	{"spawn0", spawn, 0, 0},
	{"spawn90", spawn, 0, 90},
	{"down45", spawn, -25, 45},
	{"up225", spawn, 20, 225},
}
local vi, mi, frame, state = 0, 0, 0, "next_view"
local cur
m3.Run(function(_, now)
	if state == "next_view" then
		vi = vi + 1
		if vi > #views then return false end
		local v = views[vi]
		if cur then cur:Remove() end
		cur = View.New{Priority = 200, Position = v[2], Rotation = QuatDeg3(v[3], v[4], 0), ExposureLock = ev}:Activate()
		mi = 0
		state = "next_mode"
		return
	end
	if state == "next_mode" then
		mi = mi + 1
		if mi > #modes then state = "next_view" return end
		modes[mi].fn(glass_tint, pvars)
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
				print("SAVED", texture:SaveWithoutAlpha(out .. "/" .. modes[mi].name .. "_" .. views[vi][1] .. ".png"))
				state = "next_mode"
			end)
		end
	end
end)
