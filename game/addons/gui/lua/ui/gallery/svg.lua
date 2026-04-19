local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Button = import("../elements/button.lua")
local Column = import("../elements/column.lua")
local Frame = import("../elements/frame.lua")
local Row = import("../elements/row.lua")
local Slider = import("../elements/slider.lua")
local SVG = import("../elements/svg.lua")
local Text = import("../elements/text.lua")
local TextEdit = import("../elements/text_edit.lua")
local icon_sources = {
	{"Home", "https://api.iconify.design/mdi-light/home.svg"},
	{"Heart", "https://api.iconify.design/mdi-light/heart.svg"},
	{"Account", "https://api.iconify.design/mdi-light/account.svg"},
	{"Cog", "https://api.iconify.design/mdi-light/cog.svg"},
	{"Bell", "https://api.iconify.design/mdi-light/bell.svg"},
	{"Camera", "https://api.iconify.design/mdi-light/camera.svg"},
	{"Folder", "https://api.iconify.design/mdi-light/folder.svg"},
	{"Cloud", "https://api.iconify.design/mdi-light/cloud.svg"},
	{"Play", "https://api.iconify.design/mdi-light/play.svg"},
	{"Star", "https://api.iconify.design/mdi-light/star.svg"},
	{"Email", "https://api.iconify.design/mdi-light/email.svg"},
	{"Check", "https://api.iconify.design/mdi-light/check.svg"},
}
local default_custom_source = "https://api.iconify.design/mdi-light/star.svg"
return {
	Name = "svg",
	Create = function()
		local state = {
			icon_size = 72,
			custom_source = default_custom_source,
		}
		local icon_panels = {}
		local custom_preview
		local custom_input
		local size_label
		local status_label

		local function set_status(value)
			if status_label and status_label:IsValid() then
				status_label.text:SetText(value or "")
			end
		end

		local function update_size_label()
			if size_label and size_label:IsValid() then
				size_label.text:SetText(string.format("Icon Size: %d", math.floor(state.icon_size + 0.5)))
			end
		end

		local function apply_icon_sizes()
			for _, panel in ipairs(icon_panels) do
				if panel and panel:IsValid() then
					panel.transform:SetSize(Vec2(state.icon_size, state.icon_size))
				end
			end

			if custom_preview and custom_preview:IsValid() then
				custom_preview.transform:SetSize(Vec2(state.icon_size * 2, state.icon_size * 2))
			end

			update_size_label()
		end

		local function load_custom_source()
			if
				not custom_preview or
				not custom_preview:IsValid()
				or
				not custom_input or
				not custom_input:IsValid()
			then
				return
			end

			state.custom_source = custom_input:GetText()
			set_status("Loading custom SVG...")
			custom_preview:SetSource(state.custom_source)
		end

		local function build_icon_tile(label, source)
			local tile_svg
			local frame = Frame{
				Padding = Rect() + 12,
				layout = {
					FitWidth = true,
					FitHeight = true,
					MinSize = Vec2(132, 148),
				},
			}{
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						AlignmentX = "center",
						AlignmentY = "center",
						ChildGap = 8,
					},
				}{
					SVG{
						Ref = function(self)
							tile_svg = self
							icon_panels[#icon_panels + 1] = self
							self.transform:SetSize(Vec2(state.icon_size, state.icon_size))
						end,
						Source = source,
						Color = "text_foreground",
						Padding = Rect() + 6,
					},
					Text{
						Text = label,
						IgnoreMouseInput = true,
						AlignX = "center",
					},
				},
			}
			return frame
		end

		local grid_rows = {}

		for i = 1, #icon_sources, 4 do
			local row_children = {}

			for j = i, math.min(i + 3, #icon_sources) do
				row_children[#row_children + 1] = build_icon_tile(icon_sources[j][1], icon_sources[j][2])
			end

			grid_rows[#grid_rows + 1] = Row{
				layout = {
					FitHeight = true,
					GrowWidth = 1,
					AlignmentY = "start",
					AlignmentX = "stretch",
					ChildGap = 12,
				},
			}(row_children)
		end

		local page = Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 14,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "SVG Panel",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "These icons are loaded through the resource system. URLs are fetched and cached, local paths are read directly when available, and raw SVG content is accepted for the custom preview below.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
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
					Ref = function(self)
						size_label = self
						update_size_label()
					end,
					Text = "Icon Size: 72",
					IgnoreMouseInput = true,
				},
				Slider{
					Value = state.icon_size,
					Min = 24,
					Max = 160,
					OnChange = function(value)
						state.icon_size = value
						apply_icon_sizes()
					end,
					layout = {
						GrowWidth = 1,
					},
				},
			},
			Column{
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					ChildGap = 12,
				},
			}(grid_rows),
			Text{
				Text = "Custom Source",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "Paste an Iconify URL, a local path, or raw SVG markup. If the input contains '<svg' it is treated as inline SVG content; otherwise it is treated as a path or URL.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Row{
				layout = {
					GrowWidth = 1,
					AlignmentY = "start",
					ChildGap = 16,
				},
			}{
				Frame{
					Padding = Rect() + 16,
					layout = {
						FitWidth = true,
						FitHeight = true,
						MinSize = Vec2(state.icon_size * 2 + 32, state.icon_size * 2 + 32),
					},
				}{
					SVG{
						Ref = function(self)
							custom_preview = self
							self.transform:SetSize(Vec2(state.icon_size * 2, state.icon_size * 2))
						end,
						Source = state.custom_source,
						Color = "text_foreground",
						Padding = Rect() + 8,
						OnLoad = function()
							set_status("Loaded custom SVG")
						end,
						OnError = function(_, reason)
							set_status("Failed to load SVG: " .. tostring(reason))
						end,
					},
				},
				Column{
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						AlignmentX = "stretch",
						ChildGap = 10,
					},
				}{
					TextEdit{
						Ref = function(self)
							custom_input = self
							self:SetText(state.custom_source)
						end,
						Text = state.custom_source,
						Size = Vec2(0, 120),
						MinSize = Vec2(280, 120),
						MaxSize = Vec2(0, 120),
						Wrap = true,
						layout = {
							GrowWidth = 1,
						},
					},
					Row{
						layout = {
							GrowWidth = 1,
							ChildGap = 10,
							AlignmentY = "center",
						},
					}{
						Button{
							Text = "Load",
							OnClick = load_custom_source,
						},
						Button{
							Text = "Use Inline Sample",
							Mode = "outline",
							OnClick = function()
								local sample = [[<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24"><path fill="currentColor" d="M12 2L3 7v10l9 5l9-5V7zm0 2.3L18.8 8L12 11.7L5.2 8zM5 9.7l6 3.3v6.4l-6-3.3zm14 0v6.4l-6 3.3V13z"/></svg>]]
								state.custom_source = sample

								if custom_input and custom_input:IsValid() then custom_input:SetText(sample) end

								set_status("Loading custom SVG...")

								if custom_preview and custom_preview:IsValid() then
									custom_preview:SetSource(sample)
								end
							end,
						},
					},
					Text{
						Ref = function(self)
							status_label = self
							set_status("Loaded custom SVG")
						end,
						Text = "",
						Wrap = true,
						IgnoreMouseInput = true,
						layout = {
							GrowWidth = 1,
						},
					},
				},
			},
		}
		apply_icon_sizes()
		return page
	end,
}
