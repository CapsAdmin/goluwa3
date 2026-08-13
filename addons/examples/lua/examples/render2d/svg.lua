-- SVG renderer showcase
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local SVG = import("goluwa/render2d/svg.lua")
local running = true
-- Inline SVG icons for the demo
local heart_svg = [[<svg viewBox="0 0 24 24"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>]]
local star_svg = [[<svg viewBox="0 0 24 24"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>]]
local diamond_svg = [[<svg viewBox="0 0 24 24"><path d="M12 2L2 12l10 10 10-10L12 2z"/></svg>]]
local bolt_svg = [[<svg viewBox="0 0 24 24"><path d="M17.76,10.63,9,21l2.14-8H7.05a1,1,0,0,1-1-1.36l3.23-8a1.05,1.05,0,0,1,1-.64h4.34a1,1,0,0,1,1,1.36L13.7,9H17a1,1,0,0,1,.76,1.63Z"/></svg>]]
local circle_svg = [[<svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8z"/></svg>]]
-- Create SVG objects
local svg_list = {
	SVG.New(heart_svg),
	SVG.New(star_svg),
	SVG.New(diamond_svg),
	SVG.New(bolt_svg),
	SVG.New(circle_svg),
}
local colors = {
	Color(1, 0.3, 0.4, 1),
	Color(1, 0.85, 0.2, 1),
	Color(0.3, 0.7, 1, 1),
	Color(0.9, 0.5, 1, 1),
	Color(0.4, 1, 0.6, 1),
}

event.AddListener("Draw2D", "svg_example_draw", function()
	local W, H = render2d.GetSize()
	local t = system.GetElapsedTime()
	-- Clear
	render2d.PushBlendPreset("none")
	render2d.SetColor(0.08, 0.08, 0.12, 1)
	render2d.DrawRect(0, 0, W, H)
	render2d.PopBlendMode()
	-- Draw title
	render2d.DrawText{
		text = "SVG Renderer",
		x = W / 2,
		y = 30,
		size = 24,
		foreground_color = Color(0.9, 0.9, 0.9, 1),
	}
	-- Draw SVGs in a row
	local svg_size = 80
	local gap = 40
	local total_width = #svg_list * svg_size + (#svg_list - 1) * gap
	local start_x = (W - total_width) / 2
	local base_y = H / 2 - 30

	for i, svg in ipairs(svg_list) do
		if svg.status ~= "loaded" then continue end

		local x = start_x + (i - 1) * (svg_size + gap)
		local bob = math.sin(t * 2 + i * 1.2) * 10
		local scale = 1 + math.sin(t * 3 + i * 0.8) * 0.1
		render2d.SetColor(colors[i]:Unpack())
		render2d.PushMatrixf(x, base_y + bob, svg_size * scale)
		--render2d.PushSDFSoftness(4)
		svg:Draw()
		--render2d.PopSDFSoftness()
		render2d.PopMatrix()
	end
end)
