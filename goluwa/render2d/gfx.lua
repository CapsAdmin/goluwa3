local render2d = require("render2d.render2d")
local Rect = require("structs.rect")
local Texture = require("render.texture")
local Polygon2D = require("render2d.polygon_2d")
local gfx = library()

function gfx.CreatePolygon2D(vertex_count, map)
	return Polygon2D.New(vertex_count, map)
end

function gfx.Initialize()
	-- Create a 1x1 white texture for use as a default
	local white_tex = Texture.New(
		{
			width = 1,
			height = 1,
			format = "r8g8b8a8_unorm",
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
			},
		}
	)
	white_tex:Shade([[
		return vec4(1.0, 1.0, 1.0, 1.0);
	]])
	gfx.white_texture = white_tex
	local tex = Texture.New(
		{
			width = 1024,
			height = 1024,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				mipmap_mode = "linear",
				wrap_s = "mirrored_repeat",
				wrap_t = "mirrored_repeat",
			},
		}
	)
	tex:Shade([[
		// http://www.geeks3d.com/20130705/shader-library-circle-disc-fake-sphere-in-glsl-opengl-glslhacker/3/
		float disc_radius = 1;
		float border_size = 0.0001;
		vec2 uv2 = vec2(uv.x, -uv.y + 1);
		float dist = sqrt(dot(uv2, uv2));
		float t = smoothstep(disc_radius + border_size, disc_radius - border_size, dist);
		return vec4(1,1,1,t);
	]])
	gfx.quadrant_circle_texture = tex
	local tex = Texture.New(
		{
			width = 512,
			height = 512,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				mipmap_mode = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)
	tex:Shade([[
		float dist = length(uv - 0.5);
		float alpha = smoothstep(0.5, 0.25, dist);
		return vec4(1.0, 1.0, 1.0, alpha * alpha);
	]])
	gfx.shadow_texture = tex
end

function gfx.DrawShadow(x, y, w, h, size, radius)
	size = size or 16
	radius = radius or 0
	local tex = gfx.shadow_texture

	if w / 2 < radius then radius = w / 2 end

	if h / 2 < radius then radius = h / 2 end

	render2d.PushTexture(tex)
	render2d.PushUV()
	local sw = {size, radius, w - radius * 2, radius, size}
	local sh = {size, radius, h - radius * 2, radius, size}
	local u = {0, 0.25, 0.5, 0.5, 0.75}
	local uw = {0.25, 0.25, 0, 0.25, 0.25}
	local v = {0, 0.25, 0.5, 0.5, 0.75}
	local vh = {0.25, 0.25, 0, 0.25, 0.25}
	local px = {x - size, x, x + radius, x + w - radius, x + w}
	local py = {y - size, y, y + radius, y + h - radius, y + h}

	for row = 1, 5 do
		for col = 1, 5 do
			if sw[col] > 0 and sh[row] > 0 then
				render2d.SetUV2(u[col], v[row] + vh[row], u[col] + uw[col], v[row])
				render2d.DrawRect(px[col], py[row], sw[col], sh[row])
			end
		end
	end

	render2d.PopUV()
	render2d.PopTexture()
end

function gfx.DrawNinePatch(x, y, w, h, patch_size_w, patch_size_h, corner_size, u_offset, v_offset, uv_scale)
	local size = render2d.GetTexture():GetSize()
	local skin_w = size.x
	local skin_h = size.y
	u_offset = u_offset or 0
	v_offset = v_offset or 0
	uv_scale = uv_scale or 1

	if w / 2 < corner_size then corner_size = w / 2 end

	if h / 2 < corner_size then corner_size = h / 2 end

	-- 1
	render2d.SetUV(
		u_offset,
		v_offset,
		corner_size / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x, y, corner_size, corner_size)
	-- 2
	render2d.SetUV(
		u_offset + corner_size,
		v_offset,
		(patch_size_w - corner_size * 2) / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x + corner_size, y, w - corner_size * 2, corner_size)
	-- 3
	render2d.SetUV(
		u_offset + patch_size_w - corner_size / uv_scale,
		v_offset,
		corner_size / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x + w - corner_size, y, corner_size, corner_size)
	-- 4
	render2d.SetUV(
		u_offset,
		v_offset + corner_size,
		corner_size / uv_scale,
		(patch_size_h - corner_size * 2) / uv_scale,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x, y + corner_size, corner_size, h - corner_size * 2)
	-- 5
	render2d.SetUV(
		u_offset + corner_size,
		v_offset + corner_size,
		patch_size_w - corner_size * 2,
		patch_size_h - corner_size * 2,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x + corner_size, y + corner_size, w - corner_size * 2, h - corner_size * 2)
	-- 6
	render2d.SetUV(
		u_offset + patch_size_w - corner_size / uv_scale,
		v_offset + corner_size / uv_scale,
		corner_size / uv_scale,
		(patch_size_h - corner_size * 2) / uv_scale,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x + w - corner_size, y + corner_size, corner_size, h - corner_size * 2)
	-- 7
	render2d.SetUV(
		u_offset,
		v_offset + patch_size_h - corner_size / uv_scale,
		corner_size / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x, y + h - corner_size, corner_size, corner_size)
	-- 8
	render2d.SetUV(
		u_offset + corner_size / uv_scale,
		v_offset + patch_size_h - corner_size / uv_scale,
		(patch_size_w - corner_size * 2) / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x + corner_size, y + h - corner_size, w - corner_size * 2, corner_size)
	-- 9
	render2d.SetUV(
		u_offset + patch_size_w - corner_size / uv_scale,
		v_offset + patch_size_h - corner_size / uv_scale,
		corner_size / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	render2d.DrawRect(x + w - corner_size, y + h - corner_size, corner_size, corner_size)
end

function gfx.DrawFilledCircle(x, y, sx, sy)
	sy = sy or sx
	render2d.PushTexture(gfx.quadrant_circle_texture)
	render2d.DrawRect(x, y, sx, sy)
	render2d.DrawRect(x, y, sx, sy, math.pi)
	render2d.DrawRect(x, y, sy, sx, math.pi / 2)
	render2d.DrawRect(x, y, sy, sx, -math.pi / 2)
	render2d.PopTexture()
end

function gfx.DrawRoundedRect(x, y, w, h, amt)
	amt = amt or 16

	if amt > w / 2 then amt = w / 2 end

	if amt > h / 2 then amt = h / 2 end

	render2d.PushTexture(nil)
	render2d.DrawRect(x + amt, y + amt, w - amt * 2, h - amt * 2) -- center
	render2d.DrawRect(x + amt, y, w - amt * 2, amt) -- top
	render2d.DrawRect(x + amt, y + h - amt, w - amt * 2, amt) -- bottom
	render2d.DrawRect(x + w - amt, y + amt, amt, h - amt * 2) -- right
	render2d.DrawRect(x, y + amt, amt, h - amt * 2) -- left
	render2d.PopTexture()
	render2d.PushTexture(gfx.quadrant_circle_texture)
	render2d.DrawRect(x + w - amt, y + h - amt, amt, amt)
	render2d.DrawRect(x + amt, y + h - amt, amt, amt, math.pi / 2)
	render2d.DrawRect(x + amt, y + amt, amt, amt, math.pi)
	render2d.DrawRect(x + w - amt, y + amt, amt, amt, -math.pi / 2)
	render2d.PopTexture()
end

function gfx.DrawRect(x, y, w, h, tex, r, g, b, a)
	if not y and not w and not h then
		tex = x
		x, y = 0, 0
		w, h = tex:GetSize():Unpack()
	end

	if r then render2d.PushColor(r, g, b, a) end

	render2d.PushTexture(tex)
	render2d.DrawRect(x, y, w, h)
	render2d.PopTexture()

	if r then render2d.PopColor() end
end

function gfx.DrawOutlinedRect(x, y, w, h, r, r_, g, b, a)
	r = r or 1

	if r_ then render2d.PushColor(r_, g, b, a) end

	render2d.PushTexture(nil)

	if type(r) == "number" then r = Rect() + r end

	gfx.DrawLine(x, y, x, y + h, r.x, true, r.x)
	gfx.DrawLine(x - r.x + r.y, y, x + w + r.y + r.w, y, r.y, true, 0, r.y)
	gfx.DrawLine(x + w, y, x + w, y + h, r.w, true, 0)
	gfx.DrawLine(x - r.x, y + h, x + w + r.w, y + h, r.h, true, r.h, 0)
	render2d.PopTexture()

	if r_ then render2d.PopColor() end
end

function gfx.DrawLine(x1, y1, x2, y2, w, skip_tex, ox, oy)
	w = w or 1

	if not skip_tex then render2d.SetTexture() end

	local dx, dy = x2 - x1, y2 - y1
	local ang = math.atan2(dx, dy)
	local dst = math.sqrt((dx * dx) + (dy * dy))
	ox = ox or (w * 0.5)
	oy = oy or 0
	render2d.DrawRect(x1, y1, w, dst, -ang, ox, oy)
end

function gfx.DrawCircle(x, y, radius, width, resolution)
	resolution = resolution or 16
	local spacing = (resolution / radius) - 0.2

	for i = 0, resolution do
		local i1 = ((i + 0) / resolution) * math.pi * 2
		local i2 = ((i + 1 + spacing) / resolution) * math.pi * 2
		gfx.DrawLine(
			x + math.sin(i1) * radius,
			y + math.cos(i1) * radius,
			x + math.sin(i2) * radius,
			y + math.cos(i2) * radius,
			width
		)
	end
end

do
	local window = require("window")
	local render = require("render.render")

	function gfx.GetMousePosition()
		if window.GetMouseTrapped() then
			return render.GetWidth() / 2, render.GetHeight() / 2
		end

		return window.GetMousePosition():Unpack()
	end

	local last_x = 0
	local last_y = 0
	local last_diff = 0

	function gfx.GetMouseVel()
		local x, y = window.GetMousePosition():Unpack()
		local vx = x - last_x
		local vy = y - last_y
		local time = system.GetElapsedTime()

		if last_diff < time then
			last_x = x
			last_y = y
			last_diff = time + 0.1
		end

		return vx, vy
	end
end

return gfx
