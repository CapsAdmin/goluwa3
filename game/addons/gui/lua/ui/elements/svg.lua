local io = require("io")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local vfs = import("goluwa/vfs.lua")
local theme = import("lua/ui/theme.lua")
local resource = import("goluwa/resource.lua")
local svg_codec = import("goluwa/codecs/svg.lua")

local function read_source_text(path)
	local data = vfs.Read(path)

	if data then return data end

	local file = io.open(path, "rb")

	if not file then return nil end

	data = file:read("*a")
	file:close()
	return data
end

local function normalize_padding(padding)
	if type(padding) == "string" then
		padding = Rect() + theme.GetPadding(padding)
	elseif type(padding) == "number" then
		padding = Rect() + padding
	end

	if not padding then padding = Rect() end

	return {
		left = padding.l or padding.left or padding.x or 0,
		top = padding.t or padding.top or padding.y or 0,
		right = padding.r or padding.right or padding.w or 0,
		bottom = padding.b or padding.bottom or padding.h or 0,
	}
end

return function(props)
	props = props or {}
	local state = {
		source = props.Source or props.Path,
		poly = nil,
		decoded = nil,
		fallback_texture = nil,
		status = "idle",
		error = nil,
		request_id = 0,
	}
	local panel

	local function notify_loaded()
		if props.OnLoad then props.OnLoad(panel, state.decoded) end
	end

	local function notify_error(reason)
		if props.OnError then props.OnError(panel, reason) end
	end

	local function get_fallback_texture()
		state.fallback_texture = state.fallback_texture or Texture.GetFallback()
		return state.fallback_texture
	end

	local function apply_svg_data(data, request_id)
		local poly, decoded = svg_codec.CreatePolygon2D(data, props.DecodeOptions)

		if request_id ~= state.request_id then return end

		state.poly = poly
		state.decoded = decoded
		state.status = "loaded"
		state.error = nil
		notify_loaded()
	end

	local function fail(reason, request_id)
		if request_id ~= state.request_id then return end

		state.poly = nil
		state.decoded = nil
		state.status = "error"
		state.error = tostring(reason)
		get_fallback_texture()
		wlog("svg panel load failed for %s: %s", tostring(state.source), state.error)
		notify_error(state.error)
	end

	local function load_source(source)
		state.request_id = state.request_id + 1
		local request_id = state.request_id
		state.source = source

		if not source or source == "" then
			state.poly = nil
			state.decoded = nil
			state.status = "idle"
			state.error = nil
			return
		end

		state.status = "loading"
		state.error = nil

		if source:find("<svg", 1, true) then
			local ok, err = pcall(apply_svg_data, source, request_id)

			if not ok then fail(err, request_id) end

			return
		end

		local local_data = read_source_text(source)

		if local_data then
			local ok, err = pcall(apply_svg_data, local_data, request_id)

			if not ok then fail(err, request_id) end

			return
		end

		resource.Download(source):Then(function(path)
			local data = read_source_text(path)

			if not data then
				fail("unable to read SVG source: " .. tostring(path), request_id)
				return
			end

			local ok, err = pcall(apply_svg_data, data, request_id)

			if not ok then fail(err, request_id) end
		end):Catch(function(reason)
			fail(reason or (tostring(source) .. " not found"), request_id)
		end)
	end

	panel = Panel.New{
		props,
		{
			Name = "svg",
			transform = {
				Size = props.Size or Vec2(96, 96),
			},
			layout = {
				MinSize = props.MinSize,
				MaxSize = props.MaxSize,
				props.layout,
			},
			gui_element = {
				BorderRadius = props.BorderRadius,
				OnDraw = function(self)
					local owner = self.Owner
					local size = owner.transform:GetSize()

					if props.BackgroundColor then
						theme.active:DrawSurface(theme.GetDrawContext(self, true), props.BackgroundColor)
					end

					local padding = normalize_padding(props.Padding)
					local available_w = math.max(0, size.x - padding.left - padding.right)
					local available_h = math.max(0, size.y - padding.top - padding.bottom)

					if available_w <= 0 or available_h <= 0 then return end

					if state.poly and state.decoded then
						local view_box = state.decoded.view_box or
							{x = 0, y = 0, w = state.decoded.width, h = state.decoded.height}
						local bounds_w = math.max(1e-6, view_box.w)
						local bounds_h = math.max(1e-6, view_box.h)
						local scale = math.min(available_w / bounds_w, available_h / bounds_h)

						if scale <= 0 then return end

						local draw_w = bounds_w * scale
						local draw_h = bounds_h * scale
						local offset_x = padding.left + (available_w - draw_w) / 2
						local offset_y = padding.top + (available_h - draw_h) / 2
						local color = props.Color and theme.GetColor(props.Color) or theme.GetColor("text")
						render2d.PushMatrix()
						render2d.Translatef(offset_x, offset_y)
						render2d.Scalef(scale, scale)
						render2d.Translatef(-view_box.x, -view_box.y)
						render2d.SetTexture(nil)
						render2d.SetColor(color.r, color.g, color.b, color.a)
						state.poly:Draw()
						render2d.PopMatrix()
					elseif state.status == "error" then
						local fallback = get_fallback_texture()
						local draw_size = math.min(available_w, available_h)

						if draw_size <= 0 then return end

						local offset_x = padding.left + (available_w - draw_size) / 2
						local offset_y = padding.top + (available_h - draw_size) / 2
						render2d.SetTexture(fallback)
						render2d.SetColor(1, 1, 1, 1)
						render2d.DrawRect(offset_x, offset_y, draw_size, draw_size)
					end
				end,
			},
			mouse_input = {
				Cursor = props.Cursor,
			},
			clickable = props.Clickable == true,
		},
	}

	function panel:SetSource(source)
		load_source(source)
		return self
	end

	function panel:SetPath(path)
		return self:SetSource(path)
	end

	function panel:GetSource()
		return state.source
	end

	function panel:GetStatus()
		return state.status, state.error
	end

	function panel:GetSVGData()
		return state.decoded
	end

	if state.source then panel:SetSource(state.source) end

	return panel
end
