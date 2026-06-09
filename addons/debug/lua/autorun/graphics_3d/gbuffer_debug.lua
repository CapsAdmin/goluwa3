local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Texture = import("goluwa/render/texture.lua")
local ffi = require("ffi")
local fonts = import("goluwa/render2d/fonts.lua")
local show_gbuffer = false
local checkerboard_texture

local function get_checkerboard_texture()
	if checkerboard_texture then return checkerboard_texture end

	checkerboard_texture = Texture.New{
		width = 8,
		height = 8,
		format = "r8g8b8a8_unorm",
		mip_map_levels = 1,
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "repeat",
			wrap_t = "repeat",
		},
	}
	checkerboard_texture:Shade([[	
		vec4 color1 = vec4(0.5, 0.5, 0.5, 1);
		vec4 color2 = vec4(0.7, 0.7, 0.7, 1);
		int x = int(gl_FragCoord.x) / 4;
		int y = int(gl_FragCoord.y) / 4;
		if ((x + y) % 2 == 0) {
			return color1;
		} else {
			return color2;
		}

	]])
	return checkerboard_texture
end

local function draw_debug_tile(x, y, size, texture, label, swizzle_mode)
	if not texture then return false end

	render2d.PushUV()
	render2d.SetUV2(0, 0, size / 32, size / 32)
	render2d.SetTexture(get_checkerboard_texture())
	render2d.DrawRect(x, y, size, size)
	render2d.PopUV()
	render2d.PushUV()
	render2d.SetUV2(0, 1, 1, 0)
	render2d.SetTexture(texture)
	render2d.PushSwizzleMode(swizzle_mode or 0)
	render2d.DrawRect(x, y, size, size)
	render2d.PopSwizzleMode()
	render2d.PopUV()
	render2d.SetTexture(nil)
	render2d.SetColor(0, 0, 0, 0.5)
	render2d.DrawRect(x, y, 150, 20)
	render2d.SetColor(1, 1, 1, 1)
	fonts.GetFont():DrawText(label, x + 5, y + 5)
	return true
end

local function add_pass(views, name)
	if render3d.pipelines[name] then
		for i, v in ipairs(render3d.pipelines[name]:GetDebugViews()) do
			v.pipeline = render3d.pipelines[name]
			table.insert(views, v)
		end
	end
end

event.AddListener("Draw2D", "debug_gbuffer", function(cmd, dt)
	if not render3d.pipelines then return end

	if not render3d.pipelines.gbuffer or not render3d.pipelines.gbuffer:GetFramebuffer() then
		return
	end

	local window = system.GetWindow()

	if not window then return end

	local wnd_size = window:GetSize()

	if not render3d.pipelines.gbuffer then return end

	local swizzle_to_mode = {
		r = 1,
		g = 2,
		b = 3,
		a = 4,
		rgb = 5,
	}

	if not show_gbuffer then return end

	local size = 256
	local x = 0
	local y = 0
	render2d.SetColor(1, 1, 1, 1)
	local views = {}
	add_pass(views, "gbuffer")
	add_pass(views, "ambient_occlusion")
	add_pass(views, "ssr")
	add_pass(views, "ssgi_filter_1")
	add_pass(views, "ssgi_filter_2")
	add_pass(views, "ssgi")
	add_pass(views, "probe_irradiance")

	for i, view in ipairs(views) do
		local tex = view.pipeline:GetFramebuffer():GetAttachment(view.attachment_index)
		draw_debug_tile(
			x,
			y,
			size,
			tex,
			view.pipeline.name .. " " .. view.name,
			swizzle_to_mode[view.swizzle] or 0
		)
		x = x + size

		if x + size > wnd_size.x then
			x = 0
			y = y + size
		end
	end

	-- Draw depth texture
	if render3d.pipelines.gbuffer:GetFramebuffer().depth_texture then
		draw_debug_tile(x, y, size, render3d.pipelines.gbuffer:GetFramebuffer().depth_texture, "Depth", 0)
	end
end)

event.AddListener("KeyInput", "debug_gbuffer_toggle", function(key, press)
	if not press then return end

	if key == "g" then
		show_gbuffer = not show_gbuffer
		print("G-buffer debug: " .. (show_gbuffer and "ON" or "OFF"))
	end
end)
