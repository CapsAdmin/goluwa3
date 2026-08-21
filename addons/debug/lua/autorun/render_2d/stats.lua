local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")

event.AddListener("KeyInput", "render_stats_debug", function(key, press)
	if not press then return end

	if key == "f4" then render.stats = not render.stats end
end)
