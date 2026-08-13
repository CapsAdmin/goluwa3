-- MSDF vs SDF comparison test
local render2d = import("goluwa/render2d/render2d.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local SVG = import("goluwa/render2d/svg.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local event = import("goluwa/event.lua")
local font_path = fonts.GetDefaultSystemFontPath()
local label_font = fonts.New{Path = font_path, Size = 14}
local font_sizes = {8, 12, 16, 24, 32}
local fonts_sdf = {}
local fonts_msdf = {}

for _, sz in ipairs(font_sizes) do
	fonts_sdf[sz] = fonts.New{Path = font_path, Size = sz, Mode = "sdf"}
	fonts_msdf[sz] = fonts.New{Path = font_path, Size = sz, Mode = "msdf"}
end

-- Star SVG path
local star_svg = [[
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
  <path d="M 50 5 L 61 35 L 95 35 L 68 57 L 79 90 L 50 70 L 21 90 L 32 57 L 5 35 L 39 35 Z" fill="black"/>
</svg>
]]
local svg_sdf = SVG.New(star_svg, {TextureSize = 64, SDFSpread = 8, Mode = "sdf"})
local svg_msdf = SVG.New(star_svg, {TextureSize = 64, SDFSpread = 8, Mode = "msdf"})
local svg_poly = SVG.New(star_svg, {Mode = "poly"})
-- Create a color texture to modulate with
local gradient_tex = Texture.New{
	width = 64,
	height = 64,
	format = "r8g8b8a8_unorm",
	mip_map_levels = 1,
	sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	},
}
gradient_tex:Shade([[ return vec4(uv.x, uv.y, 0.5, 1.0); ]])
-- MSDF texture for a circle
local msdf_tex = Texture.New{
	width = 64,
	height = 64,
	format = "r8g8b8a8_unorm",
	mip_map_levels = 1,
	sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	},
}
msdf_tex:Shade([[
	vec2 center = vec2(0.5);
	float radius = 0.4;
	float texels = 64.0;
	vec2 to_center = center - uv;
	float d = (radius - length(to_center)) * texels;
	vec2 normal = normalize(to_center);
	float r = d + normal.x;
	float g = d + normal.y;
	float b = d;
	float spread = 10.0;
	vec3 msdf = vec3(r, g, b) / (spread * 2.0) + 0.5;
	msdf = clamp(msdf, 0.0, 1.0);
	return vec4(msdf, 1.0);
]])
-- Regular single-channel SDF texture for comparison
local sdf_tex = Texture.New{
	width = 64,
	height = 64,
	format = "r8g8b8a8_unorm",
	mip_map_levels = 1,
	sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_edge",
		wrap_t = "clamp_to_edge",
	},
}
sdf_tex:Shade([[
	vec2 center = vec2(0.5);
	float radius = 0.4;
	float texels = 64.0;
	float d = (radius - length(uv - center)) * texels;
	float normalized = d / (10.0 * 2.0) + 0.5;
	normalized = clamp(normalized, 0.0, 1.0);
	return vec4(normalized);
]])

local function draw_circle(x, y, w, h, tex, use_msdf, outline, softness)
	render2d.PushSDFTexelRange(20)
	render2d.PushSDFTexture(tex)
	render2d.PushMSDFEnabled(use_msdf)

	if softness then render2d.PushSDFSoftness(softness) end

	if outline then render2d.PushOutlineWidth(outline) end

	render2d.PushTexture(gradient_tex)
	render2d.DrawRect(x, y, w, h)
	render2d.PopTexture()

	if outline then render2d.PopOutlineWidth() end

	if softness then render2d.PopSDFSoftness() end

	render2d.PopMSDFEnabled()
	render2d.PopSDFTexture()
	render2d.PopSDFTexelRange()
end

local function draw_row(y, label, draw_fn)
	label_font:DrawText(label, 10, y)
	draw_fn(y + 15)
end

event.AddListener("Draw2D", "msdf_test", function()
	draw_circle(30, 30, 30, 30, sdf_tex, false, nil, nil)
	render2d.SetColor(1, 1, 1, 1)
	local W, H = render2d.GetSize()
	render2d.PushBlendPreset("none")
	render2d.SetColor(0.08, 0.08, 0.12, 1)
	render2d.DrawRect(0, 0, W, H)
	render2d.PopBlendMode()
	render2d.SetColor(1, 1, 1, 1)
	local col_sdf = 30
	local size = 70
	local col_msdf = col_sdf + 70 + 20
	local y = 30

	-- Row 1: circle basic fill
	draw_row(y, "circle fill", function(ry)
		draw_circle(col_sdf, ry, size, size, sdf_tex, false)
		draw_circle(col_msdf, ry, size, size, msdf_tex, true)
	end)

	-- Row 3: circle with outline
	y = y + size + 30

	draw_row(y, "circle outline outset", function(ry)
		draw_circle(col_sdf, ry, size, size, sdf_tex, false, 5)
		draw_circle(col_msdf, ry, size, size, msdf_tex, true, 5)
	end)

	y = y + size + 30

	draw_row(y, "circle outline inset", function(ry)
		draw_circle(col_sdf, ry, size, size, sdf_tex, false, -5)
		draw_circle(col_msdf, ry, size, size, msdf_tex, true, -5)
	end)

	-- Row 4: circle with softness
	y = y + size + 30

	draw_row(y, "circle softness", function(ry)
		draw_circle(col_sdf, ry, size, size, sdf_tex, false, nil, 4)
		draw_circle(col_msdf, ry, size, size, msdf_tex, true, nil, 4)
	end)

	-- Row 5: SVG star basic
	y = y + size + 40

	draw_row(y, "svg star", function(ry)
		render2d.PushMatrixf(col_sdf, ry, size)
		svg_sdf:Draw()
		render2d.PopMatrix()
		render2d.PushMatrixf(col_msdf, ry, size)
		svg_msdf:Draw()
		render2d.PopMatrix()
		render2d.PushMatrixf(col_msdf + 80, ry, size)
		svg_poly:Draw()
		render2d.PopMatrix()
	end)

	-- Font comparison rows (SDF on top, MSDF below)
	y = y + 80
	local text = "The quick brown fox jumps over the lazy dog"

	for _, sz in ipairs(font_sizes) do
		label_font:DrawText("font " .. sz .. "px", 10, y)
		fonts_sdf[sz]:DrawText(text, 10, y + 15)
		y = y + sz + 5
		fonts_msdf[sz]:DrawText(text, 10, y + 15)
		y = y + sz + 20
	end

	-- Labels
	label_font:DrawText("SDF", col_sdf + 20, H - 10)
	label_font:DrawText("MSDF", col_msdf + 10, H - 10)
end)
