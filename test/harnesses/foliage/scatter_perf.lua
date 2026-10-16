-- frame time of a scatter set over the hills of test/harnesses/scatter/scene.lua, standing in it and from above,
-- after the bakes are done: SET=foliage_forest luajit glw --3d --background lua test/harnesses/foliage/scatter_perf.lua
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local scatter = import("goluwa/render3d/scatter.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
import("test/harnesses/scatter/scene.lua")
local views = {
	{name = "ground", pos = {-25, 0, -25}, ground = 1.7, ang = {-3, 45}},
	{name = "above", pos = {0, 0, 0}, ground = 25, ang = {-30, 90}},
}
local index, view, phase, phase_start, frames, settled_at = 0, nil, "next", 0, 0, nil

local function next_view()
	index = index + 1
	local v = views[index]

	if not v then
		system.ShutDown(0)
		return
	end

	if view then view:Remove() end

	local pos = Vec3(v.pos[1], _G.scatter_height(v.pos[1], v.pos[3]) + v.ground, v.pos[3])
	view = View.New{Priority = 100, Position = pos, Rotation = Quat():SetAngles(Deg3(v.ang[1], v.ang[2], 0)), FOV = math.rad(70)}:Activate()
	phase, phase_start, settled_at = "settle", system.GetElapsedTime(), nil
end

event.AddListener("Update", "foliage_scatter_perf", function()
	local now = system.GetElapsedTime()

	if phase == "next" then
		if now > 3 then next_view() end
	elseif phase == "settle" then
		if (scatter.pending_bakes or 0) == 0 then settled_at = settled_at or now else settled_at = nil end

		if settled_at and now - settled_at > 2 or now - phase_start > 30 then
			phase, phase_start, frames = "measure", system.GetTime(), 0
		end
	elseif phase == "measure" then
		frames = frames + 1
		local elapsed = system.GetTime() - phase_start

		if elapsed > 4 then
			print(("%s %s: %.2f ms a frame (%d frames)"):format(os.getenv("SET") or "crysis_meadow", views[index].name, elapsed / frames * 1000, frames))
			phase = "next"
			next_view()
		end
	end
end)
