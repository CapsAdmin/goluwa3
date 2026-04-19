local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
return function(opts)
	local primary = opts.primary or Color.FromHex("#334155")
	local default_font_path = opts.default_font_path

	local function copy_table(tbl)
		local out = {}

		for key, value in pairs(tbl or {}) do
			out[key] = value
		end

		return out
	end

	local function merge_tables(base_tbl, override_tbl)
		local merged = copy_table(base_tbl)

		for key, value in pairs(override_tbl or {}) do
			merged[key] = value
		end

		return merged
	end

	local function extend_preset(base_preset, overrides)
		local preset = copy_table(base_preset)
		overrides = overrides or {}
		preset.colors = merge_tables(base_preset.colors, overrides.colors)
		preset.sizes = merge_tables(base_preset.sizes, overrides.sizes)
		preset.font_sizes = merge_tables(base_preset.font_sizes, overrides.font_sizes)
		preset.font_styles = merge_tables(base_preset.font_styles, overrides.font_styles)
		preset.font_cache = {}

		for key, value in pairs(overrides) do
			if
				key ~= "colors" and
				key ~= "sizes" and
				key ~= "font_sizes" and
				key ~= "font_styles"
			then
				preset[key] = value
			end
		end

		return preset
	end

	local palette = Color.BuildPallete(
		{
			Color.FromHex("#f8fafc"),
			Color.FromHex("#cbd5e1"),
			Color.FromHex("#0f172a"),
		},
		{
			red = Color.FromHex("#dc2626"),
			yellow = Color.FromHex("#d97706"),
			blue = Color.FromHex("#2563eb"),
			green = Color.FromHex("#16a34a"),
			purple = Color.FromHex("#7c3aed"),
			brown = Color.FromHex("#8b5e3c"),
		}
	)
	local colors = merge_tables(
		palette,
		{
			dashed_underline = Color(0.2, 0.2, 0.2, 0.18),
			button_color = primary,
			underline = primary,
			url_color = primary,
			text_selection = Color.FromHex("#bfdbfe"):SetAlpha(0.85),
			actual_black = Color(0, 0, 0, 1),
			primary = primary,
			secondary = Color.FromHex("#e2e8f0"),
			positive = palette.green,
			neutral = palette.yellow,
			negative = palette.red,
			heading = Color.FromHex("#0f172a"),
			default = Color.FromHex("#0f172a"),
			text_foreground = Color.FromHex("#0f172a"),
			text_button = Color.FromHex("#0f172a"),
			foreground = Color.FromHex("#0f172a"),
			background = Color.FromHex("#f8fafc"),
			text_background = Color.FromHex("#ffffff"),
			main_background = Color.FromHex("#f1f5f9"),
			surface = Color.FromHex("#ffffff"),
			surface_variant = Color.FromHex("#e2e8f0"),
			card = Color.FromHex("#ffffff"),
			scrollbar_track = Color(0, 0, 0, 0.08),
			scrollbar = Color(0.1, 0.16, 0.22, 0.35),
			frame_border = Color.FromHex("#cbd5e1"),
			invisible = Color(0, 0, 0, 0),
			clickable_disabled = Color.FromHex("#cbd5e1"),
			button_normal = primary,
		}
	)
	colors.text_disabled = colors.text_foreground:Copy():SetAlpha(0.45)

	local function create_runtime(theme)
		local runtime = {panels = {}, icons = {}}

		local function set_color(color, alpha_multiplier)
			alpha_multiplier = alpha_multiplier or 1
			render2d.SetColor(color.r, color.g, color.b, color.a * alpha_multiplier)
		end

		local function draw_round_rect(x, y, w, h, radius, color, alpha_multiplier)
			render2d.SetTexture(nil)
			set_color(color, alpha_multiplier)

			if radius > 0 then
				gfx.DrawRoundedRect(x, y, w, h, radius)
			else
				render2d.DrawRect(x, y, w, h)
			end
		end

		local function draw_round_outline(x, y, w, h, radius, color, alpha_multiplier, width)
			render2d.SetTexture(nil)
			set_color(color, alpha_multiplier)
			render2d.PushBorderRadius(radius)
			render2d.PushOutlineWidth(width or 1)
			render2d.DrawRect(x, y, w, h)
			render2d.PopOutlineWidth()
			render2d.PopBorderRadius()
		end

		function runtime.icons.disclosure(pnl, opts)
			opts = opts or {}
			local size = opts.size or 10
			local thickness = opts.thickness or 2
			local progress = opts.open_fraction or 0
			local color = opts.color or theme.GetColor("text_foreground")
			local center = pnl.transform:GetSize() / 2
			local half = size / 2
			render2d.PushMatrix()
			render2d.Translatef(center.x, center.y)
			render2d.Rotate(math.rad(progress * 90))
			render2d.SetColor(color:Unpack())
			render2d.SetTexture(nil)
			gfx.DrawLine(-half * 0.7, -half, half * 0.7, 0, thickness)
			gfx.DrawLine(-half * 0.7, half, half * 0.7, 0, thickness)
			render2d.PopMatrix()
		end

		function runtime.icons.dropdown_indicator(pnl, opts)
			opts = opts or {}
			local size = opts.size or 8
			local thickness = opts.thickness or 2
			local color = opts.color or theme.GetColor("text_foreground")
			local center = pnl.transform:GetSize() / 2
			local half = size / 2
			render2d.SetColor(color:Unpack())
			render2d.SetTexture(nil)
			gfx.DrawLine(center.x - half, center.y - half * 0.3, center.x, center.y + half * 0.5, thickness)
			gfx.DrawLine(center.x, center.y + half * 0.5, center.x + half, center.y - half * 0.3, thickness)
		end

		function runtime.icons.close(pnl, opts)
			opts = opts or {}
			local size = opts.size or 8
			local thickness = opts.thickness or 2
			local color = opts.color or theme.GetColor("text_foreground")
			local center = pnl.transform:GetSize() / 2
			local half = size / 2
			render2d.SetColor(color:Unpack())
			render2d.SetTexture(nil)
			gfx.DrawLine(center.x - half, center.y - half, center.x + half, center.y + half, thickness)
			gfx.DrawLine(center.x - half, center.y + half, center.x + half, center.y - half, thickness)
		end

		function runtime.UpdateButtonAnimations(pnl, state)
			if not pnl or not state then return end

			local anim = state.anim
			local hovered = state.hovered and not state.disabled
			local pressed = hovered and state.pressed

			if hovered ~= anim.last_hovered then
				pnl.animation:Animate{
					id = "glow_alpha",
					get = function()
						return anim.glow_alpha
					end,
					set = function(value)
						anim.glow_alpha = value
					end,
					to = hovered and 1 or 0,
					interpolation = "inOutSine",
					time = 0.12,
				}
				anim.last_hovered = hovered
			end

			if pressed ~= anim.last_pressed then
				pnl.animation:Animate{
					id = "press_scale",
					get = function()
						return anim.press_scale
					end,
					set = function(value)
						anim.press_scale = value
					end,
					to = pressed and 1 or 0,
					interpolation = "inOutSine",
					time = 0.08,
				}
				pnl.animation:Animate{
					id = "DrawScaleOffset",
					get = function()
						return pnl.transform:GetDrawScaleOffset()
					end,
					set = function(value)
						pnl.transform:SetDrawScaleOffset(value)
					end,
					to = pressed and (Vec2() + 0.985) or (Vec2(1, 1)),
					interpolation = "inOutSine",
					time = 0.08,
				}
				anim.last_pressed = pressed
			end
		end

		function runtime.UpdateSliderAnimations(pnl, state)
			local anim = state.anim

			if state.hovered ~= anim.last_hovered then
				pnl.animation:Animate{
					id = "glow_alpha",
					get = function()
						return anim.glow_alpha
					end,
					set = function(value)
						anim.glow_alpha = value
					end,
					to = state.hovered and 1 or 0,
					interpolation = "inOutSine",
					time = 0.15,
				}
				pnl.animation:Animate{
					id = "knob_scale",
					get = function()
						return anim.knob_scale
					end,
					set = function(value)
						anim.knob_scale = value
					end,
					to = state.hovered and 1.2 or 1,
					interpolation = {
						type = "spring",
						bounce = 0.5,
						duration = 80,
					},
				}
				anim.last_hovered = state.hovered
			end
		end

		function runtime.UpdateCheckboxAnimations(pnl, state)
			local anim = state.anim

			if state.hovered ~= anim.last_hovered then
				pnl.animation:Animate{
					id = "glow_alpha",
					get = function()
						return anim.glow_alpha
					end,
					set = function(value)
						anim.glow_alpha = value
					end,
					to = state.hovered and 1 or 0,
					interpolation = "inOutSine",
					time = 0.15,
				}
				anim.last_hovered = state.hovered
			end

			if state.value ~= anim.last_value then
				pnl.animation:Animate{
					id = "check_anim",
					get = function()
						return anim.check_anim
					end,
					set = function(value)
						anim.check_anim = value
					end,
					to = state.value and 1 or 0,
					interpolation = {
						type = "spring",
						bounce = 0.4,
						duration = 100,
					},
				}
				anim.last_value = state.value
			end
		end

		function runtime.panels.button(pnl, state)
			local anim = state.anim
			local owner = pnl.Owner
			local size = owner.transform.Size
			local radius = math.max(4, math.floor(size.y * 0.18))
			local fill
			local border = theme.GetColor("frame_border")

			if state.disabled then
				fill = theme.GetColor("clickable_disabled")
			elseif state.mode == "outline" then
				fill = theme.GetColor("surface")
			elseif state.pressed then
				fill = theme.GetColor("secondary")
			elseif state.active then
				fill = theme.GetColor("surface_variant")
			elseif state.hovered then
				fill = theme.GetColor("surface_variant")
			else
				fill = theme.GetColor("surface")
			end

			if state.mode == "outline" then
				draw_round_rect(0, 0, size.x, size.y, radius, fill, 0.35 + anim.glow_alpha * 0.15)
			else
				draw_round_rect(0, 0, size.x, size.y, radius, fill)
			end

			if state.active and not state.disabled then
				draw_round_outline(0, 0, size.x, size.y, radius, theme.GetColor("primary"), 0.6, 1)
			else
				draw_round_outline(0, 0, size.x, size.y, radius, border, 0.9, 1)
			end
		end

		function runtime.panels.surface(pnl)
			local size = pnl.Owner.transform.Size + pnl.Owner.transform.DrawSizeOffset
			local color = pnl.Color + pnl.DrawColor
			local radius = pnl:GetBorderRadius()
			draw_round_rect(0, 0, size.x, size.y, radius, color, pnl.DrawAlpha)
		end

		function runtime.panels.button_post(pnl, state)
			local anim = state.anim

			if not state.hovered or state.disabled then return end

			local size = pnl.Owner.transform.Size
			local radius = math.max(4, math.floor(size.y * 0.18))
			draw_round_outline(0, 0, size.x, size.y, radius, theme.GetColor("primary"), anim.glow_alpha * 0.5, 1)
		end

		function runtime.panels.slider(pnl, state)
			local owner = pnl.Owner
			local anim = state.anim

			if state.hovered then runtime.UpdateSliderAnimations(owner, state) end

			local size = owner.transform.Size
			local knob_w = theme.GetSize("S")
			local knob_h = theme.GetSize("S")
			local track = theme.GetColor("surface_variant")
			local accent = theme.GetColor("primary")
			local border = theme.GetColor("frame_border")
			local value = state.value
			local min_value = state.min
			local max_value = state.max
			local knob_x = 0
			local knob_y = 0

			if state.mode == "2d" then
				local normalized_x = (value.x - min_value.x) / (max_value.x - min_value.x)
				local normalized_y = (value.y - min_value.y) / (max_value.y - min_value.y)
				draw_round_rect(0, 0, size.x, size.y, 6, theme.GetColor("surface"))
				draw_round_outline(0, 0, size.x, size.y, 6, border, 1, 1)
				knob_x = normalized_x * (size.x - knob_w)
				knob_y = normalized_y * (size.y - knob_h)
			elseif state.mode == "vertical" then
				local normalized = (value - min_value) / (max_value - min_value)
				local track_w = theme.GetSize("XXS")
				local track_x = (size.x - track_w) / 2
				draw_round_rect(track_x, knob_h / 2, track_w, size.y - knob_h, track_w / 2, track)
				draw_round_rect(track_x, knob_h / 2, track_w, normalized * (size.y - knob_h), track_w / 2, accent)
				knob_x = (size.x - knob_w) / 2
				knob_y = normalized * (size.y - knob_h)
			else
				local normalized = (value - min_value) / (max_value - min_value)
				local track_h = theme.GetSize("XXS")
				local track_y = (size.y - track_h) / 2
				draw_round_rect(knob_w / 2, track_y, size.x - knob_w, track_h, track_h / 2, track)
				draw_round_rect(knob_w / 2, track_y, normalized * (size.x - knob_w), track_h, track_h / 2, accent)
				knob_x = normalized * (size.x - knob_w)
				knob_y = (size.y - knob_h) / 2
			end

			local scaled_w = knob_w * anim.knob_scale
			local scaled_h = knob_h * anim.knob_scale
			local offset_x = (scaled_w - knob_w) / 2
			local offset_y = (scaled_h - knob_h) / 2
			draw_round_rect(
				knob_x - offset_x,
				knob_y - offset_y,
				scaled_w,
				scaled_h,
				math.floor(scaled_h / 2),
				theme.GetColor("surface")
			)
			draw_round_outline(
				knob_x - offset_x,
				knob_y - offset_y,
				scaled_w,
				scaled_h,
				math.floor(scaled_h / 2),
				border,
				1,
				1
			)

			if state.hovered then
				draw_round_outline(
					knob_x - offset_x,
					knob_y - offset_y,
					scaled_w,
					scaled_h,
					math.floor(scaled_h / 2),
					accent,
					anim.glow_alpha * 0.45,
					1
				)
			end
		end

		function runtime.panels.checkbox(pnl, state)
			local anim = state.anim

			if state.hovered then runtime.UpdateCheckboxAnimations(pnl, state) end

			local size = pnl.transform.Size
			local box_size = theme.GetSize("M")
			local x = 0
			local y = (size.y - box_size) / 2
			draw_round_rect(x, y, box_size, box_size, 4, theme.GetColor("surface"))
			draw_round_outline(x, y, box_size, box_size, 4, theme.GetColor("frame_border"), 1, 1)

			if anim.check_anim > 0.01 then
				local inset = 3 + (1 - anim.check_anim) * 3
				draw_round_rect(
					x + inset,
					y + inset,
					box_size - inset * 2,
					box_size - inset * 2,
					2,
					theme.GetColor("primary"),
					anim.check_anim
				)
			end
		end

		function runtime.panels.button_radio(pnl, state)
			local anim = state.anim

			if state.hovered then runtime.UpdateCheckboxAnimations(pnl, state) end

			local size = pnl.transform.Size
			local box_size = theme.GetSize("M")
			local x = 0
			local y = (size.y - box_size) / 2
			local radius = math.floor(box_size / 2)
			draw_round_rect(x, y, box_size, box_size, radius, theme.GetColor("surface"))
			draw_round_outline(x, y, box_size, box_size, radius, theme.GetColor("frame_border"), 1, 1)

			if anim.check_anim > 0.01 then
				local dot = box_size * 0.42 * anim.check_anim
				local dot_x = x + box_size / 2 - dot / 2
				local dot_y = y + box_size / 2 - dot / 2
				draw_round_rect(dot_x, dot_y, dot, dot, math.floor(dot / 2), theme.GetColor("primary"))
			end
		end

		function runtime.panels.frame(pnl, emphasis)
			local size = pnl.transform.Size + pnl.transform.DrawSizeOffset
			local color = pnl.gui_element.Color + pnl.gui_element.DrawColor
			local radius = theme.GetSize("XS")
			draw_round_rect(0, 0, size.x, size.y, radius, color, pnl.gui_element.DrawAlpha)

			if emphasis and emphasis > 1 then
				draw_round_outline(0, 0, size.x, size.y, radius, theme.GetColor("primary"), 0.08 * emphasis, 1)
			end
		end

		function runtime.panels.frame_post(pnl)
			local size = pnl.transform.Size + pnl.transform.DrawSizeOffset
			local radius = theme.GetSize("XS")
			draw_round_outline(
				0,
				0,
				size.x,
				size.y,
				radius,
				theme.GetColor("frame_border"),
				pnl.gui_element.DrawAlpha,
				1
			)
		end

		function runtime.panels.menu_spacer(pnl, vertical)
			local size = pnl.Owner.transform:GetSize()
			set_color(theme.GetColor("frame_border"), 0.8)
			render2d.SetTexture(nil)

			if vertical then
				render2d.DrawRect(size.x / 2, 0, 1, size.y)
			else
				render2d.DrawRect(0, size.y / 2, size.x, 1)
			end
		end

		function runtime.panels.header(pnl)
			local size = pnl.transform.Size
			draw_round_rect(
				0,
				0,
				size.x,
				size.y,
				0,
				theme.GetColor("surface_variant"),
				pnl.gui_element.DrawAlpha
			)
			set_color(theme.GetColor("frame_border"), pnl.gui_element.DrawAlpha)
			render2d.SetTexture(nil)
			render2d.DrawRect(0, size.y - 1, size.x, 1)
		end

		function runtime.panels.progress_bar(pnl, state)
			local size = pnl.Owner.transform.Size
			local value = math.clamp(state.value or 0, 0, 1)
			local color = pnl.Owner.gui_element.Color or theme.GetColor("primary")
			local radius = math.floor(size.y / 2)
			draw_round_rect(0, 0, size.x, size.y, radius, theme.GetColor("surface_variant"))
			draw_round_rect(0, 0, size.x * value, size.y, radius, color)
			draw_round_outline(0, 0, size.x, size.y, radius, theme.GetColor("frame_border"), 1, 1)
		end

		function runtime.panels.divider(pnl)
			local size = pnl.transform.Size
			set_color(theme.GetColor("frame_border"), pnl.gui_element.DrawAlpha)
			render2d.SetTexture(nil)

			if size.x > size.y then
				render2d.DrawRect(0, math.floor(size.y / 2), size.x, 1)
			else
				render2d.DrawRect(math.floor(size.x / 2), 0, 1, size.y)
			end
		end

		return runtime
	end

	return {
		preset = {
			label = "Base",
			colors = colors,
			sizes = {
				none = 0,
				line = 1,
				XXXS = 4,
				XXS = 6,
				XS = 8,
				S = 12,
				M = 14,
				L = 18,
				XL = 24,
				XXL = 32,
				default = 14,
				line_height = 4,
			},
			font_sizes = {
				XS = 10,
				S = 12,
				M = 14,
				L = 18,
				XL = 24,
				XXL = 30,
				XXXL = 38,
			},
			font_styles = {
				heading = {Path = default_font_path},
				body_weak = {Path = default_font_path},
				body = {Path = default_font_path},
				body_strong = {Path = default_font_path},
			},
			font_cache = {},
		},
		extend_preset = extend_preset,
		create_runtime = create_runtime,
	}
end
