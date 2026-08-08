-- Pretty Text showcase
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")

event.AddListener("FrameClose", "pretty_text_example_stop", function()
	running = false
end)

-- Create a gradient texture for gradient text demo
local gradient_tex = render2d.CreateGradient{
	width = 256,
	height = 1,
	mode = "linear",
	angle = 90,
	stops = {
		{pos = 0, color = Color(1, 0.2, 0.3, 1)},
		{pos = 0.3, color = Color(1, 0.6, 0.1, 1)},
		{pos = 0.6, color = Color(0.3, 1, 0.2, 1)},
		{pos = 1, color = Color(0.2, 0.4, 1, 1)},
	},
}
local FONT = "Orbitron"

event.AddListener("Draw2D", "pretty_text_example_draw", function()
	local W, H = render2d.GetSize()
	-- Clear background
	render2d.PushBlendPreset("none")
	render2d.SetColor(0.08, 0.08, 0.12, 1)
	render2d.DrawRect(0, 0, W, H)
	render2d.PopBlendMode()
	local y_offset = 40
	local x_start = 40
	-- Section 1: Basic text with glow
	render2d.DrawText{
		text = "Pretty Text Showcase",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 36,
		weight = 700,
		blur_size = 3,
		foreground_color = Color(1, 1, 1, 1),
		background_color = Color(0.6, 0.4, 1, 1),
		blur_intensity = 3,
	}
	y_offset = y_offset + 50
	-- Section 2: Colored text with auto background
	render2d.DrawText{
		text = "Auto Background (red)",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 28,
		blur_size = 2,
		foreground_color = Color(1, 0.3, 0.2, 1),
		background_color = true,
	}
	y_offset = y_offset + 40
	render2d.DrawText{
		text = "Auto Background (green)",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 28,
		blur_size = 2,
		foreground_color = Color(0.2, 1, 0.4, 1),
		background_color = true,
	}
	y_offset = y_offset + 40
	render2d.DrawText{
		text = "Auto Background (cyan)",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 28,
		blur_size = 2,
		foreground_color = Color(0.2, 0.8, 1, 1),
		background_color = true,
	}
	y_offset = y_offset + 50
	-- Section 3: Text with shadow
	render2d.DrawText{
		text = "Text With Shadow",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 32,
		blur_size = 2,
		foreground_color = Color(1, 1, 0.9, 1),
		background_color = Color(0, 0, 0, 0.5),
		shadow_x = 4,
		shadow_y = 4,
		shadow_color = Color(0, 0, 0, 0.8),
	}
	y_offset = y_offset + 50
	-- Section 4: Gradient text
	render2d.DrawText{
		text = "Gradient Text",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 34,
		weight = 700,
		blur_size = 2,
		foreground_color = Color(1, 1, 1, 1),
		background_color = Color(0, 0, 0, 1),
		gradient = gradient_tex,
	}
	y_offset = y_offset + 50
	-- Section 5: Scaled and rotated text
	render2d.DrawText{
		text = "Scaled 1.5x",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 24,
		blur_size = 2,
		foreground_color = Color(0.4, 1, 0.6, 1),
		background_color = Color(0.1, 0.3, 0.2, 1),
		scale = 1,
	}
	y_offset = y_offset + 55
	render2d.DrawText{
		text = "Rotated",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 24,
		blur_size = 2,
		foreground_color = Color(1, 0.6, 0.3, 1),
		background_color = Color(0.3, 0.15, 0.1, 1),
		angle = 0.1,
	}
	y_offset = y_offset + 55
	-- Section 6: Skewed text
	render2d.DrawText{
		text = "Skewed",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 28,
		blur_size = 2,
		foreground_color = Color(0.8, 0.5, 1, 1),
		background_color = Color(0.2, 0.1, 0.3, 1),
		skew_x = -20,
		skew_y = 0,
	}
	y_offset = y_offset + 50
	-- Section 7: Animated pulsing glow
	local pulse = (math.sin(system.GetElapsedTime() * 3) + 1) * 0.5
	local pulse_color = Color(0.5 + pulse * 0.5, 0.3 + pulse * 0.3, 1, 1)
	render2d.DrawText{
		text = "Pulsing Glow",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 30,
		blur_size = 2 + pulse * 3,
		foreground_color = pulse_color,
		background_color = Color(0.1, 0.1, 0.4, 0.5 + pulse * 0.5),
		blur_intensity = 2 + pulse * 2,
	}
	y_offset = y_offset + 50
	-- Section 8: Alignment demo
	local center_x = W / 2
	render2d.DrawText{
		text = "Center Aligned",
		x = center_x,
		y = y_offset,
		font = FONT,
		size = 26,
		blur_size = 2,
		foreground_color = Color(1, 0.8, 0.4, 1),
		background_color = Color(0.3, 0.2, 0.1, 1),
		x_align = -0.5,
		y_align = -0.5,
	}
	y_offset = y_offset + 45
	-- Section 10: Small text with minimal blur
	render2d.DrawText{
		text = "Small text, no blur",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 14,
		blur_size = 0,
		foreground_color = Color(0.7, 0.7, 0.7, 1),
	}
	y_offset = y_offset + 30
	render2d.DrawText{
		text = "Small text with glow",
		x = x_start,
		y = y_offset,
		font = FONT,
		size = 14,
		blur_size = 1,
		foreground_color = Color(0.7, 0.7, 0.7, 1),
		background_color = Color(0.2, 0.2, 0.4, 0.5),
	}
	-- Draw a separator line at top
	render2d.PushBlendPreset("alpha")
	render2d.SetColor(0.3, 0.3, 0.5, 0.5)
	render2d.DrawRect(x_start, 30, W - x_start * 2, 1)
	render2d.PopBlendMode()
end)
