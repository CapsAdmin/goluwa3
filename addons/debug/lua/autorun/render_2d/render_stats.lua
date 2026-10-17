local input = import("goluwa/input.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")

input.Bind("f4", "render_stats", function()
	render.stats = not render.stats
end)
