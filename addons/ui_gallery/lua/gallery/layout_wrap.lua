local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")

local alignment_options = {
	{Text = "Start", Value = "start"},
	{Text = "Center", Value = "center"},
	{Text = "End", Value = "end"},
	{Text = "Stretch", Value = "stretch"},
	{Text = "Space Between", Value = "space_between"},
	{Text = "Space Around", Value = "space_around"},
	{Text = "Space Evenly", Value = "space_evenly"},
}

local direction_options = {
	{Text = "Horizontal (row)", Value = "x"},
	{Text = "Vertical (column)", Value = "y"},
}

return {
	Name = "layout_wrap",
	Create = function()
		local state = {
			count = 20,
			item_size = 60,
			alignment = "space_between",
			direction = "x",
			wrap = true,
			child_gap = 10,
		}

		local preview_host

		local function hsl_to_rgb(h, s, l)
			-- Simple HSL to RGB conversion
			h = h % 360
			local c = (1 - math.abs(2 * l - 1)) * s
			local x = c * (1 - math.abs((h / 60) % 2 - 1))
			local m = l - c / 2
			local r, g, b

			if h < 60 then
				r, g, b = c, x, 0
			elseif h < 120 then
				r, g, b = x, c, 0
			elseif h < 180 then
				r, g, b = 0, c, x
			elseif h < 240 then
				r, g, b = 0, x, c
			elseif h < 300 then
				r, g, b = x, 0, c
			else
				r, g, b = c, 0, x
			end

			return r + m, g + m, b + m
		end

		local function get_item_color(index)
			local hue = (index * 37) % 360
			local r, g, b = hsl_to_rgb(hue, 0.7, 0.55)
			return {r = r, g = g, b = b}
		end

		local function build_tile(index)
			local color = get_item_color(index)
			local size = state.item_size

			return Panel.New{
				{
					Name = "Tile " .. index,
					transform = {
						Size = Vec2(size, size),
						MinSize = Vec2(20, 20),
						MaxSize = Vec2(150, 150),
					},
					visual = {
						OnDraw = function()
							render2d.SetColor(color.r, color.g, color.b, 1)
							render2d.DrawRect(0, 0, size, size)
						end,
					},
					layout = {
						MinSize = Vec2(20, 20),
						MaxSize = Vec2(150, 150),
					},
				},
			}
		end

		local function rebuild_preview()
			if not preview_host or not preview_host:IsValid() then return end

			preview_host:RemoveChildren()

			for i = 1, state.count do
				preview_host:AddChild(build_tile(i))
			end

			if preview_host.layout then preview_host.layout:InvalidateLayout(true) end
		end

		local function update_alignment_display()
			local label_text = alignment_options[1].Text
			for _, opt in ipairs(alignment_options) do
				if opt.Value == state.alignment then
					label_text = opt.Text
					break
				end
			end
			return label_text
		end

		local pnl = Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Layout Wrap Demo",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "Explore how the wrap layout distributes children across multiple lines. Adjust the controls below to see how alignment, direction, and spacing affect the layout.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Text{
				Text = "Controls",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 12,
					AlignmentY = "center",
				},
			}{
				Text{
					Text = "Items",
					IgnoreMouseInput = true,
					layout = {
						FitWidth = true,
					},
				},
				Slider{
					Value = state.count,
					Min = 1,
					Max = 100,
					OnChange = function(value)
						state.count = math.floor(value + 0.5)
						rebuild_preview()
					end,
					layout = {
						GrowWidth = 1,
					},
				},
					Text{
						Ref = function(self)
							self.text:SetText(tostring(state.count))
						end,
						Text = tostring(state.count),
						IgnoreMouseInput = true,
						AlignX = 1,
						layout = {
							FitWidth = true,
						},
					},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 12,
					AlignmentY = "center",
				},
			}{
				Text{
					Text = "Size",
					IgnoreMouseInput = true,
					layout = {
						FitWidth = true,
					},
				},
				Slider{
					Value = state.item_size,
					Min = 20,
					Max = 150,
					OnChange = function(value)
						state.item_size = math.floor(value + 0.5)
						rebuild_preview()
					end,
					layout = {
						GrowWidth = 1,
					},
				},
					Text{
						Ref = function(self)
							self.text:SetText(tostring(state.item_size) .. "px")
						end,
						Text = tostring(state.item_size) .. "px",
						IgnoreMouseInput = true,
						AlignX = 1,
						layout = {
							FitWidth = true,
						},
					},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 12,
					AlignmentY = "center",
				},
			}{
				Text{
					Text = "Gap",
					IgnoreMouseInput = true,
					layout = {
						FitWidth = true,
					},
				},
				Slider{
					Value = state.child_gap,
					Min = 0,
					Max = 30,
					OnChange = function(value)
						state.child_gap = math.floor(value + 0.5)
						rebuild_preview()
					end,
					layout = {
						GrowWidth = 1,
					},
				},
					Text{
						Ref = function(self)
							self.text:SetText(tostring(state.child_gap))
						end,
						Text = tostring(state.child_gap),
						IgnoreMouseInput = true,
						AlignX = 1,
						layout = {
							FitWidth = true,
						},
					},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 12,
					AlignmentY = "center",
				},
			}{
				Text{
					Text = "Align",
					IgnoreMouseInput = true,
					layout = {
						FitWidth = true,
					},
				},
				Dropdown{
					Text = update_alignment_display(),
					Value = state.alignment,
					Options = alignment_options,
					GetValue = function()
						return state.alignment
					end,
					GetText = function()
						return update_alignment_display()
					end,
					OnSelect = function(value)
						state.alignment = value
						rebuild_preview()
					end,
					layout = {
						GrowWidth = 1,
					},
					Padding = "XS",
				},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 12,
					AlignmentY = "center",
				},
			}{
				Text{
					Text = "Direction",
					IgnoreMouseInput = true,
					layout = {
						FitWidth = true,
					},
				},
				Dropdown{
					Text = "Horizontal (row)",
					Value = state.direction,
					Options = direction_options,
					GetValue = function()
						return state.direction
					end,
					GetText = function()
						if state.direction == "x" then return "Horizontal (row)" end
						return "Vertical (column)"
					end,
					OnSelect = function(value)
						state.direction = value
						rebuild_preview()
					end,
					layout = {
						GrowWidth = 1,
					},
					Padding = "XS",
				},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
				},
			}{
				Checkbox{
					Value = state.wrap,
					OnChange = function(value)
						state.wrap = value
						rebuild_preview()
					end,
				},
				Text{
					Text = "Wrap",
					IgnoreMouseInput = true,
				},
			},
			Text{
				Text = "Preview",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Frame{
				Padding = Rect() + 8,
				layout = {
					GrowWidth = 1,
					FitHeight = true,
				},
			}{
				Row{
					Ref = function(self)
						preview_host = self
						rebuild_preview()
					end,
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						WrapChildren = true,
						AlignmentX = "space_between",
						AlignmentY = "start",
						ChildGap = 10,
					},
				}{},
			},
		}

		-- Override rebuild to update layout props dynamically
		local original_rebuild = rebuild_preview
		rebuild_preview = function()
			if not preview_host or not preview_host:IsValid() then return end

			preview_host:RemoveChildren()

			local layout = preview_host.layout
			layout:SetDirection(state.direction)
			layout:SetWrapChildren(state.wrap)

			-- Set the appropriate alignment based on direction
			if state.direction == "x" then
				layout:SetAlignmentX(state.alignment)
				layout:SetAlignmentY("start")
			else
				layout:SetAlignmentY(state.alignment)
				layout:SetAlignmentX("start")
			end
			layout:SetChildGap(state.child_gap)

			for i = 1, state.count do
				preview_host:AddChild(build_tile(i))
			end

			layout:InvalidateLayout(true)
		end

		rebuild_preview()
		return pnl
	end,
}
