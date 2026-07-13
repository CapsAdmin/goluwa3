local assets = import("goluwa/assets.lua")
local event = import("goluwa/event.lua")
local tex = assets.GetTexture("textures/render/blue_noise.lua")
local render2d = import("goluwa/render2d/render2d.lua")

event.AddListener("Draw2D", "test", function()
	render2d.SetTexture(tex)
	render2d.DrawRect(0, 0, 512, 512)
end)
