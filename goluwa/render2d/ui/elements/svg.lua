local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local SVG = import("goluwa/render2d/svg.lua")

local function normalize_padding(padding)
	if type(padding) == "string" then
		padding = Rect() + theme.active:GetPadding(padding)
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
		svg = nil,
		fallback_texture = nil,
	}
	local panel

	local function notify_loaded()
		if props.OnLoad then props.OnLoad(panel, state.svg and state.svg.decoded) end
	end

	local function notify_error(reason)
		if props.OnError then props.OnError(panel, reason) end
	end

	local function get_fallback_texture()
		state.fallback_texture = state.fallback_texture or Texture.GetFallback()
		return state.fallback_texture
	end

	panel = Panel.New{
		props,
		{
			Name = "svg",
			transform = {
				Size = props.Size or Vec2(96, 96),
				Position = Vec2(),
			},
			layout = {
				MinSize = props.MinSize,
				MaxSize = props.MaxSize,
				props.layout,
			},
			visual = {
				OnDraw = function(self)
					local owner = self.Owner
					local size = owner.transform:GetSize()

					if props.BackgroundColor then theme.active:Draw(owner) end

					local padding = normalize_padding(props.Padding)
					local available_w = math.max(0, size.x - padding.left - padding.right)
					local available_h = math.max(0, size.y - padding.top - padding.bottom)

					if available_w <= 0 or available_h <= 0 then return end

					local svg = state.svg

					if svg and svg.status == "loaded" then
						local color = props.Color and
							theme.active:GetColor(props.Color) or
							theme.active:GetColor("text")
						render2d.SetColor(color.r, color.g, color.b, color.a)
						render2d.PushMatrixf(padding.left, padding.top, available_w, available_h)
						svg:Draw()
						render2d.PopMatrix()
					elseif svg and svg.status == "error" then
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
	panel:SetState("background_color", props.BackgroundColor)

	function panel:SetSource(source)
		state.svg = SVG.New(source)

		if state.svg.status == "loaded" then
			notify_loaded()
		elseif state.svg.status == "error" then
			notify_error(state.svg.error)
		end

		return self
	end

	function panel:SetPath(path)
		return self:SetSource(path)
	end

	function panel:GetSource()
		return state.svg and state.svg.source
	end

	function panel:GetStatus()
		if not state.svg then return "idle" end

		return state.svg.status, state.svg.error
	end

	function panel:GetSVGData()
		return state.svg and state.svg.decoded
	end

	if state.source then panel:SetSource(state.source) end

	return panel
end
