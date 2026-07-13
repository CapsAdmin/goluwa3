local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")

event.AddListener("Draw2D", "clear_test", function()
	render.target:Clear(0, 0, 0, nil, nil)
	render.target:Clear(0, 0, 1, 1, 1)
end)
