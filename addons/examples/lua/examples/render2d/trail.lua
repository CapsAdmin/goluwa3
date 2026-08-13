-- Trail renderer showcase
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local TrailRenderer = import("goluwa/render2d/trail_renderer.lua")
local assets = import("goluwa/assets.lua")
local glow_tex = assets.GetTexture("textures/render/glow_point.lua")
-- Create several trails with different configurations
local trails = {}
-- Rainbow spiral trail
trails[#trails + 1] = TrailRenderer.New{
	Duration = 3.0,
	Spacing = 2.0,
	StartSize = 12.0,
	EndSize = 0.0,
	StartColor = Color(1, 0.2, 0.3, 1),
	EndColor = Color(0.2, 0.3, 1, 0),
	Additive = true,
}
-- Green dash trail
trails[#trails + 1] = TrailRenderer.New{
	Duration = 1.5,
	Spacing = 4.0,
	StartSize = 8.0,
	EndSize = 1.0,
	StartColor = Color(0.2, 1, 0.4, 1),
	EndColor = Color(0.1, 0.5, 0.2, 0),
	Additive = false,
}
-- Blue wide trail
trails[#trails + 1] = TrailRenderer.New{
	Duration = 2.5,
	Spacing = 1.5,
	StartSize = 20.0,
	EndSize = 2.0,
	StartColor = Color(0.3, 0.5, 1, 0.8),
	EndColor = Color(0.1, 0.1, 0.5, 0),
	Additive = true,
}
-- Mouse trail with glow texture
local mouse_trail = TrailRenderer.New{
	Duration = 2.0,
	Spacing = 3.0,
	StartSize = 10.0,
	EndSize = 0.0,
	StartColor = Color(1, 1, 1, 1),
	EndColor = Color(0.8, 0.6, 1, 0),
	Texture = glow_tex,
	UVStretch = 2.0,
	Additive = true,
}
-- Trail state for orbital motion
local orbiter = {
	angle = 0,
	center_x = 0,
	center_y = 0,
	radius = 100,
	speed = 1.5,
}
local last_mouse_x = 0
local last_mouse_y = 0

event.AddListener("Update", "trail_example_update", function(dt)
	local W, H = render2d.GetSize()
	orbiter.center_x = W * 0.5
	orbiter.center_y = H * 0.5
	-- Update orbital trails
	orbiter.angle = orbiter.angle + orbiter.speed * dt

	for i, trail in ipairs(trails) do
		local offset_angle = orbiter.angle + (i - 1) * math.pi * 2 / #trails
		local offset_radius = orbiter.radius + (i - 1) * 40
		local x = orbiter.center_x + math.cos(offset_angle) * offset_radius
		local y = orbiter.center_y + math.sin(offset_angle) * offset_radius
		-- Add some wobble
		local wobble = math.sin(orbiter.angle * 3 + i) * 20
		x = x + math.cos(offset_angle) * wobble
		y = y + math.sin(offset_angle) * wobble
		trail:AddPoint(x, y)
		trail:Update(dt)
	end

	-- Mouse trail
	local win = system.GetCurrentWindow()

	if win then
		local mpos = win:GetMousePosition()
		mouse_trail:AddPoint(mpos.x, mpos.y)
		last_mouse_x = mpos.x
		last_mouse_y = mpos.y
	end

	mouse_trail:Update(dt)
end)

event.AddListener("Draw2D", "trail_example_draw", function()
	local W, H = render2d.GetSize()
	-- Clear with dark background
	render2d.PushBlendPreset("none")
	render2d.SetColor(0.05, 0.05, 0.08, 1)
	render2d.DrawRect(0, 0, W, H)
	render2d.PopBlendMode()

	-- Draw trails
	for _, trail in ipairs(trails) do
		trail:Draw()
	end

	-- Draw mouse trail on top
	mouse_trail:Draw()
	-- Draw center dot
	render2d.PushBlendPreset("additive")
	render2d.SetColor(1, 1, 1, 0.5)
	render2d.DrawRect(orbiter.center_x - 3, orbiter.center_y - 3, 6, 6)
end)

print("Trail renderer showcase loaded")
