local event = require("event")
local render = require("render.render")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local render3d = require("render3d.render3d")
local window = require("render.window")
local Texture = require("render.texture")
local ffi = require("ffi")
local show_gbuffer = false
local fullscreen_index = 0
local checkerboard_texture

local function get_checkerboard_texture()
	if checkerboard_texture then return checkerboard_texture end

	local size = 32
	local buffer = ffi.new("uint8_t[?]", size * size * 4)

	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local is_gray = ((math.floor(x / 8) + math.floor(y / 8)) % 2) == 0
			local val = is_gray and 200 or 150
			local idx = (y * size + x) * 4
			buffer[idx + 0] = val
			buffer[idx + 1] = val
			buffer[idx + 2] = val
			buffer[idx + 3] = 255
		end
	end

	checkerboard_texture = Texture.New(
		{
			width = size,
			height = size,
			format = "r8g8b8a8_unorm",
			buffer = buffer,
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "repeat",
				wrap_t = "repeat",
			},
		}
	)
	return checkerboard_texture
end

event.AddListener("Draw2D", "debug_gbuffer", function(cmd, dt)
	if not render3d.gbuffer then return end

	local wnd_size = window:GetSize()

	if not render3d.fill_pipeline then return end

	local swizzle_to_mode = {
		r = 1,
		g = 2,
		b = 3,
		a = 4,
		rgb = 5,
	}

	if fullscreen_index > 0 then
		local views = render3d.fill_pipeline:GetDebugViews()
		local tex, name, swizzle

		if fullscreen_index <= #views then
			local view = views[fullscreen_index]
			tex = render3d.gbuffer:GetAttachment(view.attachment_index)
			name = view.name
			swizzle = view.swizzle
		else
			tex = render3d.gbuffer.depth_texture
			name = "Depth"
		end

		if tex then
			render2d.SetColor(1, 1, 1, 1)
			render2d.PushUV()
			render2d.SetUV2(0, 0, wnd_size.x / 32, wnd_size.y / 32)
			render2d.SetTexture(get_checkerboard_texture())
			render2d.DrawRect(0, 0, wnd_size.x, wnd_size.y)
			render2d.PopUV()
			render2d.PushUV()
			render2d.SetUV2(0, 1, 1, 0)
			render2d.SetTexture(tex)
			render2d.PushSwizzleMode(swizzle_to_mode[swizzle] or 0)
			render2d.DrawRect(0, 0, wnd_size.x, wnd_size.y)
			render2d.PopSwizzleMode()
			render2d.PopUV()
			-- Label
			render2d.SetTexture(nil)
			render2d.SetColor(0, 0, 0, 0.5)
			render2d.DrawRect(5, 5, 200, 30)
			render2d.SetColor(1, 1, 1, 1)
			gfx.DrawText("Fullscreen: " .. name, 10, 10)
		end

		return
	end

	if not show_gbuffer then return end

	local size = 256
	local x = 0
	local y = 0
	render2d.SetColor(1, 1, 1, 1)

	-- Draw color textures
	for i, view in ipairs(render3d.fill_pipeline:GetDebugViews()) do
		local tex = render3d.gbuffer:GetAttachment(view.attachment_index)
		-- Draw checkerboard background
		render2d.PushUV()
		render2d.SetUV2(0, 0, size / 32, size / 32)
		render2d.SetTexture(get_checkerboard_texture())
		render2d.DrawRect(x, y, size, size)
		render2d.PopUV()
		render2d.PushUV()
		render2d.SetUV2(0, 1, 1, 0)
		render2d.SetTexture(tex)
		render2d.PushSwizzleMode(swizzle_to_mode[view.swizzle] or 0)
		render2d.DrawRect(x, y, size, size)
		render2d.PopSwizzleMode()
		render2d.PopUV()
		-- Draw label
		render2d.SetTexture(nil)
		render2d.SetColor(0, 0, 0, 0.5)
		render2d.DrawRect(x, y, 150, 20)
		render2d.SetColor(1, 1, 1, 1)
		gfx.DrawText(view.name, x + 5, y + 5)
		x = x + size

		if x + size > wnd_size.x then
			x = 0
			y = y + size
		end
	end

	-- Draw depth texture
	if render3d.gbuffer.depth_texture then
		-- Draw checkerboard background
		render2d.PushUV()
		render2d.SetUV2(0, 0, size / 32, size / 32)
		render2d.SetTexture(get_checkerboard_texture())
		render2d.DrawRect(x, y, size, size)
		render2d.PopUV()
		render2d.PushUV()
		render2d.SetUV2(0, 1, 1, 0)
		render2d.SetTexture(render3d.gbuffer.depth_texture)
		render2d.DrawRect(x, y, size, size)
		render2d.PopUV()
		-- Draw label
		render2d.SetTexture(nil)
		render2d.SetColor(0, 0, 0, 0.5)
		render2d.DrawRect(x, y, 100, 20)
		render2d.SetColor(1, 1, 1, 1)
		gfx.DrawText("Depth", x + 5, y + 5)
	end
end)

event.AddListener("KeyInput", "debug_gbuffer_toggle", function(key, press)
	if not press then return end

	if key == "g" then
		show_gbuffer = not show_gbuffer
		print("G-buffer debug: " .. (show_gbuffer and "ON" or "OFF"))
	elseif key == "f" then
		local views = render3d.fill_pipeline and render3d.fill_pipeline:GetDebugViews() or {}
		local count = #views + (render3d.gbuffer.depth_texture and 1 or 0)
		fullscreen_index = fullscreen_index + 1

		if fullscreen_index > count then fullscreen_index = 0 end

		if fullscreen_index == 0 then
			print("G-buffer fullscreen: OFF")
		elseif fullscreen_index <= #views then
			print("G-buffer fullscreen: " .. views[fullscreen_index].name)
		else
			print("G-buffer fullscreen: Depth")
		end
	end
end)
