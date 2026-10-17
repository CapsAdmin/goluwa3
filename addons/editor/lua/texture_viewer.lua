local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Splitter = react.Element(import("goluwa/render2d/ui/elements/splitter.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local Checkbox = react.Element(import("goluwa/render2d/ui/elements/checkbox.lua"))
local ScrollablePanel = react.Element(import("goluwa/render2d/ui/elements/scrollable_panel.lua"))
local PropertyEditor = react.Element(import("goluwa/render2d/ui/widgets/property_editor.lua"))
local PanelElement = react.Element(Panel)
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local kit = import("lua/editor_kit.lua")
local ViewerWindow = kit.ViewerWindow
local Canvas = kit.Canvas
local InfoRow = kit.InfoRow
local CHANNEL_NAMES = {"R", "G", "B", "A"}
local ALL_CHANNELS = {R = true, G = true, B = true, A = true}
local SINGLE_CHANNEL_SWIZZLE = {R = "rrr", G = "ggg", B = "bbb", A = "aaa"}
local SWATCH = {R = {1, 0, 0}, G = {0, 1, 0}, B = {0, 0, 1}}
local GRAY = {0.5, 0.5, 0.5}

local function compute_draw_rect(view, canvas_w, canvas_h, zoom)
	zoom = zoom or view.zoom
	local aspect = view.width / view.height
	local canvas_aspect = canvas_w / canvas_h
	local base_w, base_h

	if aspect > canvas_aspect then
		base_w = canvas_w
		base_h = canvas_w / aspect
	else
		base_h = canvas_h
		base_w = canvas_h * aspect
	end

	local draw_w = base_w * zoom
	local draw_h = base_h * zoom
	return (canvas_w - draw_w) / 2 + view.pan.x, (canvas_h - draw_h) / 2 + view.pan.y, draw_w, draw_h
end

local function Heading(text)
	return Text{Key = text, Text = text, Font = "heading XS", IgnoreMouseInput = true}
end

-- the pixel under the mouse changes on every mouse move, so it renders on its own and nothing else does
local PixelRow = react.Component(|props| -> do
	local text, set_text = react.UseState(props.Idle)
	props.View.set_pixel_text = set_text

	return InfoRow{Label = "Pixel:", Value = text}
end)
local ChannelRow = react.Memo(
	react.Component(|props| -> do
		local label = props.Channel.label
		local draw = react.UseCallback(|| -> do
			local color = SWATCH[label] ?? GRAY
			render2d.SetColor(color[1], color[2], color[3], 1)
			render2d.DrawRect(0, 0, 10, 10)
		end, {label})

		return Row{layout = {Direction = "x", GrowWidth = 1, FitHeight = true, AlignmentY = "center", ChildGap = 4}}{
			PanelElement{
				transform = {Size = Vec2(10, 10)},
				visual = {OnDraw = draw},
				mouse_input = {IgnoreMouseInput = true},
			},
			Text{Text = label, Font = "body XS", IgnoreMouseInput = true, layout = {FitWidth = true}},
			Text{
				Text = string.format("min:%d max:%d avg:%.0f", props.Channel.min, props.Channel.max, props.Channel.avg),
				Font = "body XS",
				Color = "text_disabled",
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
		}
	end)
)
local TextureView = react.Component(|props| -> do
	local texture = props.Texture
	local path = props.Path
	local editor = react.UseRef()
	local channels, set_channels = react.UseState(ALL_CHANNELS)
	local show_grid, set_show_grid = react.UseState(false)
	local info = react.UseMemo(|| -> do
		local can_read = texture:CanDownload()
		local unavailable = "unavailable for " .. texture.format

		return {
			width = texture:GetWidth(),
			height = texture:GetHeight(),
			can_read = can_read,
			stats = can_read and texture:GetChannelStatistics() or {},
			unavailable = unavailable,
			idle = can_read and "-" or unavailable,
		}
	end, {})
	-- the canvas reads this while drawing, the mouse changes it, none of it is a reason to render again
	local view = react.UseMemo(|| -> {
		zoom = 1,
		pan = Vec2(0, 0),
		width = info.width,
		height = info.height,
		panning = false,
	}, {})
	local count = 0
	local single

	for _, name in ipairs(CHANNEL_NAMES) do
		if channels[name] then
			count = count + 1
			single = name
		end
	end

	view.swizzle = count == 1 and SINGLE_CHANNEL_SWIZZLE[single] or "none"
	view.show_grid = show_grid

	react.UseEffect(|| -> editor.current:SetObject(texture), {})

	local draw = react.UseCallback(|self| -> do
		local size = self.Owner.transform:GetSize()
		local w, h = size.x, size.y
		render2d.PushClipRect(0, 0, w, h)
		render2d.PushSwizzleMode(view.swizzle)
		local draw_x, draw_y, draw_w, draw_h = compute_draw_rect(view, w, h)
		render2d.SetTexture(texture)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(draw_x, draw_y, draw_w, draw_h)
		render2d.PopSwizzleMode()

		if view.show_grid and view.zoom >= 0.5 then
			render2d.SetTexture(nil)
			render2d.SetColor(0.5, 0.5, 0.5, 0.3)

			for i = 0, math.ceil(draw_w / view.zoom) do
				render2d.DrawRect(draw_x + i * view.zoom, draw_y, 1, draw_h)
			end

			for j = 0, math.ceil(draw_h / view.zoom) do
				render2d.DrawRect(draw_x, draw_y + j * view.zoom, draw_w, 1)
			end
		end

		render2d.PopClip()
	end, {})
	local on_mouse_input = react.UseCallback(|self, button, press, local_pos| -> do
		if (button == "mwheel_up" or button == "mwheel_down") and press then
			local old_zoom = view.zoom

			if button == "mwheel_up" then
				view.zoom = math.max(0.05, view.zoom / 1.25)
			else
				view.zoom = math.min(32, view.zoom * 1.25)
			end

			local size = self.transform:GetSize()
			local old_dx, old_dy, old_dw, old_dh = compute_draw_rect(view, size.x, size.y, old_zoom)
			local new_dx, new_dy, new_dw, new_dh = compute_draw_rect(view, size.x, size.y, view.zoom)
			local ratio_x = (local_pos.x - old_dx) / old_dw
			local ratio_y = (local_pos.y - old_dy) / old_dh
			view.pan.x = view.pan.x + (local_pos.x - new_dx - ratio_x * new_dw)
			view.pan.y = view.pan.y + (local_pos.y - new_dy - ratio_y * new_dh)

			return true
		end

		if button == "button_1" then
			view.panning = press

			if press then
				view.drag_start = local_pos:Copy()
				view.drag_pan_start = view.pan:Copy()
			end

			return true
		end

		if button == "button_3" and press then
			if self.last_click_time and system.GetTime() - self.last_click_time < 0.3 then
				view.zoom = 1
				view.pan = Vec2(0, 0)
				self.last_click_time = 0

				return true
			end

			self.last_click_time = system.GetTime()
		end
	end, {})
	local on_mouse_move = react.UseCallback(|self, local_pos| -> do
		if view.panning then
			view.pan = view.drag_pan_start + (local_pos - view.drag_start)
			view.set_pixel_text(info.idle)

			return true
		end

		local size = self.transform:GetSize()
		local draw_x, draw_y, draw_w, draw_h = compute_draw_rect(view, size.x, size.y)

		if
			info.can_read and
			local_pos.x >= draw_x and
			local_pos.x < draw_x + draw_w and
			local_pos.y >= draw_y and
			local_pos.y < draw_y + draw_h
		then
			local x = math.clamp(math.floor((local_pos.x - draw_x) / draw_w * view.width), 0, view.width - 1)
			local y = math.clamp(math.floor((local_pos.y - draw_y) / draw_h * view.height), 0, view.height - 1)
			local r, g, b, a = texture:GetPixel(x, y)
			view.set_pixel_text(string.format("%d, %d  |  %d, %d, %d, %d  |  #%02x%02x%02x", x, y, r, g, b, a, r, g, b))
		else
			view.set_pixel_text(info.idle)
		end
	end, {})
	local channel_rows = {}

	if not info.can_read then
		channel_rows[1] = Text{
			Key = "unavailable",
			Text = info.unavailable,
			Font = "body XS",
			Color = "text_disabled",
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
	end

	for _, channel in ipairs(info.stats) do
		channel_rows[#channel_rows + 1] = ChannelRow{Key = channel.label, Channel = channel}
	end

	return ViewerWindow{Title = path ?? "Texture Viewer", Size = Vec2(800, 600)}{
		Splitter{InitialSize = 550}{
			Canvas{
				Name = "TextureCanvas",
				OnDraw = draw,
				OnMouseInput = on_mouse_input,
				OnMouseMove = on_mouse_move,
			},
			Column{
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					ChildGap = 8,
					Padding = Rect() + theme.active:GetPadding("S"),
				},
			}{
				Heading("TEXTURE"),
				Column{layout = {GrowWidth = 1, FitHeight = true, AlignmentX = "stretch", ChildGap = 4}}{
					InfoRow{Label = "Path:", Value = path ?? ""},
					InfoRow{Label = "Size:", Value = info.width .. " × " .. info.height},
					PixelRow{View = view, Idle = info.idle},
				},
				Heading("CHANNELS"),
				Column{layout = {GrowWidth = 1, FitHeight = true, AlignmentX = "stretch", ChildGap = 4}}{channel_rows},
				Heading("VIEW"),
				Column{layout = {GrowWidth = 1, FitHeight = true, AlignmentX = "stretch", ChildGap = 6}}{
					Row{layout = {Direction = "x", GrowWidth = 1, FitHeight = true, AlignmentY = "center", ChildGap = 4}}{
						list.map(
							CHANNEL_NAMES,
							|name| -> Checkbox{
								Key = name,
								Text = name,
								Font = "body XS",
								Value = channels[name],
								OnChange = |value| -> set_channels(|current| -> do
									local next_channels = table.shallow_copy(current)
									next_channels[name] = value

									return next_channels
								end),
							}
						),
					},
					Row{layout = {Direction = "x", GrowWidth = 1, FitHeight = true, AlignmentY = "center", ChildGap = 4}}{
						Checkbox{Text = "Show Grid", Font = "body XS", Value = show_grid, OnChange = set_show_grid},
					},
					Button{
						Text = "Reset View",
						Mode = "outline",
						OnClick = || -> do
							view.zoom = 1
							view.pan = Vec2(0, 0)
							set_channels(ALL_CHANNELS)
						end,
					},
				},
				Heading("PROPERTIES"),
				ScrollablePanel{ScrollX = false, ScrollY = true, layout = {GrowWidth = 1, GrowHeight = 1}}{
					PropertyEditor{Ref = editor, layout = {GrowHeight = 1, FitWidth = false}},
				},
			},
		},
	}
end)

return function(texture, texture_path)
	local window = react.Mount(TextureView{Texture = texture, Path = texture_path}, Panel.World):GetEntity()
	texture:CallOnRemove(window)

	return window
end
