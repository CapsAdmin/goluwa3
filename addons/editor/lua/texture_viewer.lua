local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextButton = import("goluwa/render2d/ui/elements/text_button.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
return function(texture, texture_path)
	local zoom = 1.0
	local pan_offset = Vec2(0, 0)
	local is_panning = false
	local drag_start = Vec2(0, 0)
	local drag_pan_start = Vec2(0, 0)
	local show_grid = false
	local canvas_panel
	local tex_w = texture:GetWidth()
	local tex_h = texture:GetHeight()
	local channel_stats = texture:GetChannelStatistics()
	local hover_pixel = nil
	local hover_pixel_text
	local channel_visible = {R = true, G = true, B = true, A = true}
	local active_swizzle = "none"

	local function update_swizzle()
		local count = 0

		if channel_visible.R then count = count + 1 end

		if channel_visible.G then count = count + 1 end

		if channel_visible.B then count = count + 1 end

		if channel_visible.A then count = count + 1 end

		if count == 4 then
			active_swizzle = "none"
		elseif count == 1 then
			if channel_visible.R then active_swizzle = "rrr" end

			if channel_visible.G then active_swizzle = "ggg" end

			if channel_visible.B then active_swizzle = "bbb" end

			if channel_visible.A then active_swizzle = "aaa" end
		else
			active_swizzle = "none"
		end
	end

	local function build_channel_toggle_row()
		local children = {}

		for _, ch_name in ipairs{"R", "G", "B", "A"} do
			children[#children + 1] = Checkbox{
				Value = channel_visible[ch_name],
				OnChange = function(val)
					channel_visible[ch_name] = val
					update_swizzle()
				end,
			}
			children[#children + 1] = Text{
				Text = ch_name,
				Font = "body XS",
				IgnoreMouseInput = true,
				layout = {FitWidth = true},
			}
		end

		return children
	end

	local function build_channel_rows(stats)
		local rows = {}

		for _, ch in ipairs(stats or {}) do
			rows[#rows + 1] = Row{
				layout = {
					Direction = "x",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentY = "center",
					ChildGap = 4,
				},
			}{
				Panel.New{
					transform = {Size = Vec2(10, 10)},
					visual = {
						OnDraw = function(self)
							local r, g, b = 0.5, 0.5, 0.5

							if ch.label == "R" then
								r, g, b = 1, 0, 0
							elseif ch.label == "G" then
								r, g, b = 0, 1, 0
							elseif ch.label == "B" then
								r, g, b = 0, 0, 1
							end

							render2d.SetColor(r, g, b, 1)
							render2d.DrawRect(0, 0, 10, 10)
						end,
					},
					mouse_input = {IgnoreMouseInput = true},
				},
				Text{
					Text = ch.label,
					Font = "body XS",
					IgnoreMouseInput = true,
					layout = {FitWidth = true},
				},
				Text{
					Text = string.format("min:%d max:%d avg:%.0f", ch.min, ch.max, ch.avg),
					Font = "body XS",
					Color = "text_disabled",
					IgnoreMouseInput = true,
					layout = {GrowWidth = 1},
				},
			}
		end

		return rows
	end

	local function reset_view()
		zoom = 1.0
		pan_offset = Vec2(0, 0)
	end

	local function compute_draw_rect(canvas_w, canvas_h, use_zoom)
		use_zoom = use_zoom or zoom
		local aspect = tex_w / tex_h
		local canvas_aspect = canvas_w / canvas_h
		local base_w, base_h

		if aspect > canvas_aspect then
			base_w = canvas_w
			base_h = canvas_w / aspect
		else
			base_h = canvas_h
			base_w = canvas_h * aspect
		end

		local draw_w = base_w * use_zoom
		local draw_h = base_h * use_zoom
		local draw_x = (canvas_w - draw_w) / 2 + pan_offset.x
		local draw_y = (canvas_h - draw_h) / 2 + pan_offset.y
		return draw_x, draw_y, draw_w, draw_h
	end

	return Window{
		Title = texture_path or "Texture Viewer",
		Size = Vec2(800, 600),
		Padding = "none",
		Position = Panel.World.transform:GetSize() / 2 - Vec2(800, 600) / 2,
	}{
		Splitter{
			InitialSize = 550,
		}{
			Panel.New{
				Name = "TextureCanvas",
				transform = true,
				visual = {
					OnDraw = function(self)
						local w, h = self.Owner.transform:GetSize().x, self.Owner.transform:GetSize().y
						render2d.PushClipRect(0, 0, w, h)
						render2d.PushSwizzleMode(active_swizzle)
						local draw_x, draw_y, draw_w, draw_h = compute_draw_rect(w, h)
						render2d.SetTexture(texture)
						render2d.SetColor(1, 1, 1, 1)
						render2d.DrawRect(draw_x, draw_y, draw_w, draw_h)
						render2d.PopSwizzleMode()

						-- grid overlay
						if show_grid and zoom >= 0.5 then
							render2d.SetTexture(nil)
							render2d.SetColor(0.5, 0.5, 0.5, 0.3)

							for i = 0, math.ceil(draw_w / zoom) do
								local x = draw_x + i * zoom
								render2d.DrawRect(x, draw_y, 1, draw_h)
							end

							for j = 0, math.ceil(draw_h / zoom) do
								local y = draw_y + j * zoom
								render2d.DrawRect(draw_x, y, draw_w, 1)
							end
						end

						render2d.PopClip()
					end,
				},
				mouse_input = {
					Cursor = "arrow",
				},
				layout = {
					GrowWidth = 1,
					GrowHeight = 1,
				},
				Ref = function(self)
					canvas_panel = self
				end,
				OnMouseInput = function(self, button, press, local_pos)
					if (button == "mwheel_up" or button == "mwheel_down") and press then
						local old_zoom = zoom

						if button == "mwheel_up" then
							zoom = math.max(0.05, zoom / 1.25)
						else
							zoom = math.min(32.0, zoom * 1.25)
						end

						-- zoom toward cursor
						local w, h = self.transform:GetSize().x, self.transform:GetSize().y
						local old_dx, old_dy, old_dw, old_dh = compute_draw_rect(w, h, old_zoom)
						local new_dx, new_dy, new_dw, new_dh = compute_draw_rect(w, h, zoom)
						local ratio_x = (local_pos.x - old_dx) / old_dw
						local ratio_y = (local_pos.y - old_dy) / old_dh
						pan_offset.x = pan_offset.x + (local_pos.x - new_dx - ratio_x * new_dw)
						pan_offset.y = pan_offset.y + (local_pos.y - new_dy - ratio_y * new_dh)
						return true
					end

					if button == "button_1" then
						is_panning = press

						if press then
							drag_start = local_pos:Copy()
							drag_pan_start = pan_offset:Copy()
						end

						return true
					end

					if button == "button_3" and press then
						if self.last_click_time and (system.GetTime() - self.last_click_time) < 0.3 then
							reset_view()
							self.last_click_time = 0
							return true
						end

						self.last_click_time = system.GetTime()
					end
				end,
				OnMouseMove = function(self, local_pos)
					if is_panning then
						local delta = local_pos - drag_start
						pan_offset = drag_pan_start + delta
						hover_pixel = nil

						if hover_pixel_text and hover_pixel_text:IsValid() then
							hover_pixel_text.text:SetText("-")
						end

						return true
					end

					local w, h = self.transform:GetSize().x, self.transform:GetSize().y
					local draw_x, draw_y, draw_w, draw_h = compute_draw_rect(w, h)

					if
						local_pos.x >= draw_x and
						local_pos.x < draw_x + draw_w and
						local_pos.y >= draw_y and
						local_pos.y < draw_y + draw_h
					then
						local tex_x = math.floor((local_pos.x - draw_x) / draw_w * tex_w)
						local tex_y = math.floor((local_pos.y - draw_y) / draw_h * tex_h)
						tex_x = math.clamp(tex_x, 0, tex_w - 1)
						tex_y = math.clamp(tex_y, 0, tex_h - 1)
						local r, g, b, a = texture:GetPixel(tex_x, tex_y)
						hover_pixel = {x = tex_x, y = tex_y, r = r, g = g, b = b, a = a}

						if hover_pixel_text and hover_pixel_text:IsValid() then
							hover_pixel_text.text:SetText(
								string.format("%d, %d  |  %d, %d, %d, %d  |  #%02x%02x%02x", tex_x, tex_y, r, g, b, a, r, g, b)
							)
						end
					else
						hover_pixel = nil

						if hover_pixel_text and hover_pixel_text:IsValid() then
							hover_pixel_text.text:SetText("-")
						end
					end
				end,
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
				Text{
					Text = "TEXTURE",
					Font = "heading XS",
					IgnoreMouseInput = true,
				},
				Column{
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						AlignmentX = "stretch",
						ChildGap = 4,
					},
				}{
					Row{
						layout = {
							Direction = "x",
							GrowWidth = 1,
							FitHeight = true,
							AlignmentY = "center",
							ChildGap = 4,
						},
					}{
						Text{
							Text = "Path:",
							Font = "body XS",
							Color = "text_disabled",
							IgnoreMouseInput = true,
							layout = {FitWidth = true},
						},
						Text{
							Text = texture_path or "",
							Font = "body XS",
							IgnoreMouseInput = true,
							layout = {GrowWidth = 1},
						},
					},
					Row{
						layout = {
							Direction = "x",
							GrowWidth = 1,
							FitHeight = true,
							AlignmentY = "center",
							ChildGap = 4,
						},
					}{
						Text{
							Text = "Size:",
							Font = "body XS",
							Color = "text_disabled",
							IgnoreMouseInput = true,
							layout = {FitWidth = true},
						},
						Text{
							Text = tostring(tex_w) .. " × " .. tostring(tex_h),
							Font = "body XS",
							IgnoreMouseInput = true,
							layout = {GrowWidth = 1},
						},
					},
					Row{
						layout = {
							Direction = "x",
							GrowWidth = 1,
							FitHeight = true,
							AlignmentY = "center",
							ChildGap = 4,
						},
					}{
						Text{
							Text = "Pixel:",
							Font = "body XS",
							Color = "text_disabled",
							IgnoreMouseInput = true,
							layout = {FitWidth = true},
						},
						Text{
							Ref = function(self)
								hover_pixel_text = self
							end,
							Text = "-",
							Font = "body XS",
							IgnoreMouseInput = true,
							layout = {GrowWidth = 1},
						},
					},
				},
				Text{
					Text = "CHANNELS",
					Font = "heading XS",
					IgnoreMouseInput = true,
				},
				Column{
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						AlignmentX = "stretch",
						ChildGap = 4,
					},
				}(build_channel_rows(channel_stats)),
				Text{
					Text = "VIEW",
					Font = "heading XS",
					IgnoreMouseInput = true,
				},
				Column{
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						AlignmentX = "stretch",
						ChildGap = 6,
					},
				}{
					Row{
						layout = {
							Direction = "x",
							GrowWidth = 1,
							FitHeight = true,
							AlignmentY = "center",
							ChildGap = 4,
						},
					}(build_channel_toggle_row()),
					Row{
						layout = {
							Direction = "x",
							GrowWidth = 1,
							FitHeight = true,
							AlignmentY = "center",
							ChildGap = 4,
						},
					}{
						Checkbox{
							Value = show_grid,
							OnChange = function(val)
								show_grid = val
							end,
						},
						Text{
							Text = "Show Grid",
							Font = "body XS",
							IgnoreMouseInput = true,
						},
					},
					TextButton{
						Text = "Reset View",
						Mode = "outline",
						OnClick = function()
							reset_view()
							channel_visible = {R = true, G = true, B = true, A = true}
							active_swizzle = "none"
						end,
					},
				},
				Text{
					Text = "PROPERTIES",
					Font = "heading XS",
					IgnoreMouseInput = true,
				},
				ScrollablePanel{
					ScrollX = false,
					ScrollY = true,
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
					},
				}{
					PropertyEditor{
						Ref = function(self)
							self:SetObject(texture)
						end,
						layout = {
							GrowHeight = 1,
							FitWidth = false,
						},
					},
				},
			},
		},
	}
end
