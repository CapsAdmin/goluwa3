local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local system = import("goluwa/system.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local build_base_theme = import("./base.lua")
local primary = Color.FromHex("#062a67"):SetAlpha(0.9)
local base = build_base_theme{
	primary = Color.FromHex("#334155"),
	default_font_path = fonts.GetDefaultSystemFontPath(),
}

do
	local palette = Color.BuildPalette(
		{
			Color.FromHex("#cccccc"),
			primary,
			primary:Darken(2),
		},
		{
			red = Color.FromHex("#dd4546"),
			yellow = Color.FromHex("#e0c33d"),
			blue = primary,
			green = Color.FromHex("#69ce4a"),
			purple = Color.FromHex("#a454d8"),
			brown = Color.FromHex("#a17247"),
		}
	)
	local colors = {}

	for key, value in pairs(palette) do
		colors[key] = value
	end

	for key, value in pairs{
		dashed_underline = Color(0.37, 0.37, 0.37, 0.25),
		button_color = palette.blue,
		underline = palette.blue,
		url_color = palette.blue,
		property_selection = Color.FromHex("#5d8cff"):SetAlpha(0.9),
		actual_black = Color(0, 0, 0, 1),
		primary = palette.blue,
		secondary = palette.green,
		positive = palette.green_lighter,
		neutral = palette.yellow_lighter,
		negative = palette.red_darker,
		heading = palette.white,
		default = palette.white,
		text_foreground = palette.white,
		text_button = palette.white,
		foreground = palette.black,
		background = palette.black,
		text_background = palette.black,
		main_background = palette.black,
		surface = palette.darkest,
		surface_variant = palette.dark,
		card = palette.darkest,
		scrollbar_track = Color(1, 1, 1, 0.08),
		scrollbar = Color(1, 1, 1, 0.45),
		frame_border = Color(0.106, 0.463, 0.678),
		invisible = Color(0, 0, 0, 0),
		clickable_disabled = Color(0.3, 0.3, 0.3, 1),
		button_normal = Color(0.8, 0.8, 0.2, 1),
	} do
		colors[key] = value
	end

	colors.text_disabled = colors.text_foreground:Copy():SetAlpha(0.5)
	local preset = base.extend_preset(
		base.preset,
		{
			label = "JRPG",
			colors = colors,
			sizes = {
				XXS = 7,
				S = 14,
				M = 16,
				L = 20,
				XL = 30,
				XXL = 40,
				default = 16,
			},
			font_sizes = {
				XS = 10,
				S = 12,
				M = 14,
				L = 20,
				XL = 27,
				XXL = 32,
				XXXL = 42,
			},
			font_styles = {
				heading = {"Orbitron", "Bold"},
				body_weak = {"Exo", "Bold"},
				body = {"Exo", "Regular"},
				body_strong = {"Exo", "Bold"},
			},
		}
	)

	local function create_runtime(theme)
		local runtime = {panels = {}, icons = {}}
		local base_runtime = base.create_runtime(theme)
		local assets = import("goluwa/assets.lua")
		local Textures = {
			GlowLinear = assets.GetTexture("textures/render/glow_linear.lua"),
			GlowPoint = assets.GetTexture("textures/render/glow_point.lua"),
			Gradient = assets.GetTexture("textures/render/gradient_linear.lua"),
		}
		local glow_line = assets.GetTexture(
			"textures/render/glow_line.lua",
			{
				config = {
					core_thickness = 1,
					glow_radius = 9,
					glow_intensity = 0.2,
				},
			}
		)
		local gradient_classic = Texture.New{
			width = 16,
			height = 16,
			format = "r8g8b8a8_unorm",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		local start = Color.FromHex("#060086")
		local stop = Color.FromHex("#04013e")
		gradient_classic:Shade(
			[[
			float dist = distance(uv, vec2(0.5));
				return vec4(mix(vec3(]] .. start.r .. ", " .. start.g .. ", " .. start.b .. "), vec3(" .. stop.r .. ", " .. stop.g .. ", " .. stop.b .. [[), -uv.y + 1.0), 1.0);
		]]
		)
		local metal_frame = assets.GetTexture(
			"textures/render/metal_frame.lua",
			{
				config = {base_color = Color.FromHex("#8f8b92")},
			}
		)
		local metal_frame_white = assets.GetTexture(
			"textures/render/metal_frame.lua",
			{
				config = {
					base_color = Color.FromHex("#8f8b92"),
					frame_inner = 0.02,
					frame_outer = 0.002,
					corner_radius = 0.02,
				},
			}
		)

		function runtime.DrawDiamond(x, y, size)
			render2d.PushMatrix()
			render2d.Translatef(x, y)
			render2d.Rotate(math.rad(45))
			render2d.DrawRectf(-size / 2, -size / 2, size, size)
			render2d.PopMatrix()
		end

		function runtime.DrawDiamond2(x, y, size)
			runtime.DrawDiamond(x, y, size / 3)
			render2d.PushOutlineWidth(1)
			runtime.DrawDiamond(x, y, size)
			render2d.PopOutlineWidth()
		end

		function runtime.DrawPill(x, y, w, h)
			x = x - 15
			w = w + 30
			render2d.PushBorderRadius(h)
			render2d.DrawRect(x, y, w, h)
			render2d.SetBorderRadius(h / 2)
			render2d.PushOutlineWidth(1)
			render2d.PushBlendMode("additive")
			render2d.PushAlphaMultiplier(1)
			render2d.DrawRect(x, y, w, h)
			render2d.PopAlphaMultiplier()
			render2d.PopBlendMode()
			render2d.PopOutlineWidth()
			render2d.PopBorderRadius()
			runtime.DrawDiamond2(x, y + h / 2, 5)
			runtime.DrawDiamond2(x + w, y + h / 2, 5)
		end

		function runtime.DrawBadge(x, y, w, h)
			x = x - 15
			w = w + 30
			render2d.PushTexture(Textures.Gradient)
			render2d.PushUV()
			render2d.SetUV2(-0.1, 0, 0.75, 1)
			render2d.PushBorderRadius(h)
			render2d.DrawRect(x, y, w, h)
			render2d.PopBorderRadius()
			render2d.PopUV()
			render2d.PopTexture()
			render2d.PushColor(1, 1, 1, 1)
			runtime.DrawDiamond2(x + 8, y + h / 2, 8)
			render2d.PopColor()
		end

		function runtime.DrawArrow(x, y, size)
			local f = size / 2
			render2d.PushBorderRadius(f * 3, f * 2, f * 2, f * 3)
			render2d.PushMatrix()
			render2d.Translatef(x - size / 3, y - size / 3)
			render2d.Scalef(1.6, 0.75)
			render2d.DrawRectf(0, 0, size, size)
			render2d.PopMatrix()
			render2d.PopBorderRadius()
			runtime.DrawDiamond(x, y + 0.5, size / 2)
		end

		function runtime.icons.disclosure(pnl, opts)
			opts = opts or {}
			local size = opts.size or 10
			local progress = opts.open_fraction or 0
			local color = opts.color or theme.GetColor("text_foreground")
			local center = pnl.transform:GetSize() / 2
			render2d.PushMatrix()
			render2d.Translatef(center.x, center.y)
			render2d.Rotate(math.rad(progress * 90))
			render2d.SetColor(color:Unpack())
			render2d.SetTexture(nil)
			runtime.DrawArrow(0, 0, size)
			render2d.PopMatrix()
		end

		function runtime.icons.dropdown_indicator(pnl, opts)
			opts = opts or {}
			local size = opts.size or 9
			local color = opts.color or theme.GetColor("text_foreground")
			local center = pnl.transform:GetSize() / 2
			render2d.PushMatrix()
			render2d.Translatef(center.x, center.y + 1)
			render2d.Rotate(math.rad(90))
			render2d.SetColor(color:Unpack())
			render2d.SetTexture(nil)
			runtime.DrawArrow(0, 0, size)
			render2d.PopMatrix()
		end

		function runtime.icons.close(pnl, opts)
			opts = opts or {}
			local size = opts.size or 8
			local color = opts.color or theme.GetColor("text_foreground")
			local center = pnl.transform:GetSize() / 2
			local half = size / 2
			render2d.SetColor(color:Unpack())
			render2d.SetTexture(nil)
			runtime.DrawLine(center.x - half, center.y - half, center.x + half, center.y + half, 1.5)
			runtime.DrawLine(center.x - half, center.y + half, center.x + half, center.y - half, 1.5)
		end

		function runtime.DrawLine(x1, y1, x2, y2, thickness)
			local angle = math.atan2(y2 - y1, x2 - x1)
			local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
			local s = thickness * 2
			runtime.DrawDiamond(x1, y1, s)
			runtime.DrawDiamond(x2, y2, s)
			render2d.PushMatrix()
			render2d.Translatef(x1, y1)
			render2d.Rotate(angle)
			render2d.DrawRect(0, -thickness / 2, length, thickness)
			render2d.PopMatrix()
		end

		function runtime.DrawLine2(x1, y1, x2, y2, thickness)
			local angle = math.atan2(y2 - y1, x2 - x1)
			local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
			local s = thickness * 4
			render2d.PushMatrix()
			render2d.Translatef(x1, y1 + 1)
			render2d.Rotate(math.pi)
			runtime.DrawArrow(0, 0, s)
			render2d.PopMatrix()
			runtime.DrawArrow(x2, y2, s)
			render2d.PushMatrix()
			render2d.Translatef(x1, y1)
			render2d.Rotate(angle)
			render2d.DrawRect(0, -thickness / 2, length, thickness)
			render2d.PopMatrix()
		end

		function runtime.DrawGlowLine(x1, y1, x2, y2, thickness)
			thickness = thickness or 1
			local angle = math.atan2(y2 - y1, x2 - x1)
			local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
			render2d.PushMatrix()
			render2d.Translatef(x1, y1)
			render2d.Rotate(angle)
			render2d.Translatef(0, -glow_line:GetHeight() / 2)
			render2d.SetTexture(glow_line)
			render2d.PushBlendMode("additive")
			render2d.DrawRectf(0, -thickness / 10, length, glow_line:GetHeight())
			render2d.PopBlendMode()
			render2d.PopMatrix()
		end

		function runtime.DrawClassicFrame(x, y, w, h)
			render2d.PushBorderRadius(h * 0.2)
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetTexture(gradient_classic)
			render2d.DrawRect(x, y, w, h)
			render2d.PopBorderRadius()
			render2d.PushOutlineWidth(5)
			render2d.PushBlur(10)
			render2d.SetColor(0, 0, 0, 0.5)
			render2d.SetTexture(nil)
			render2d.DrawRect(x, y, w, h)
			render2d.PopBlur()
			render2d.PopOutlineWidth()
			x = x - 3
			y = y - 3
			w = w + 6
			h = h + 6
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetNinePatchTable(metal_frame.nine_patch)
			render2d.SetTexture(metal_frame)
			render2d.DrawRect(x, y, w, h)
			render2d.ClearNinePatch()
			render2d.SetTexture(nil)
		end

		function runtime.DrawWhiteFrame(x, y, w, h)
			render2d.PushBorderRadius(h * 0.2)
			render2d.SetColor(1, 1, 1, 0.5)
			render2d.SetTexture(nil)
			render2d.DrawRect(x, y, w, h)
			x = x + 1
			y = y + 1
			w = w - 2
			h = h - 2
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetNinePatchTable(metal_frame_white.nine_patch)
			render2d.SetTexture(metal_frame_white)
			render2d.DrawRect(x, y, w, h)
			render2d.ClearNinePatch()
			render2d.SetTexture(nil)
			render2d.PushOutlineWidth(1)
			render2d.DrawRect(x + 1, y + 1, w - 2, h - 2)
			render2d.PopOutlineWidth()
			render2d.PopBorderRadius()
		end

		function runtime.DrawCircle(x, y, size, width)
			render2d.PushBorderRadius(size)
			render2d.PushOutlineWidth(width or 1)
			render2d.DrawRect(x - size, y - size, size * 2, size * 2)
			render2d.PopOutlineWidth()
			render2d.PopBorderRadius()
		end

		function runtime.DrawSimpleLine(x1, y1, x2, y2, thickness)
			local angle = math.atan2(y2 - y1, x2 - x1)
			local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
			render2d.PushMatrix()
			render2d.Translatef(x1, y1)
			render2d.Rotate(angle)
			render2d.DrawRectf(0, -thickness / 2, length, thickness)
			render2d.PopMatrix()
		end

		function runtime.DrawMagicCircle(x, y, size)
			render2d.PushBlur(size * 0.05)
			runtime.DrawCircle(x, y, size, 4)
			runtime.DrawCircle(x, y, size * 1.5)
			runtime.DrawCircle(x, y, size * 1.7)
			runtime.DrawCircle(x, y, size * 3)
			render2d.PopBlur()

			for i = 1, 8 do
				local angle = (i / 8) * math.pi * 2
				local length = size * 1.35
				local x1 = x + math.cos(angle) * length
				local y1 = y + math.sin(angle) * length
				runtime.DrawDiamond(x1, y1, 3)
			end

			for i = 1, 16 do
				local angle = (i / 16) * math.pi * 2
				local length = size * 1.35
				local x1 = x + math.cos(angle) * length
				local y1 = y + math.sin(angle) * length
				local x2 = x + math.cos(angle) * length * 1.5
				local y2 = y + math.sin(angle) * length * 1.5
				render2d.SetTexture(Textures.GlowLinear)
				runtime.DrawGlowLine(x1, y1, x2, y2, 1)
			end
		end

		function runtime.DrawGlow(x, y, size)
			render2d.PushTexture(Textures.GlowPoint)
			render2d.PushAlphaMultiplier(0.5)
			render2d.DrawRectf(x - size, y - size, size * 2, size * 2)
			render2d.PopAlphaMultiplier()
			render2d.PopTexture()
		end

		function runtime.DrawProgressBarPrimitive(x, y, w, h, progress, color)
			render2d.SetColor(0.2, 0.2, 0.3, 0.4)
			render2d.DrawRect(x, y, w, h)
			render2d.PushBlendMode("additive")
			render2d.SetColor(0.3, 0.4, 0.6, 0.5)
			runtime.DrawGlowLine(x, y, x + w, y, 2)
			runtime.DrawGlowLine(x, y + h, x + w, y + h, 2)
			render2d.SetColor(1, 1, 1, 0.1)

			for i = 1, 9 do
				render2d.DrawRect(x + (w / 10) * i, y, 1, h)
			end

			render2d.PopBlendMode()

			if progress > 0 then
				local fill_w = w * progress
				local center_y = y + h / 2
				local tip_x = x + fill_w
				render2d.PushTexture(Textures.Gradient)

				if color then
					render2d.SetColor(color.r, color.g, color.b, (color.a or 1) * 0.8)
				else
					render2d.SetColor(0.4, 0.7, 1, 0.8)
				end

				render2d.DrawRect(x, y, fill_w, h)
				render2d.PopTexture()
				render2d.PushBlendMode("additive")
				render2d.SetColor(1, 1, 1, 0.6)
				render2d.DrawRect(x, y, fill_w, 2)

				if color then
					render2d.SetColor(color.r, color.g, color.b, 1)
				else
					render2d.SetColor(0.6, 0.9, 1, 1)
				end

				runtime.DrawDiamond(tip_x, center_y, h * 0.8)

				if color then
					render2d.SetColor(color.r, color.g, color.b, 0.3)
				else
					render2d.SetColor(0.6, 0.9, 1, 0.3)
				end

				runtime.DrawDiamond(tip_x, center_y, h * 1.8)
				render2d.SetTexture(Textures.GlowLinear)
				render2d.SetColor(1, 1, 1, 1)
				render2d.PushMatrix()
				render2d.Translate(tip_x, center_y)
				render2d.Rotate(math.rad(90))
				render2d.DrawRect(-h, -1.5, h * 2, 3)
				render2d.PopMatrix()
				render2d.PopBlendMode()
				render2d.SetTexture(nil)
			end
		end

		do
			local glow_color = preset.colors.light or preset.colors.white or Color(1, 1, 1, 1)
			local gradient = Texture.New{
				width = 16,
				height = 16,
				format = "r8g8b8a8_unorm",
				sampler = {
					min_filter = "linear",
					mag_filter = "linear",
					wrap_s = "clamp_to_edge",
					wrap_t = "clamp_to_edge",
				},
			}
			local grad_start = preset.colors.primary
			local grad_stop = preset.colors.darkest or preset.colors.surface
			gradient:Shade(
				[[
				float dist = distance(uv, vec2(0.5));
					return mix(vec4(]] .. grad_start.r .. ", " .. grad_start.g .. ", " .. grad_start.b .. ", " .. grad_start.a .. [[), vec4(]] .. grad_stop.r .. ", " .. grad_stop.g .. ", " .. grad_stop.b .. ", " .. grad_stop.a .. [[), -uv.y + 1.0 + uv.x*0.3);
			]]
			)

			function runtime.DrawModernFrame(x, y, w, h)
				render2d.SetColor(1, 1, 1, 1)
				render2d.SetTexture(gradient)
				render2d.DrawRect(x, y, w, h)
			end

			function runtime.DrawModernFramePost(x, y, w, h, intensity)
				render2d.SetTexture(nil)
				x = x - 1
				y = y - 1
				w = w + 2
				h = h + 2
				render2d.SetColor(glow_color.r, glow_color.g, glow_color.b, 0.75 + intensity * 0.4)
				render2d.SetBlendMode("additive")
				local glow_size = 40 * intensity
				local diamond_size = 6 + 2 * intensity
				runtime.DrawDiamond2(x, y, diamond_size)
				runtime.DrawGlow(x, y, glow_size)
				runtime.DrawDiamond2(x + w, y, diamond_size)
				runtime.DrawGlow(x + w, y, glow_size)
				runtime.DrawDiamond2(x, y + h, diamond_size)
				runtime.DrawGlow(x, y + h, glow_size)
				runtime.DrawDiamond2(x + w, y + h, diamond_size)
				runtime.DrawGlow(x + w, y + h, glow_size)
				render2d.SetTexture(Textures.GlowLinear)
				local extent_h = -50 * intensity
				local extent_w = -50 * intensity
				render2d.SetBlendMode("alpha")
				runtime.DrawGlowLine(x + extent_w, y, x + w - extent_w, y, 1)
				runtime.DrawGlowLine(x + extent_w, y + h, x + w - extent_w, y + h, 1)
				runtime.DrawGlowLine(x, y + extent_h, x, y + h - extent_h, 1)
				runtime.DrawGlowLine(x + w, y + extent_h, x + w, y + h - extent_h, 1)
				render2d.SetTexture(nil)
			end
		end

		function runtime.DrawRect(x, y, w, h, thickness, extent)
			extent = extent or 0
			runtime.DrawLine(x - extent, y, x + w + extent, y, thickness)
			runtime.DrawLine(x + w, y - extent, x + w, y + h + extent, thickness)
			runtime.DrawLine(x + w + extent, y + h, x - extent, y + h, thickness)
			runtime.DrawLine(x, y + h + extent, x, y - extent, thickness)
		end

		function runtime.UpdateButtonAnimations(pnl, state)
			if not pnl or not state then return end

			local anim = state.anim
			local is_active = not state.disabled and
				(
					(
						state.hovered and
						state.pressed
					)
					or
					(
						state.active or
						false
					)
				)
			local is_tilting = is_active

			if is_active ~= anim.last_active then
				pnl.animation:Animate{
					id = "press_scale",
					get = function()
						return anim.press_scale
					end,
					set = function(value)
						anim.press_scale = value
					end,
					to = is_active and 1 or 0,
					interpolation = (state.pressed and not state.hovered) and "linear" or "inOutSine",
					time = (state.pressed and not state.hovered) and 0.2 or 0.1,
				}
				pnl.animation:Animate{
					id = "DrawScaleOffset",
					get = function()
						return pnl.transform:GetDrawScaleOffset()
					end,
					set = function(value)
						pnl.transform:SetDrawScaleOffset(value)
					end,
					to = is_active and (Vec2() + 0.97) or (Vec2(1, 1)),
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 100},
					time = (state.pressed and not state.hovered) and 0.2 or nil,
				}
				anim.last_active = is_active
			end

			if state.hovered ~= anim.last_hovered then
				pnl.animation:Animate{
					id = "glow_alpha",
					get = function()
						return anim.glow_alpha
					end,
					set = function(value)
						anim.glow_alpha = value
					end,
					to = (state.hovered and not state.disabled) and 1 or 0,
					interpolation = "inOutSine",
					time = 0.1,
				}
				anim.last_hovered = state.hovered
			end

			if is_tilting ~= anim.last_tilting or is_tilting then
				pnl.animation:Animate{
					id = "Pivot",
					get = function()
						return pnl.transform:GetPivot()
					end,
					set = function(value)
						pnl.transform:SetPivot(value)
					end,
					to = not is_tilting and
						Vec2(0.5, 0.5) or
						{
							__lsx_value = function(panel)
								local mpos = system.GetWindow():GetMousePosition()
								local local_pos = panel.transform:GlobalToLocal(mpos)
								local size = panel.transform:GetSize()
								local pivot = local_pos / size
								return -pivot + Vec2(1, 1)
							end,
						},
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 10},
					time = is_tilting and 0.3 or 10,
				}
				pnl.animation:Animate{
					id = "DrawAngleOffset",
					get = function()
						return pnl.transform:GetDrawAngleOffset()
					end,
					set = function(value)
						pnl.transform:SetDrawAngleOffset(value)
					end,
					to = not is_tilting and
						Ang3(0, 0, 0) or
						{
							__lsx_value = function(panel)
								local mpos = system.GetWindow():GetMousePosition()
								local local_pos = panel.transform:GlobalToLocal(mpos)
								local size = panel.transform:GetSize()
								local nx = (local_pos.x / size.x) * 2 - 1
								local ny = (local_pos.y / size.y) * 2 - 1
								return Ang3(-ny, nx, 0) * 0.01
							end,
						},
					interpolation = (
							state.pressed and
							not state.hovered
						)
						and
						"linear" or
						{type = "spring", bounce = 0.6, duration = 10},
					time = is_tilting and 0.3 or 10,
				}
				anim.last_tilting = is_tilting
			end
		end

		function runtime.UpdateSliderAnimations(pnl, state)
			return base_runtime.UpdateSliderAnimations(pnl, state)
		end

		function runtime.UpdateCheckboxAnimations(pnl, state)
			return base_runtime.UpdateCheckboxAnimations(pnl, state)
		end

		function runtime.panels.button(pnl, state)
			local anim = state.anim

			if state.hovered then runtime.UpdateButtonAnimations(pnl.Owner, state) end

			local size = pnl.Owner.transform.Size

			if state.mode == "filled" then
				render2d.PushUV()
				render2d.SetUV2(0, 0, 0.4, 1)
				render2d.PushBorderRadius(size.y / 6)
				render2d.SetTexture(Textures.Gradient)
				local col = pnl.Owner.gui_element.Color or theme.GetColor("primary")
				render2d.SetColor(col.r * anim.glow_alpha, col.g * anim.glow_alpha, col.b * anim.glow_alpha, 1)
				render2d.DrawRect(0, 0, size.x, size.y)
				render2d.PopBorderRadius()
				render2d.PopUV()
			end

			local mpos = system.GetWindow():GetMousePosition()

			if not state.disabled and pnl.Owner.mouse_input:IsHoveredExclusively(mpos) then
				local lpos = pnl.Owner.transform:GlobalToLocal(mpos)
				render2d.SetBlendMode("additive")
				render2d.SetTexture(Textures.GlowLinear)

				if anim.glow_alpha > 0 then
					local c = pnl.Owner.gui_element.Color or theme.GetColor("lightest")
					render2d.SetColor(c.r, c.g, c.b, c.a * anim.glow_alpha)
					render2d.DrawRect(lpos.x - 192, lpos.y - 192, 384, 384)
				end

				render2d.SetTexture(Textures.GlowPoint)
				local c = pnl.Owner.gui_element.Color or theme.GetColor("lighter")
				render2d.SetColor(c.r, c.g, c.b, c.a * anim.press_scale)
				local ps = anim.press_scale * 150
				render2d.DrawRect(lpos.x - ps / 2, lpos.y - ps / 2, ps, ps)
				render2d.SetBlendMode("alpha")
			end
		end

		function runtime.panels.surface(pnl)
			local size = pnl.Owner.transform.Size + pnl.Owner.transform.DrawSizeOffset
			local c = pnl.Color + pnl.DrawColor
			local radius = pnl:GetBorderRadius()
			render2d.SetTexture(nil)
			render2d.SetColor(c.r, c.g, c.b, c.a * pnl.DrawAlpha)

			if radius > 0 then
				gfx.DrawRoundedRect(0, 0, size.x, size.y, radius)
			else
				render2d.DrawRect(0, 0, size.x, size.y)
			end
		end

		function runtime.panels.button_post(pnl, state)
			local anim = state.anim
			local size = pnl.Owner.transform.Size
			render2d.SetBlendMode("additive")
			render2d.SetColor(anim.glow_alpha, anim.glow_alpha, anim.glow_alpha, 1)
			render2d.SetTexture(Textures.GlowLinear)

			if state.mode == "filled" then
				runtime.DrawGlowLine(-3, -3, -3, size.y + 6, 40)
			elseif state.mode == "outline" then
				local c = theme.GetColor("frame_border")
				render2d.SetColor(c.r, c.g, c.b, anim.glow_alpha)
				runtime.DrawGlowLine(0, 0, 0, size.y, 1)
				runtime.DrawGlowLine(size.x, 0, size.x, size.y, 1)
			end

			local c = theme.GetColor("frame_border")
			render2d.SetColor(c.r, c.g, c.b, anim.glow_alpha)
			runtime.DrawGlowLine(0, 0, size.x, 0, 1)
			runtime.DrawGlowLine(0, size.y, size.x, size.y, 1)
			render2d.SetBlendMode("alpha")
		end

		function runtime.panels.slider(pnl, state)
			local owner = pnl.Owner
			local anim = state.anim

			if state.hovered then runtime.UpdateSliderAnimations(owner, state) end

			local size = owner.transform.Size
			local knob_width = theme.GetSize("S")
			local knob_height = theme.GetSize("S")
			local value = state.value
			local min_value = state.min
			local max_value = state.max
			local knob_x, knob_y

			if state.mode == "2d" then
				local normalized_x = (value.x - min_value.x) / (max_value.x - min_value.x)
				local normalized_y = (value.y - min_value.y) / (max_value.y - min_value.y)
				render2d.SetTexture(nil)
				local c = theme.GetColor("darker")
				render2d.SetColor(c.r, c.g, c.b, c.a)
				render2d.DrawRect(0, 0, size.x, size.y)
				knob_x = normalized_x * (size.x - knob_width)
				knob_y = normalized_y * (size.y - knob_height)
			elseif state.mode == "vertical" then
				local normalized = (value - min_value) / (max_value - min_value)
				local track_width = theme.GetSize("XXS")
				local track_x = (size.x - track_width) / 2
				render2d.SetTexture(nil)
				local c = theme.GetColor("darker")
				render2d.SetColor(c.r, c.g, c.b, c.a)
				render2d.DrawRect(track_x, knob_height / 2, track_width, size.y - knob_height)
				local fill_height = normalized * (size.y - knob_height)
				render2d.PushUV()
				render2d.SetUV2(0, 0, 0.5, 1)
				render2d.SetTexture(Textures.Gradient)
				c = theme.GetColor("primary")
				render2d.SetColor(c.r, c.g, c.b, 0.9)
				render2d.DrawRect(track_x, knob_height / 2, track_width, fill_height)
				render2d.PopUV()

				if anim.glow_alpha > 0 then
					render2d.SetBlendMode("additive")
					render2d.SetTexture(Textures.GlowLinear)
					c = theme.GetColor("light")
					render2d.SetColor(c.r, c.g * anim.glow_alpha, c.b * anim.glow_alpha, c.a)
					render2d.DrawRect(track_x - 2, knob_height / 2, track_width + 4, fill_height)
					render2d.SetBlendMode("alpha")
				end

				knob_x = (size.x - knob_width) / 2
				knob_y = normalized * (size.y - knob_height)
			else
				local normalized = (value - min_value) / (max_value - min_value)
				local track_height = theme.GetSize("XXS")
				local track_y = (size.y - track_height) / 2
				render2d.SetTexture(nil)
				local c = theme.GetColor("darker")
				render2d.SetColor(c.r, c.g, c.b, c.a)
				render2d.DrawRect(knob_width / 2, track_y, size.x - knob_width, track_height)
				local fill_width = normalized * (size.x - knob_width)
				render2d.PushUV()
				render2d.SetUV2(0, 0, 0.5, 1)
				render2d.SetTexture(Textures.Gradient)
				c = theme.GetColor("primary")
				render2d.SetColor(c.r, c.g, c.b, 0.9)
				render2d.DrawRect(knob_width / 2, track_y, fill_width, track_height)
				render2d.PopUV()

				if anim.glow_alpha > 0 then
					render2d.SetBlendMode("additive")
					render2d.SetTexture(Textures.GlowLinear)
					c = theme.GetColor("light")
					render2d.SetColor(c.r, c.g * anim.glow_alpha, c.b * anim.glow_alpha, c.a)
					render2d.DrawRect(knob_width / 2, track_y - 2, fill_width, track_height + 4)
					render2d.SetBlendMode("alpha")
				end

				knob_x = normalized * (size.x - knob_width)
				knob_y = (size.y - knob_height) / 2
			end

			render2d.SetTexture(Textures.GlowPoint)
			render2d.SetBlendMode("additive")
			local c = theme.GetColor("lighter")
			render2d.SetColor(c.r, c.g, c.b, c.a + anim.glow_alpha * 0.3)
			local glow_size = 20 * anim.knob_scale
			render2d.DrawRect(
				knob_x + knob_width / 2 - glow_size / 2,
				knob_y + knob_height / 2 - glow_size / 2,
				glow_size,
				glow_size
			)
			render2d.SetBlendMode("alpha")
			render2d.SetTexture(nil)
			c = theme.GetColor("button_normal")
			render2d.SetColor(c.r, c.g, c.b, c.a)
			local scaled_width = knob_width * anim.knob_scale
			local scaled_height = knob_height * anim.knob_scale
			local scale_offset_x = (scaled_width - knob_width) / 2
			local scale_offset_y = (scaled_height - knob_height) / 2
			render2d.DrawRect(knob_x - scale_offset_x, knob_y - scale_offset_y, scaled_width, scaled_height)
			render2d.PushUV()
			render2d.SetUV2(0, 0, 1, 0.5)
			render2d.SetTexture(Textures.Gradient)
			c = theme.GetColor("lighter")
			render2d.SetColor(c.r, c.g, c.b, c.a)
			render2d.DrawRect(
				knob_x - scale_offset_x,
				knob_y - scale_offset_y,
				scaled_width,
				scaled_height * 0.5
			)
			render2d.PopUV()

			if anim.glow_alpha > 0 then
				render2d.SetBlendMode("additive")
				render2d.SetTexture(Textures.GlowLinear)
				c = theme.GetColor("frame_border")
				render2d.SetColor(c.r * anim.glow_alpha, c.g * anim.glow_alpha, c.b * anim.glow_alpha, 1)
				runtime.DrawLine(
					knob_x - scale_offset_x,
					knob_y - scale_offset_y,
					knob_x + scaled_width - scale_offset_x,
					knob_y - scale_offset_y,
					1
				)
				runtime.DrawLine(
					knob_x - scale_offset_x,
					knob_y + scaled_height - scale_offset_y,
					knob_x + scaled_width - scale_offset_x,
					knob_y + scaled_height - scale_offset_y,
					1
				)
				render2d.SetBlendMode("alpha")
			end
		end

		function runtime.panels.checkbox(pnl, state)
			local anim = state.anim

			if state.hovered then runtime.UpdateCheckboxAnimations(pnl, state) end

			local size = pnl.transform.Size
			local check_size = theme.GetSize("M")
			local box_x = 0
			local box_y = (size.y - check_size) / 2
			render2d.SetTexture(nil)
			local c = theme.GetColor("darker")
			render2d.SetColor(c.r, c.g, c.b, c.a)
			render2d.DrawRect(box_x, box_y, check_size, check_size)

			if anim.glow_alpha > 0 then
				render2d.SetBlendMode("additive")
				render2d.SetTexture(Textures.GlowLinear)
				c = theme.GetColor("frame_border")
				render2d.SetColor(c.r * anim.glow_alpha, c.g * anim.glow_alpha, c.b * anim.glow_alpha, 0.5)
				runtime.DrawRect(box_x - 1, box_y - 1, check_size + 2, check_size + 2, 1)
				render2d.SetBlendMode("alpha")
			end

			if anim.check_anim > 0.01 then
				local s = anim.check_anim
				render2d.PushUV()
				render2d.SetUV2(0, 0, 0.5, 1)
				render2d.SetTexture()
				c = theme.GetColor("primary")
				render2d.SetBlendMode("additive")
				render2d.SetColor(c.r, c.g, c.b, 0.9 * s)
				local padding = check_size * 0.2
				local mark_size = (check_size - padding * 2) * s
				local mark_x = box_x + check_size / 2 - mark_size / 2
				local mark_y = box_y + check_size / 2 - mark_size / 2
				render2d.DrawRect(mark_x, mark_y, mark_size, mark_size)
				render2d.PopUV()
				render2d.SetBlendMode("alpha")
			end
		end

		function runtime.panels.button_radio(pnl, state)
			local anim = state.anim

			if state.hovered then runtime.UpdateCheckboxAnimations(pnl, state) end

			local size = pnl.transform.Size
			local rb_size = theme.GetSize("M")
			local rb_x = 0
			local rb_y = (size.y - rb_size) / 2
			render2d.SetTexture(nil)
			local c = theme.GetColor("darker")
			render2d.SetColor(c.r, c.g, c.b, c.a)
			runtime.DrawDiamond(rb_x + rb_size / 2, rb_y + rb_size / 2, rb_size * 0.8)

			if anim.glow_alpha > 0 then
				render2d.SetBlendMode("additive")
				render2d.PushOutlineWidth(1)
				render2d.SetTexture()
				c = theme.GetColor("frame_border")
				render2d.SetColor(c.r * anim.glow_alpha, c.g * anim.glow_alpha, c.b * anim.glow_alpha, 2)
				runtime.DrawDiamond(rb_x + rb_size / 2, rb_y + rb_size / 2, rb_size * 0.8)
				render2d.SetBlendMode("alpha")
				render2d.PopOutlineWidth()
			end

			if anim.check_anim > 0.01 then
				local s = anim.check_anim
				render2d.SetTexture(theme.GetColor("primary"))
				render2d.SetBlendMode("additive")
				c = theme.GetColor("primary")
				render2d.SetColor(c.r, c.g, c.b, s)
				local dot_size = rb_size * s
				runtime.DrawDiamond(rb_x + dot_size / 2, rb_y + dot_size / 2, dot_size * 0.25)
				render2d.SetBlendMode("alpha")
			end
		end

		function runtime.panels.frame(pnl, emphasis)
			local s = pnl.transform.Size + pnl.transform.DrawSizeOffset
			local c = pnl.gui_element.Color + pnl.gui_element.DrawColor
			render2d.SetColor(c.r, c.g, c.b, c.a * pnl.gui_element.DrawAlpha)
			render2d.PushAlphaMultiplier(pnl.gui_element.DrawAlpha)
			runtime.DrawModernFrame(0, 0, s.x, s.y, (emphasis or 1) * pnl.gui_element.DrawAlpha)
			render2d.PopAlphaMultiplier()
		end

		function runtime.panels.frame_post(pnl, emphasis)
			local s = pnl.transform.Size + pnl.transform.DrawSizeOffset
			local c = pnl.gui_element.Color + pnl.gui_element.DrawColor
			render2d.SetColor(c.r, c.g, c.b, c.a)
			render2d.PushAlphaMultiplier(pnl.gui_element.DrawAlpha)
			runtime.DrawModernFramePost(0, 0, s.x, s.y, (emphasis or 1) * pnl.gui_element.DrawAlpha)
			render2d.PopAlphaMultiplier()
		end

		function runtime.panels.menu_spacer(pnl, vertical)
			local size = pnl.Owner.transform:GetSize()
			local r, g, b, a = theme.GetColor("lightest"):Unpack()
			render2d.PushColor(r, g, b, a)

			if vertical then
				runtime.DrawLine(size.x / 2, 0, size.x / 2, size.y, 2)
			else
				runtime.DrawLine(0, size.y / 2, size.x, size.y / 2, 2)
			end

			render2d.PopColor()
		end

		function runtime.panels.header(pnl)
			local size = pnl.transform.Size
			render2d.SetColor(primary.r, primary.g, primary.b, primary.a * pnl.gui_element.DrawAlpha)
			runtime.DrawPill(0, 0, size.x, size.y)
		end

		function runtime.panels.progress_bar(pnl, state)
			local size = pnl.Owner.transform.Size
			local value = state.value or 0
			local color = pnl.Owner.gui_element.Color or primary
			runtime.DrawProgressBarPrimitive(0, 0, size.x, size.y, value, color)
		end

		function runtime.panels.divider(pnl)
			local size = pnl.transform.Size
			render2d.SetColor(primary.r, primary.g, primary.b, primary.a * pnl.gui_element.DrawAlpha * 10)
			render2d.PushBlendMode("additive")

			if size.x > size.y then
				runtime.DrawGlowLine(0, size.y / 2, size.x, size.y / 2, 0)
			else
				runtime.DrawGlowLine(size.x / 2, 0, size.x / 2, size.y, 0)
			end

			render2d.PopBlendMode()
		end

		function runtime.DrawMuseum()
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetTexture(nil)
			local x, y = 500, 200
			local w, h = 600, 30
			local font = theme.GetFont("heading", "XXL")
			font:DrawText("Custom Font Rendering", x, y - 40)
			runtime.DrawClassicFrame(x, y, 60, 40)
			x = x + 80
			runtime.DrawModernFrame(x, y, 100, 60, 1)
			x = x + 120
			runtime.DrawModernFrame(x, y, 100, 60, 0)
			x = x + 120
			runtime.DrawWhiteFrame(x, y, 60, 40)
			x = x - 320
			y = y + 80
			render2d.SetColor(0, 0, 0, 1)
			runtime.DrawPill(x, y, w, h)
			y = y + 50
			runtime.DrawBadge(x, y, w, h)
			y = y + 50
			runtime.DrawDiamond(x, y, 20)
			x = x + 50
			render2d.PushOutlineWidth(1)
			runtime.DrawDiamond(x, y, 20)
			render2d.PopOutlineWidth()
			render2d.SetColor(1, 1, 1, 1)
			x = x + 50
			runtime.DrawArrow(x, y, 40)
			x = x - 100
			y = y + 50
			render2d.SetTexture(nil)
			runtime.DrawLine(x + 20, y, x + w - 40, y, 3)
			y = y + 20
			runtime.DrawLine2(x + 20, y, x + w - 40, y, 3)
			y = y + 20
			runtime.DrawDiamond2(x, y, 10)
			y = y + 40
			runtime.DrawMagicCircle(x - 100, y, 30)
			y = y + 20
			runtime.DrawGlowLine(x, y, x + w - 40, y, 1)
		end

		return runtime
	end

	return {
		preset = preset,
		create_runtime = create_runtime,
	}
end
