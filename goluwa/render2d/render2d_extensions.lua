local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local render = import("goluwa/render/render.lua")

function render2d.CreateGradient(config)
	local width = config.width or 256
	local height = config.height or 1
	local mode = config.mode or "linear"
	local stops = config.stops or {}

	for i, stop in ipairs(stops) do
		stop.pos = stop.pos or i - 1
	end

	local dither_amount = config.dither

	if dither_amount == nil then dither_amount = 0.5 end

	local dithered = dither_amount ~= false
	local tex = Texture.New{
		width = width,
		height = height,
		name = string.format("render2d %s gradient %dx%d", mode, width, height),
		-- Stops are authored display values; the render2d pipeline linearizes
		-- the color*texture product and the sRGB framebuffer re-encodes it,
		-- so stored values round-trip to the screen exactly.
		srgb = config.srgb,
		mip_map_levels = config.mip_map_levels or 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = config.repeat_texture and "repeat" or "clamp_to_edge",
			wrap_t = config.repeat_texture and "repeat" or "clamp_to_edge",
		},
	}
	local glsl

	if mode == "linear" then
		local angle = config.angle or 0 -- degrees
		local rad = math.rad(angle)
		local s, c = math.sin(rad), math.cos(rad)
		glsl = [[
				vec2 dir = vec2(]] .. s .. [[, ]] .. -c .. [[);
				float t = dot(uv - 0.5, dir) + 0.5;
				t = clamp(t, 0.0, 1.0);
			]]
	elseif mode == "radial" then
		glsl = [[
				float t = distance(uv, vec2(0.5)) * 2.0;
				t = clamp(t, 0.0, 1.0);
			]]
	end

	-- Build the color ramp from stops
	-- stops = { {pos=0, color=Color(1,0,0,1)}, {pos=1, color=Color(0,0,1,1)} }
	table.sort(stops, function(a, b)
		return a.pos < b.pos
	end)

	local ramp = "vec4 res = vec4(0.0);\n"

	if #stops == 0 then
		ramp = ramp .. "res = vec4(1.0);\n"
	elseif #stops == 1 then
		local c = stops[1].color
		ramp = ramp .. "res = vec4(" .. c.r .. "," .. c.g .. "," .. c.b .. "," .. c.a .. ");\n"
	elseif #stops == 2 then
		local s1, s2 = stops[1], stops[2]
		local mix_code = "res = mix(vec4(" .. s1.color.r .. "," .. s1.color.g .. "," .. s1.color.b .. "," .. s1.color.a .. "), vec4(" .. s2.color.r .. "," .. s2.color.g .. "," .. s2.color.b .. "," .. s2.color.a .. "), clamp((t - " .. s1.pos .. ") / (" .. s2.pos .. " - " .. s1.pos .. "), 0.0, 1.0));\n"
		ramp = ramp .. mix_code
	else
		for i = 1, #stops - 1 do
			local s1 = stops[i]
			local s2 = stops[i + 1]
			local cond = (i == 1) and "t <= " .. s2.pos or "t > " .. s1.pos .. " && t <= " .. s2.pos

			if i == #stops - 1 then cond = "t > " .. s1.pos end

			ramp = ramp .. "if (" .. cond .. ") {\n"
			ramp = ramp .. "  float fac = clamp((t - " .. s1.pos .. ") / (" .. s2.pos .. " - " .. s1.pos .. "), 0.0, 1.0);\n"
			ramp = ramp .. "  res = mix(vec4(" .. s1.color.r .. "," .. s1.color.g .. "," .. s1.color.b .. "," .. s1.color.a .. "), vec4(" .. s2.color.r .. "," .. s2.color.g .. "," .. s2.color.b .. "," .. s2.color.a .. "), fac);\n"
			ramp = ramp .. "}\n"
		end
	end

	-- Only ramping gradients need dithering: the framebuffer is 8-bit, so a
	-- display range spanning fewer than 256 levels bands at hard edges. Baking
	-- per-texel noise (in stored sRGB space, which is the output space) turns
	-- band edges into invisible fine noise. Flat gradients stay exact.
	local flat = true

	if #stops > 1 then
		local first = stops[1].color

		for i = 2, #stops do
			local c = stops[i].color

			if c.r ~= first.r or c.g ~= first.g or c.b ~= first.b or c.a ~= first.a then
				flat = false

				break
			end
		end
	end

	if dithered and not flat then
		ramp = ramp .. string.format(
				[[
				{
					float dth = fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453);
					res.rgb += (dth - 0.5) * (%.9f / 255.0);
					res.rgb = clamp(res.rgb, vec3(0.0), vec3(1.0));
				}
				return res;
			]],
				dither_amount
			)
	else
		ramp = ramp .. "return res;"
	end

	tex:Shade(glsl .. "\n" .. ramp)
	return tex
end

function render2d.DrawTriangle(x, y, w, h, a)
	render2d.triangle_mesh = render2d.triangle_mesh or
		render2d.CreateMesh{
			{
				pos = Vec3(-0.5, -0.5, 0),
				uv = Vec2(0, 0),
				sample_uv = Vec2(0, 0),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(0.5, 0.5, 0),
				uv = Vec2(1, 1),
				sample_uv = Vec2(1, 1),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(-0.5, 0.5, 0),
				uv = Vec2(0, 1),
				sample_uv = Vec2(0, 1),
				color = Color(1, 1, 1, 1),
			},
		}
	render2d.BindMesh(render2d.triangle_mesh)
	render2d.PushMatrix()

	if x and y then render2d.Translate(x, y) end

	if a then render2d.Rotate(a) end

	if w and h then render2d.Scale(w, h) end

	local cmd = render.GetCommandBuffer()
	render2d.UploadConstants(w, h)
	render2d.triangle_mesh:Draw(cmd, 3)
	render2d.PopMatrix()
end

function render2d.DrawFilledCircle(x, y, radius)
	render2d.PushBorderRadius(radius)
	render2d.DrawRect(x - radius, y - radius, radius * 2, radius * 2)
	render2d.PopBorderRadius()
end

function render2d.DrawRoundedRect(x, y, w, h, amt)
	if amt > 0 then render2d.PushBorderRadius(amt or 16) end

	render2d.DrawRect(x, y, w, h)

	if amt > 0 then render2d.PopBorderRadius() end
end

function render2d.DrawOutlinedRect(x, y, w, h, thickness, radius, r, g, b, a)
	if r then render2d.PushColor(r, g, b, a) end

	render2d.PushOutlineWidth(-(thickness or 1))
	render2d.PushBorderRadius(radius or 0)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()

	if r then render2d.PopColor() end
end

function render2d.DrawLine(x1, y1, x2, y2, w, skip_tex, ox, oy)
	w = w or 1

	if not skip_tex then render2d.SetTexture() end

	local dx, dy = x2 - x1, y2 - y1
	local ang = math.atan2(dx, dy)
	local dst = math.sqrt((dx * dx) + (dy * dy))
	ox = ox or (w * 0.5)
	oy = oy or 0
	render2d.DrawRect(x1, y1, w, dst, -ang, ox, oy)
end

function render2d.DrawCircle(x, y, radius, width, resolution)
	resolution = resolution or 16
	local spacing = (resolution / radius) - 0.2

	for i = 0, resolution do
		local i1 = ((i + 0) / resolution) * math.pi * 2
		local i2 = ((i + 1 + spacing) / resolution) * math.pi * 2
		render2d.DrawLine(
			x + math.sin(i1) * radius,
			y + math.cos(i1) * radius,
			x + math.sin(i2) * radius,
			y + math.cos(i2) * radius,
			width
		)
	end
end

do
	function render2d.PushTransform(tbl, w, h)
		local x = tbl.x or 0
		local y = tbl.y or 0
		w = w or tbl.w
		h = h or tbl.h
		render2d.PushWorldMatrix()
		render2d.Translatef(x + w / 2, y + h / 2)

		if tbl.scale or tbl.scale_x or tbl.scale_y then
			local sx = tbl.scale_x or tbl.scale or 1
			local sy = tbl.scale_y or sx
			render2d.Scalef(sx, sy)
		end

		if tbl.angle then render2d.Rotate(tbl.angle) end

		if tbl.skew_x or tbl.skew_y then
			local skew_x = math.tan(math.rad(tbl.skew_x or 0))
			local skew_y = math.tan(math.rad(tbl.skew_y or 0))
			render2d.Shear(skew_x, skew_y)
		end

		if tbl.render_x or tbl.render_y then
			render2d.Translatef(tbl.render_x or 0, tbl.render_y or 0)
		end

		render2d.Translatef(-(x + w / 2), -(y + h / 2))
	end

	render2d.PopTransform = render2d.PopWorldMatrix
end

local fonts = import("goluwa/render2d/fonts.lua")
local Color = import("goluwa/structs/color.lua")
local text = library()
local font_cache = {}
local default_foreground_color = Color(1, 1, 1, 1)
local default_background_color = Color(0, 0, 0, 1)
-- Mirrors the engine default in render2d.lua; DrawShape never inherits the
-- ambient softness, so this is the fallback when a pass omits sdf_softness
local default_sdf_softness = 0.5
local hsv_cache = {}

local function get_font(font_name, size, weight)
	if not font_cache[font_name] then font_cache[font_name] = {} end

	if not font_cache[font_name][size] then font_cache[font_name][size] = {} end

	if not font_cache[font_name][size][weight] then
		font_cache[font_name][size][weight] = fonts.New{
			Name = font_name,
			Size = size,
			Weight = weight,
			Mode = "msdf",
		}
	end

	return font_cache[font_name][size][weight]
end

local function compute_auto_background(fg)
	local r = math.floor(fg.r * 255 + 0.5)
	local g = math.floor(fg.g * 255 + 0.5)
	local b = math.floor(fg.b * 255 + 0.5)

	if not hsv_cache[r] then hsv_cache[r] = {} end

	if not hsv_cache[r][g] then hsv_cache[r][g] = {} end

	if hsv_cache[r][g][b] then return hsv_cache[r][g][b] end

	local h, s, v = fg:GetHSV()
	local v2 = v
	s = s * 0.5
	v = v * 0.5
	v = 1.0 - v

	if math.abs(v - v2) < 0.1 then v = v - 0.25 end

	local bg = Color.FromHSV(h, s, math.max(v, 0))
	hsv_cache[r][g][b] = bg
	return bg
end

local function draw_shape_pass(geo, p)
	local x = p.x or geo.x or 0
	local y = p.y or geo.y or 0
	local w = p.w or geo.w
	local h = p.h or geo.h
	local blend = p.blend

	if blend == nil then blend = geo.blend end

	if blend then render2d.PushBlendPreset(blend) end

	local texture = p.texture

	if texture == nil then texture = geo.texture end

	if texture ~= nil then
		render2d.PushTexture(texture == false and nil or texture)
	end

	local radius = p.border_radius

	if radius == nil then radius = geo.border_radius end

	local clamp = p.clamp_border_radius

	if clamp == nil then clamp = geo.clamp_border_radius end

	if radius then
		if clamp == false then render2d.PushClampBorderRadius(false) end

		render2d.PushBorderRadius(radius)
	end

	-- A layer's outline_width turns the layer itself into a ring pass. The
	-- base table's outline_width is only the fill + ring shorthand, applied
	-- by DrawShape after the main pass.
	local outline_width = p ~= geo and p.outline_width or nil

	if outline_width and outline_width ~= 0 then
		render2d.PushOutlineWidth(outline_width)
	end

	local softness = p.sdf_softness

	if softness == nil then softness = geo.sdf_softness or default_sdf_softness end

	render2d.PushSDFSoftness(softness)
	local color_uv = p.color_uv

	if color_uv == nil then color_uv = geo.color_uv end

	if color_uv then
		render2d.PushColorUV(color_uv.x, color_uv.y, color_uv.w, color_uv.h, color_uv.r)
	end

	local color = p.color

	if color == nil then color = geo.color end

	local alpha = p.alpha

	if alpha == nil then alpha = geo.alpha end

	if color then
		render2d.SetColor(color.r, color.g, color.b, (alpha or 1) * color.a)
	elseif alpha and alpha ~= 1 then
		local r, g, b, a = render2d.GetColor()
		render2d.SetColor(r, g, b, a * alpha)
	end

	if p.int or geo.int then
		render2d.DrawRect(x, y, w, h)
	else
		render2d.DrawRectf(x, y, w, h)
	end

	if color_uv then render2d.PopColorUV() end

	render2d.PopSDFSoftness()

	if outline_width and outline_width ~= 0 then render2d.PopOutlineWidth() end

	if radius then
		render2d.PopBorderRadius()

		if clamp == false then render2d.PopClampBorderRadius() end
	end

	if texture ~= nil then render2d.PopTexture() end

	if blend then render2d.PopBlendMode() end
end

function render2d.DrawShape(tbl)
	local x = tbl.x or 0
	local y = tbl.y or 0
	local w = tbl.w
	local h = tbl.h
	local has_transform = tbl.scale or
		tbl.scale_x or
		tbl.scale_y or
		tbl.angle or
		tbl.skew_x or
		tbl.skew_y or
		tbl.render_x or
		tbl.render_y

	if has_transform then render2d.PushTransform(tbl, w, h) end

	local shape = tbl.shape or "none"
	render2d.PushShapeMode(shape)
	-- The full uv is the base for every pass of this call; a pass opts out
	-- with its own color_uv. This keeps a leaked ambient color uv from
	-- affecting any pass, including the shadow and outline passes.
	render2d.PushColorUV()

	if tbl.shadow or tbl.shadow_x or tbl.shadow_y then
		local shadow_color = tbl.shadow_color

		if shadow_color == true then
			shadow_color = compute_auto_background(tbl.color or default_foreground_color)
		elseif shadow_color == nil then
			shadow_color = default_background_color
		end

		local sx = tbl.shadow_x
		local sy = tbl.shadow_y

		if type(sx) ~= "number" then sx = 2 end

		if type(sy) ~= "number" then sy = 2 end

		local shadow_alpha = shadow_color.a * (
				shadow_color.a * shadow_color.a
			) * 0.67 * (
				tbl.blur_intensity or
				1
			)
		render2d.PushSDFSoftness(tbl.shadow_softness or default_sdf_softness)

		if tbl.border_radius then
			if tbl.clamp_border_radius == false then
				render2d.PushClampBorderRadius(false)
			end

			render2d.PushBorderRadius(tbl.border_radius)
		end

		if tbl.texture then render2d.PushTexture(tbl.texture) end

		render2d.SetColor(shadow_color.r, shadow_color.g, shadow_color.b, shadow_alpha)

		if tbl.int then
			render2d.DrawRect(x + sx, y + sy, w, h)
		else
			render2d.DrawRectf(x + sx, y + sy, w, h)
		end

		if tbl.texture then render2d.PopTexture() end

		if tbl.border_radius then
			render2d.PopBorderRadius()

			if tbl.clamp_border_radius == false then render2d.PopClampBorderRadius() end
		end

		render2d.PopSDFSoftness()
	end

	if tbl.layers then
		for _, layer in ipairs(tbl.layers) do
			draw_shape_pass(tbl, layer)
		end
	else
		draw_shape_pass(tbl, tbl)
		local outline_width = tbl.outline_width

		if outline_width and outline_width ~= 0 then
			local outline_color = tbl.outline_color or tbl.color or default_foreground_color
			render2d.PushSDFSoftness(tbl.outline_softness or default_sdf_softness)

			if tbl.border_radius then
				if tbl.clamp_border_radius == false then
					render2d.PushClampBorderRadius(false)
				end

				render2d.PushBorderRadius(tbl.border_radius)
			end

			render2d.PushOutlineWidth(outline_width)
			render2d.SetColor(
				outline_color.r,
				outline_color.g,
				outline_color.b,
				(tbl.outline_alpha or 1) * outline_color.a
			)

			if tbl.int then
				render2d.DrawRect(x, y, w, h)
			else
				render2d.DrawRectf(x, y, w, h)
			end

			render2d.PopOutlineWidth()

			if tbl.border_radius then
				render2d.PopBorderRadius()

				if tbl.clamp_border_radius == false then render2d.PopClampBorderRadius() end
			end

			render2d.PopSDFSoftness()
		end
	end

	render2d.PopColorUV()
	render2d.PopShapeMode()

	if has_transform then render2d.PopTransform() end
end

do
	local default_font_name = fonts.GetDefaultSystemFontPath()

	function render2d.GetTextSize(text, font_name, size, weight, _softness)
		font_name = font_name or default_font_name
		size = size or 14
		weight = weight or 0
		local font = get_font(font_name, size, weight)
		local w, h = font:GetTextSize(text)
		return w, h
	end

	function render2d.DrawText(tbl)
		local text = tbl.text or ""
		local x = tbl.x or 0
		local y = tbl.y or 0
		local font_name = tbl.font or default_font_name
		local size = tbl.size or 14
		local weight = tbl.weight or 0
		local softness = tbl.softness or 1
		local foreground_color = tbl.foreground_color or default_foreground_color
		local background_color = tbl.background_color or default_background_color
		local alpha = (tbl.alpha or 1) * foreground_color.a

		if background_color == true then
			background_color = compute_auto_background(foreground_color)

			if not tbl.softness then softness = 4 end
		end

		background_color = background_color or default_background_color
		local font = get_font(font_name, size, weight)
		local w, h = font:GetTextSize(text)
		local align_x = tbl.align_x
		local align_y = tbl.align_y
		local spacing = tbl.spacing
		local outline_width = tbl.outline_width
		local outline_color = tbl.outline_color or Color(0, 0, 0, 1)
		local has_transform = tbl.scale_x or
			tbl.scale_y or
			tbl.scale or
			tbl.angle or
			tbl.skew_x or
			tbl.skew_y or
			tbl.render_x or
			tbl.render_y

		if has_transform then render2d.PushTransform(tbl, w, h) end

		if tbl.shadow_x or tbl.shadow_y then
			local shadow_color = tbl.shadow_color or Color(0, 0, 0, 1)
			local sx = tbl.shadow_x or tbl.shadow_y or 2
			local sy = tbl.shadow_y or tbl.shadow_x or 2
			render2d.PushColor(shadow_color.r, shadow_color.g, shadow_color.b, shadow_color.a)
			render2d.PushSDFSoftness(2)
			font:DrawText(text, x + sx, y + sy, spacing, align_x, align_y)
			render2d.PopSDFSoftness()
			render2d.PopColor()
		end

		if softness > 0 then
			local bg_alpha = background_color.a * (foreground_color.a ^ 2) * 0.67
			render2d.PushColor(background_color.r, background_color.g, background_color.b, bg_alpha * (tbl.blur_intensity or 1))
			render2d.PushSDFSoftness(softness)
			font:DrawText(text, x, y, spacing, align_x, align_y)
			render2d.PopSDFSoftness()
			render2d.PopColor()
		end

		if outline_width then
			render2d.PushColor(outline_color.r, outline_color.g, outline_color.b, outline_color.a)
			render2d.PushOutlineWidth(outline_width)
			font:DrawText(text, x, y, spacing, align_x, align_y)
			render2d.PopOutlineWidth()
			render2d.PopColor()
		end

		render2d.PushColor(foreground_color.r, foreground_color.g, foreground_color.b, alpha)
		font:DrawText(text, x, y, spacing, align_x, align_y)
		render2d.PopColor()

		if has_transform then render2d.PopTransform() end

		return w, h
	end

	return text
end
