local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local Color = import("goluwa/structs/color.lua")

local function region_has_alpha_below(tex, min_x, min_y, max_x, max_y, max_alpha)
	for y = min_y, max_y do
		for x = min_x, max_x do
			local _, _, _, a = tex:GetPixel(x, y)

			if a / 255 <= max_alpha then return true end
		end
	end

	return false
end

local function region_has_alpha_above(tex, min_x, min_y, max_x, max_y, min_alpha)
	for y = min_y, max_y do
		for x = min_x, max_x do
			local _, _, _, a = tex:GetPixel(x, y)

			if a / 255 >= min_alpha then return true end
		end
	end

	return false
end

T.Test2D("sdf font", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 256,
		Unique = true,
	}
	render2d.SetTexture(nil)
	render2d.DrawRect(500, 500, 5, 5)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		local tex = render.target:GetTexture()
		T.AssertScreenPixel{
			pos = {48, 99},
			color = {1, 1, 1, 1},
			tolerance = 0.5,
		}
		assert(
			region_has_alpha_above(tex, 12, 12, 120, 220, 0.7),
			"expected opaque SDF glyph pixels"
		)
		assert(
			region_has_alpha_below(tex, 12, 12, 120, 220, 0.2),
			"expected transparent pixels around SDF glyph shape"
		)
	end
end)

T.Test2D("sdf font ignores ambient sample uv mode", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 256,
		Unique = true,
	}
	render2d.SetSampleUVMode(3)
	render2d.SetTexture(nil)
	render2d.DrawRect(500, 500, 5, 5)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		local tex = render.target:GetTexture()
		T.AssertScreenPixel{
			pos = {48, 99},
			color = {1, 1, 1, 1},
			tolerance = 0.5,
		}
		assert(
			region_has_alpha_above(tex, 12, 12, 120, 220, 0.7),
			"expected opaque SDF glyph pixels with dirty sample uv mode"
		)
		assert(
			region_has_alpha_below(tex, 12, 12, 120, 220, 0.2),
			"expected transparent pixels around SDF glyph shape with dirty sample uv mode"
		)
	end
end)

T.Test2D("sdf font small size remains visible", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 14,
		Unique = true,
	}
	render2d.SetTexture(nil)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hello", 10, 20)
	return function()
		local tex = render.target:GetTexture()
		assert(
			region_has_alpha_above(tex, 8, 8, 80, 40, 0.2),
			"expected visible pixels for small SDF text"
		)
	end
end)

T.Test2D("sdf font ignores ambient blend mode", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 64,
		Unique = true,
	}
	render2d.SetBlendPreset("none")
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		local tex = render.target:GetTexture()
		assert(
			region_has_alpha_above(tex, 12, 12, 120, 120, 0.4),
			"expected visible pixels for SDF text with dirty blend mode"
		)
	end
end)

T.Test2D("sdf font ignores ambient gradient texture", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 64,
		Unique = true,
	}
	local transparent_gradient = render2d.CreateGradient{
		mode = "linear",
		stops = {
			{pos = 0, color = Color(0, 0, 0, 0)},
			{pos = 1, color = Color(0, 0, 0, 0)},
		},
	}
	render2d.SetSDFGradientTexture(transparent_gradient)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		local tex = render.target:GetTexture()
		assert(
			region_has_alpha_above(tex, 12, 12, 120, 120, 0.4),
			"expected visible pixels for SDF text with dirty gradient texture"
		)
	end
end)

T.Test2D("sdf font ignores ambient threshold blur and outline", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 64,
		Unique = true,
	}
	render2d.SetSDFThreshold(4)
	render2d.SetBlur(18)
	render2d.SetOutlineWidth(6)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		local tex = render.target:GetTexture()
		assert(
			region_has_alpha_above(tex, 12, 12, 120, 120, 0.4),
			"expected visible pixels for SDF text with dirty threshold blur and outline"
		)
	end
end)

T.Test2D("sdf font ignores ambient disable rect sdf", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 64,
		Unique = true,
	}
	render2d.SetDisableRectSDF(true)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		local tex = render.target:GetTexture()
		assert(
			region_has_alpha_above(tex, 12, 12, 120, 120, 0.4),
			"expected visible pixels for SDF text with ambient disable_rect_sdf enabled"
		)
	end
end)

do
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 64,
		Unique = true,
	}

	T.Test2DFrames(
		"sdf font uses rect batching",
		3,
		function(width, height, frame)
			render2d.SetColor(0, 0, 0, 1)
			render2d.DrawRect(0, 0, width, height)

			if frame == 1 then
				font:GetTextSize("RectStats")
				return
			end

			if frame == 2 then
				render2d.SetColor(1, 1, 1, 1)
				font:DrawText("RectStats", 20, 20)
				local state = render2d.GetBatchState()
				T(state.pending_draws)[">"](0)
				T(#state.segments)[">"](0)
				local found_font_entry = false

				for _, segment in ipairs(state.segments) do
					for _, entry in ipairs(segment.entries) do
						if entry.state.texture ~= nil then
							T(bit.band(entry.state.rect_state_snapshot.flags, 0xF))["=="](10)
							found_font_entry = true

							break
						end
					end

					if found_font_entry then break end
				end

				T(found_font_entry)["=="](true)
			end
		end,
		function(width, height, frame)
			if frame ~= 3 then return end

			local last_flush = render2d.GetBatchState().last_flush
			T((last_flush.instanced_draws or 0))[">"](0)
			T((last_flush.gpu_rect_draw_calls or 0))[">"](0)
			T((last_flush.queued_draws or 0))[">"](0)
		end
	)
end
