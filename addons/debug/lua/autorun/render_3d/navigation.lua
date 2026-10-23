local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

do
	local lift = Vec3(0, 0.1, 0)
	local path_debug = false

	commands.Add("npc_show_paths", function()
		path_debug = not path_debug

		if not path_debug then
			event.RemoveListener("Update", "npc_path_debug")
			return
		end

		local npc_component = import("lua/components/ai_controller.lua")

		event.AddListener("Update", "npc_path_debug", function()
			for index, npc in ipairs(npc_component.Instances) do
				local path = npc.path

				if path then
					local points = path.points

					for i = npc.path_index, #points do
						debug_draw.DrawLine{
							id = "npc_path_" .. index .. "_" .. i,
							from = (
									i == npc.path_index and
									npc.Owner.transform:GetPosition() or
									points[i - 1]
								) + lift,
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
