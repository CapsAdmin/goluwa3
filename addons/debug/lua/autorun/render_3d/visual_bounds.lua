local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local Color = import("goluwa/structs/color.lua")
local AABB = import("goluwa/structs/aabb.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local Animator = import("goluwa/entities/components/animator.lua")
local Health = import("lua/components/health.lua")
local visual_bounds = import("lua/visual_bounds.lua")
local enabled = false
local culling_color = Color(1, 0.28, 0.24, 0.5)
local animated_color = Color(0.25, 0.95, 0.35, 0.95)
local core_color = Color(1, 0.85, 0.25, 0.95)
local combined_color = Color(0.5, 0.82, 1, 0.95)
local animated_box = AABB(0, 0, 0, 0, 0, 0)
local core_box = AABB(0, 0, 0, 0, 0, 0)
local combined_box = AABB(0, 0, 0, 0, 0, 0)

commands.Add("visual_bounds_debug", function()
	enabled = not enabled
	print("[Visual Bounds Debug] " .. (enabled and "ON" or "OFF"))
end)

event.AddListener(
	"Draw3DGeometry",
	"visual_bounds_debug",
	function()
		if not enabled then return end

		for _, animator in ipairs(Animator.Instances) do
			local owner = animator.Owner

			if animator.rig and owner.visual and owner.visual.Visible then
				debug_draw.DrawWireAABB{
					id = "visual_bounds_culling_" .. tostring(animator),
					aabb = owner.visual:GetWorldAABB(),
					color = culling_color,
				}
				local box = animator:GetWorldAABB(animated_box)

				if box then
					debug_draw.DrawWireAABB{
						id = "visual_bounds_animated_" .. tostring(animator),
						aabb = box,
						color = animated_color,
						width = 2,
					}
				end
			end
		end

		for _, health in ipairs(Health.Instances) do
			if visual_bounds.GetCore(health.Owner, core_box) then
				debug_draw.DrawWireAABB{
					id = "visual_bounds_core_" .. tostring(health),
					aabb = core_box,
					color = core_color,
					width = 2,
				}
			end

			if visual_bounds.Get(health.Owner, combined_box) then
				debug_draw.DrawWireAABB{
					id = "visual_bounds_combined_" .. tostring(health),
					aabb = combined_box,
					color = combined_color,
					width = 2,
				}
			end
		end
	end,
	{priority = -100}
)
