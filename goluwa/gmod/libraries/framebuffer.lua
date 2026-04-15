if SERVER then return end

local lib = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render = gine.env.render
gine.render_targets = gine.render_targets or {}

local function get_error_texture()
	if lib.GetErrorTexture then
		local texture = lib.GetErrorTexture()

		if texture then return texture end
	end

	if lib.CreateTextureFromPath then
		local texture = lib.CreateTextureFromPath("textures/error.png")

		if texture then return texture end
	end

	return nil
end

function gine.env.GetRenderTarget(name, w, h, additive)
	return gine.env.GetRenderTargetEx(name, w, h)
end

local size_mode_tr = gine.GetReverseEnums("RT_SIZE_(.+)")
local depth_mode_tr = gine.GetReverseEnums("MATERIAL_RT_DEPTH_(.+)")
local image_format_tr = gine.GetReverseEnums("IMAGE_FORMAT_(.+)")
local texture_flags_tbl = gine.GetEnums("TEXTUREFLAGS_(.+)")
local rt_flags_tbl = gine.GetEnums("CREATERENDERTARGETFLAGS_(.+)")

local function get_render_size()
	if lib.GetRenderImageSize then
		local ok, size = pcall(lib.GetRenderImageSize)

		if ok and size and size.x and size.y and size.x > 0 and size.y > 0 then return size end
	end

	local window = system.GetCurrentWindow and system.GetCurrentWindow()

	if window and (not window.IsValid or window:IsValid()) then
		local size = window:GetSize()

		if size.x > 0 and size.y > 0 then return size end
	end

	return Vec2(1, 1)
end

local function pow2ceil(n)
	n = math.max(1, math.floor(tonumber(n) or 1))
	local pow = 1

	while pow < n do
		pow = pow * 2
	end

	return pow
end

local function resolve_rt_size(w, h, size_mode)
	local screen = get_render_size()
	local width = tonumber(w) or 0
	local height = tonumber(h) or 0
	local mode = size_mode or "default"

	if width <= 0 then width = screen.x end
	if height <= 0 then height = screen.y end

	if mode == "full_frame_buffer" or mode == "offscreen" or mode == "default" then
		return Vec2(math.max(1, math.floor(width)), math.max(1, math.floor(height)))
	end

	if mode == "full_frame_buffer_rounded_up" then
		return Vec2(pow2ceil(width), pow2ceil(height))
	end

	if mode == "no_change" then
		return screen
	end

	return Vec2(math.max(1, math.floor(width)), math.max(1, math.floor(height)))
end

local function flags_to_table(mask, enum_tbl)
	local out = {}

	for key, value in pairs(enum_tbl) do
		out[key] = bit.band(mask, value) ~= 0
	end

	return out
end

function gine.env.GetRenderTargetEx(name, w, h, size_mode, depth_mode, texture_flags, rt_flags, image_format)
	if gine.render_targets[name] then return gine.render_targets[name] end

	size_mode = size_mode_tr[size_mode or gine.env.RT_SIZE_DEFAULT]
	local size = resolve_rt_size(w, h, size_mode)
	depth_mode = depth_mode_tr[depth_mode or gine.env.MATERIAL_RT_DEPTH_NONE]
	image_format = image_format_tr[image_format or gine.env.IMAGE_FORMAT_DEFAULT]
	texture_flags = flags_to_table(texture_flags or 0, texture_flags_tbl)
	rt_flags = flags_to_table(rt_flags or 0, rt_flags_tbl)
	local texture_flags_str = {}

	for k, v in pairs(texture_flags) do
		if v then list.insert(texture_flags_str, k) end
	end

	texture_flags_str = "[" .. list.concat(texture_flags_str, ", ") .. "]"
	local rt_flags_str = {}

	for k, v in pairs(rt_flags) do
		if v then list.insert(rt_flags_str, k) end
	end

	rt_flags_str = "[" .. list.concat(rt_flags_str, ", ") .. "]"
	--[[llog("GetRenderTarget(Ex):")
	table.print({
		name = name,
		size = size,
		size_mode = size_mode,
		depth_mode = depth_mode,
		texture_flags = texture_flags_str,
		rt_flags = rt_flags_str,
		image_format = image_format,
	})]] local ok, fb = pcall(lib.CreateFrameBuffer, size)

	if not ok or not fb then
		local fallback = get_error_texture()

		if fallback then
			gine.render_targets[name] = gine.WrapObject(fallback, "ITexture")
			return gine.render_targets[name]
		end

		return nil
	end

	local depth_tex = fb.GetDepthTexture and fb:GetDepthTexture()
	local color_tex = fb.GetColorTexture and fb:GetColorTexture() or fb.GetAttachment and fb:GetAttachment("color")
	local wrapped_tex = color_tex or depth_tex

	if not wrapped_tex then
		local fallback = get_error_texture()

		if fallback then
			gine.render_targets[name] = gine.WrapObject(fallback, "ITexture")
			return gine.render_targets[name]
		end

		return nil
	end

	wrapped_tex.fb = fb
	gine.render_targets[name] = gine.WrapObject(wrapped_tex, "ITexture")
	return gine.render_targets[name]
end

local current_fb

function render.SetRenderTarget(tex)
	if tex.__obj.fb then
		tex.__obj.fb:Bind()
		current_fb = tex
	end
end

function render.GetRenderTarget()
	return current_fb or gine.WrapObject(get_error_texture(), "ITexture")
end

function render.CopyRenderTargetToTexture(tex) end

function render.PushRenderTarget(rt, x, y, w, h)
	lib.PushFrameBuffer(rt.__obj.fb)
	x = x or 0
	y = y or 0
	w = w or rt.__obj.fb:GetSize().x
	h = h or rt.__obj.fb:GetSize().y
	lib.PushViewport(x, y, w, h)
end

function render.PopRenderTarget()
	lib.PopViewport()
	lib.PopFrameBuffer()
end