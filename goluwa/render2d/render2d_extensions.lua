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

	local tex = Texture.New{
		width = width,
		height = height,
		name = string.format("render2d %s gradient %dx%d", mode, width, height),
		format = "r8g8b8a8_unorm",
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
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
			]]
	elseif mode == "radial" then
		glsl = [[
				float t = distance(uv, vec2(0.5)) * 2.0;
			]]
	end

	-- Build the color ramp from stops
	-- stops = { {pos=0, color=Color(1,0,0,1)}, {pos=1, color=Color(0,0,1,1)} }
	table.sort(stops, function(a, b)
		return a.pos < b.pos
	end)

	local ramp = ""

	if #stops == 0 then
		ramp = "return vec4(1.0);"
	elseif #stops == 1 then
		local c = stops[1].color
		ramp = "return vec4(" .. c.r .. "," .. c.g .. "," .. c.b .. "," .. c.a .. ");"
	else
		ramp = "vec4 res = vec4(0.0);\n"

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

	render2d.PushOutlineWidth(thickness or 1)
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
