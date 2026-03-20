local event = import("goluwa/event.lua")
local debug_draw = import("goluwa/render3d/debug_draw.lua")
local Model = import("goluwa/ecs/components/3d/model.lua")
local aabb_enabled = false

event.AddListener("KeyInput", "aabb_debug_toggle", function(key, press)
	if not press then return end

	if key == "b" then
		aabb_enabled = not aabb_enabled
		print("[AABB Debug] " .. (aabb_enabled and "Enabled" or "Disabled"))
	end
end)

event.AddListener(
	"Draw3DGeometry",
	"aabb_debug_draw",
	function(cmd, dt)
		if not aabb_enabled then return end

		for i, model in ipairs(Model.Instances or {}) do
			local aabb = model.GetWorldAABB and model:GetWorldAABB() or nil

			if aabb and aabb.min_x ~= math.huge then
				debug_draw.DrawWireAABB({
					id = "aabb_debug_" .. tostring(i) .. "_" .. tostring(model),
					aabb = aabb,
					color = {1, 1, 1, 0.9},
					width = 1,
					time = dt or 0.05,
				})
			end
		end
	end,
	{priority = -100}
)
