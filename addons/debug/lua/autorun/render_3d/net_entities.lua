local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local NetworkComponent = import("goluwa/entities/components/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MAX_DISTANCE = 100
local BOX_SIZE = Vec3(0.6, 0.6, 0.6)
local SPAWNED_COLOR = {0.4, 1, 0.5, 0.9}
local BOUND_COLOR = {0.35, 0.8, 1, 0.9}
local enabled = false

event.AddListener(
	"Draw3DGeometry",
	"net_entities",
	function(cmd, dt)
		if not enabled then return end

		local camera_position = render3d.GetCamera():GetPosition()

		for id, component in pairs(NetworkComponent.GetAllNetworked()) do
			local owner = component.Owner
			local position = owner.transform:GetPosition()

			if (position - camera_position):GetLength() < MAX_DISTANCE then
				local color = component.adopted and BOUND_COLOR or SPAWNED_COLOR
				debug_draw.DrawWireBox{
					id = "net_entities_box_" .. id,
					position = position,
					size = BOX_SIZE,
					color = color,
					width = 1,
					time = dt or 0.05,
				}
				debug_draw.DrawText{
					id = "net_entities_text_" .. id,
					position = position,
					lines = {
						string.format("#%d %s", id, owner:GetName()),
						component.adopted and "bound to scene" or "spawned by server",
						component.NetworkOwner ~= "" and "owned" or "server owned",
					},
					color = color,
					time = dt or 0.05,
				}
			end
		end
	end,
	{priority = -100}
)

commands.Add("net_entities", function()
	enabled = not enabled
	print("[net entities] " .. (enabled and "Enabled" or "Disabled"))
end)
