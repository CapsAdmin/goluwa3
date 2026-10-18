local commands = import("goluwa/cli/commands.lua")
local units = import("goluwa/source_engine/units.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local scene_rt = import("goluwa/render3d/scene/rt.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local m3 = {}
m3.spawn = units.PositionToEngine(Vec3(-10818, -9029.5, 9448))
local t0 = system.GetTime()

-- calls fn(view) each frame after the scene settled; fn returns true to keep going
function m3.Run(fn, yaw, pitch)
	local stable_since
	local view
	event.AddListener("Update", "m3_harness", function()
		local now = system.GetTime()
		if not view then
			if scene_rt.readied and not scene_loading.IsLoading() and not tasks.IsBusy() then
				stable_since = stable_since or now
				if now - stable_since > 4 then
					print(string.format("LOADED at %.1fs", now - t0))
					local position = m3.spawn
					if os.getenv("M3_POS") then
						local v = {}
						for n in os.getenv("M3_POS"):gmatch("[^,]+") do v[#v + 1] = tonumber(n) end
						position = Vec3(v[1], v[2], v[3])
					end
					view = View.New{Priority = 100, Position = position, Rotation = QuatDeg3(tonumber(os.getenv("M3_PITCH")) or pitch or 0, tonumber(os.getenv("M3_YAW")) or yaw or 0, 0)}:Activate()
					m3.view = view
				end
			else
				stable_since = nil
			end
			return
		end
		if os.getenv("M3_MOVE") then
			local speed = tonumber(os.getenv("M3_MOVE"))
			local dt = now - (m3.last_time or now)
			m3.last_time = now
			local rotation = view:GetRotation()
			view:SetPosition(view:GetPosition() + rotation:GetForward() * speed * dt)
		end

		if fn(view, now) == false then
			system.ShutDown(0)
		end
	end)
	commands.RunString("map gm_construct_m3_401")
end
return m3
