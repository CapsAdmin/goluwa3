local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local nav_mesh = import("goluwa/entities/components/nav_mesh.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

do
	local DEBUG_RADIUS = 30
	local DEBUG_LIFETIME = 0.1
	local OUTLINE = Color(0.1, 1, 0.3, 1)
	local BLOCKED = Color(1, 0.2, 0.2, 1)
	local AVOID = Color(1, 0.7, 0.1, 1)
	local LIFT = Vec3(0, 0.03, 0)
	local draw_events = false

	commands.Add("nav_show", function()
		draw_events = not draw_events

		if not draw_events then
			event.RemoveListener("Update", "nav_mesh_debug")
			return
		end

		event.AddListener("Update", "nav_mesh_debug", function()
			local mesh = nav_mesh.GetMesh()

			if not mesh then return end

			for _, area in ipairs(mesh:GetAreasNear(render3d.GetCamera():GetPosition(), DEBUG_RADIUS)) do
				local p = area.points
				local color = area.Blocked and BLOCKED or area.Cost > 1 and AVOID or OUTLINE

				for i = 0, area.count - 1 do
					local o, n = i * 3, (i + 1) % area.count * 3
					debug_draw.DrawLine{
						id = "nav_" .. area.Index .. "_" .. i,
						from = Vec3(p[o + 1], p[o + 2], p[o + 3]) + LIFT,
						to = Vec3(p[n + 1], p[n + 2], p[n + 3]) + LIFT,
						color = color,
						width = 2,
						time = DEBUG_LIFETIME,
					}
				end
			end
		end)
	end)
end

do
	local lift = Vec3(0, 0.1, 0)
	local path_debug = false

	commands.Add("npc_show_paths", function()
		path_debug = not path_debug

		if not path_debug then
			event.RemoveListener("Update", "npc_path_debug")
			return
		end

		local npc_component = import("lua/components/npc.lua")

		event.AddListener("Update", "npc_path_debug", function()
			for index, npc in ipairs(npc_component.Instances) do
				local path = npc.path

				if path then
					local points = path.points

					for i = npc.path_index, #points do
						debug_draw.DrawLine{
							id = "npc_path_" .. index .. "_" .. i,
							from = (i == npc.path_index and npc.Owner.transform:GetPosition() or points[i - 1]) + lift,
							to = points[i] + lift,
							color = npc.Running and Color(1, 0.4, 0.1, 1) or Color(0.2, 0.8, 1, 1),
							width = 3,
							time = 0.1,
						}
					end
				end
			end
		end)
	end)
end
