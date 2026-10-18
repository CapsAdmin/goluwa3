-- (EV_VIS=rays also estimates which of them can be seen, see scene_draw_visibility)
-- rows the main cull draws at a list of views of the esther map, after the scene is ready. the views are in VIEWS below, EV_DUMP=n lists the largest rows
-- of each view
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local View = import("goluwa/render3d/view.lua")
local weather = import("goluwa/render3d/weather.lua")
local commands = import("goluwa/cli/commands.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local VIEWS = {
	{"wall 4", Vec3(-0.907951, -39.371849, 62.735638), Ang3(-1.560790, 0.033638, -0.000022)},
	{"view 2a", Vec3(-1.940760, -37.943398, 50.408764), Ang3(0.290500, 0.646271, 0)},
	{"view 2b", Vec3(0.083815, -35.484245, 36.543209), Ang3(-0.086491, -1.481036, 0)},
	{"view 4b", Vec3(14.241719, -0.511441, -30.688238), Ang3(-1.547330, 2.100331, 0.000048)},
}
local pvars = import("goluwa/cli/pvars.lua")

for k, v in (os.getenv("EV_PV") or ""):gmatch("(%S+)=(%S+)") do
	pvars.SetSession(k, tonumber(v) or (v == "true") or (v ~= "false" and v) or false)
end

commands.RunString("map esther")
local ready_at, last_time, good, settled_at = nil, system.GetTime(), 0, nil
local index, frames_in_view = 0, 0
event.AddListener("RTSceneReady", "ev_ready", function() ready_at = system.GetTime() end)
event.AddListener("Update", "ev_cycle", function()
	local now = system.GetTime()
	local dt = now - last_time
	last_time = now

	if dt < 0.15 then good = good + 1 else good = 0 end

	if not settled_at then
		if ready_at and not scene_loading.IsLoading() and good > 60 and now - ready_at > 3 then
			weather.SetSunRotation(Quat(-0.486132, 0.157912, -0.157912, 0.844869))
			settled_at = now
			index = 1
		end

		return
	end

	frames_in_view = frames_in_view + 1

	if frames_in_view == 1 then
		local v = VIEWS[index]
		View.New{Priority = 100 + index, Position = v[2], Rotation = Quat():SetAngles(v[3]), FOV = 1.5707963267949}:Activate()
	end

	-- the depth pyramid is of the frame before, it takes a few
	if frames_in_view == 25 then
		local opaque, translucent = scene_draw.ReadBackCull(0), scene_draw.ReadBackCull(1)
		local function triangles(result)
			local total = 0

			for _, entry in pairs(result.by_id) do
				total = total + entry.index_count / 3
			end

			return total
		end

		print(string.format("VIEW %-8s opaque %3d (%7d tris) translucent %3d (%7d tris)  of %d rows, %d instances", VIEWS[index][1], opaque.count, triangles(opaque), translucent.count, triangles(translucent), opaque.slots, instances.GetCount()))

		if os.getenv("EV_DUMP") then commands.RunString("scene_draw_dump " .. os.getenv("EV_DUMP")) end

		if os.getenv("EV_VIS") then commands.RunString("scene_draw_visibility " .. os.getenv("EV_VIS")) end

		index = index + 1
		frames_in_view = 0

		if index > #VIEWS then system.ShutDown(0) end
	end
end)
