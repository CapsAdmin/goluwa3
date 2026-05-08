local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local checker_texture = Texture.New{
	width = 96,
	height = 96,
	format = "r8g8b8a8_unorm",
	mip_map_levels = 1,
	sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "repeat",
		wrap_t = "repeat",
	},
}
checker_texture:Shade([[
	vec2 grid = floor(uv * 12.0);
	float checker = mod(grid.x + grid.y, 2.0);
	float diagonal = smoothstep(0.35, 0.65, abs(sin((uv.x * 10.0 + uv.y * 14.0) * 3.14159)));
	vec3 dark = vec3(0.08, 0.11, 0.17);
	vec3 light = vec3(0.83, 0.9, 1.0);
	vec3 accent = vec3(1.0, 0.44, 0.2);
	vec3 base = mix(dark, light, checker);
	base = mix(base, accent, diagonal * 0.28);
	return vec4(base, 1.0);
]])
local warm_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 0,
	stops = {
		{pos = 0.0, color = Color(1.0, 0.5, 0.2, 1.0)},
		{pos = 1.0, color = Color(1.0, 0.86, 0.28, 1.0)},
	},
}
local cool_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 90,
	stops = {
		{pos = 0.0, color = Color(0.24, 0.82, 1.0, 1.0)},
		{pos = 1.0, color = Color(0.2, 0.3, 1.0, 1.0)},
	},
}
local mono_gradient = render2d.CreateGradient{
	mode = "linear",
	angle = 180,
	stops = {
		{pos = 0.0, color = Color(1.0, 1.0, 1.0, 1.0)},
		{pos = 1.0, color = Color(0.5, 0.56, 0.68, 1.0)},
	},
}
local gradients = {false, warm_gradient, cool_gradient, mono_gradient}
local swizzle_modes = {0, 1, 2, 3, 5}
local time_accum = 0

local function fract(value)
	return value - math.floor(value)
end

local function hash(index, salt)
	return fract(math.sin(index * 12.9898 + salt * 78.233) * 43758.5453)
end

local function with_rect_batch_mode(mode, callback)
	local old_mode = render2d.GetRectBatchMode()
	local ok, err
	render2d.SetRectBatchMode(mode)
	ok, err = xpcall(callback, debug.traceback)
	render2d.SetRectBatchMode(old_mode)

	if not ok then error(err, 0) end
end

local function reset_rect_state()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(1)
	render2d.SetBorderRadius(0)
	render2d.SetBlur(0)
	render2d.SetOutlineWidth(0)
	render2d.SetSDFGradientTexture(nil)
	render2d.SetTexture(nil)
	render2d.SetUV(nil)
	render2d.SetSwizzleMode(0)
end

local function draw_stateful_rect(x, y, w, h, index, layer, time)
	local seed = index * 37 + layer * 131
	local hue_a = hash(seed, 0)
	local hue_b = hash(seed, 1)
	local hue_c = hash(seed, 2)
	local alpha = 0.6 + hash(seed, 3) * 0.4
	local radius_a = math.floor(hash(seed, 4) * 18)
	local radius_b = math.floor(hash(seed, 5) * 18)
	local radius_c = math.floor(hash(seed, 6) * 18)
	local radius_d = math.floor(hash(seed, 7) * 18)
	local blur = (seed % 6 == 0) and (4 + math.floor(hash(seed, 8) * 14)) or 0
	local outline = (seed % 5 == 0) and (1 + hash(seed, 9) * 2.5) or 0
	local use_texture = seed % 2 == 0
	local gradient = gradients[(seed % #gradients) + 1]
	local swizzle_mode = swizzle_modes[(seed % #swizzle_modes) + 1]
	local alpha_multiplier = 0.75 + hash(seed, 10) * 0.5
	local offset_x = (hash(seed, 11) - 0.5) * 6
	local offset_y = (hash(seed, 12) - 0.5) * 6
	local uv_x = (time * (8 + layer * 3) + seed * 3) % 96
	local uv_y = (time * (5 + layer * 2) + seed * 7) % 96
	render2d.SetColor(0.16 + hue_a * 0.84, 0.12 + hue_b * 0.74, 0.18 + hue_c * 0.72, alpha)
	render2d.SetAlphaMultiplier(alpha_multiplier)
	render2d.SetBorderRadius(radius_a, radius_b, radius_c, radius_d)
	render2d.SetBlur(blur)
	render2d.SetOutlineWidth(outline)
	render2d.SetSDFGradientTexture(gradient)

	if use_texture then
		render2d.SetTexture(checker_texture)
		render2d.SetUV(uv_x, uv_y, 36 + layer * 10, 36 + layer * 8, 96, 96)
		render2d.SetSwizzleMode(swizzle_mode)
	else
		render2d.SetTexture(nil)
		render2d.SetUV(nil)
		render2d.SetSwizzleMode(0)
	end

	render2d.DrawRect(x + offset_x, y + offset_y, w, h)
end

local function draw_background(width, height, time)
	reset_rect_state()
	render2d.SetColor(0.03, 0.035, 0.05, 1)
	render2d.DrawRect(0, 0, width, height)

	for band = 0, 6 do
		local t = band / 6
		local wobble = math.sin(time * 0.25 + band * 0.8) * 18
		render2d.SetColor(0.08 + t * 0.12, 0.11 + t * 0.08, 0.18 + t * 0.14, 0.12)
		render2d.SetBorderRadius(26)
		render2d.DrawRect(24 + band * 12, 32 + band * 18 + wobble, width - 48 - band * 24, 72)
	end

	reset_rect_state()
end

local function draw_rect_stress(width, height, time)
	local columns = 26
	local rows = 14
	local margin_x = 28
	local margin_y = 28
	local gap = 6
	local cell_w = math.floor((width - margin_x * 2 - gap * (columns - 1)) / columns)
	local cell_h = math.floor((height - margin_y * 2 - gap * (rows - 1)) / rows)
	local index = 0

	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			local cell_x = margin_x + column * (cell_w + gap)
			local cell_y = margin_y + row * (cell_h + gap)
			local inset = 2 + (index % 3)
			draw_stateful_rect(cell_x, cell_y, cell_w, cell_h, index, 1, time)
			draw_stateful_rect(
				cell_x + inset,
				cell_y + inset,
				cell_w - inset * 2,
				cell_h - inset * 2,
				index,
				2,
				time
			)

			if index % 4 == 0 then
				draw_stateful_rect(
					cell_x + 4,
					cell_y + 4,
					cell_w - 8,
					math.max(10, math.floor(cell_h * 0.34)),
					index,
					3,
					time
				)
			end

			index = index + 1
		end
	end
end

event.AddListener("Draw2D", "render2d_rect_batch_stress", function(dt)
	time_accum = time_accum + dt
	local width, height = render2d.GetSize()

	with_rect_batch_mode("instanced", function()
		reset_rect_state()
		draw_background(width, height, time_accum)
		draw_rect_stress(width, height, time_accum)
		reset_rect_state()
	end)
end)
