local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Text = import("lua/ui/elements/text.lua")
local ScrollablePanel = import("lua/ui/elements/scrollable_panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	props = props or {}
	local external_ref = props.Ref
	local wrap = props.Wrap == true
	local scroll_x = props.ScrollX
	local scroll_y = props.ScrollY

	if scroll_x == nil then scroll_x = not wrap end

	if scroll_y == nil then scroll_y = false end

	local size = props.Size or Vec2(400, 34)
	local min_size = props.MinSize or Vec2(100, size.y)
	local max_size = props.MaxSize or Vec2(0, size.y)
	local editable = props.Editable ~= false
	local panel_color = props.PanelColor or "card"
	local background_color = props.BackgroundColor or "surface"
	local text_panel
	local last_text = props.Text or ""

	local function sync_text_changed(panel)
		if not props.OnTextChanged then return end

		local next_text = text_panel and text_panel.text and text_panel.text:GetText() or ""

		if next_text == last_text then return end

		local old_text = last_text
		last_text = next_text
		props.OnTextChanged(next_text, old_text, panel)
	end

	local panel = Panel.New{
		Name = "text_edit",
		Tooltip = props.Tooltip,
		TooltipOptions = props.TooltipOptions,
		OnSetProperty = theme.OnSetProperty,
		Ref = function(self)
			if props.OnTextChanged then self:AddGlobalEvent("Update") end
		end,
		transform = {
			Size = size,
		},
		layout = {
			Direction = "y",
			GrowWidth = 1,
			MinSize = min_size,
			MaxSize = max_size,
			props.layout,
		},
		gui_element = {
			Color = panel_color,
			BorderRadius = props.BorderRadius or 8,
			OnDraw = function(self)
				theme.panels.surface(self)
			end,
			OnPostDraw = function(self)
				if editable then theme.panels.frame_post(self.Owner) end
			end,
		},
		mouse_input = true,
		clickable = true,
		animation = true,
		OnUpdate = function(self)
			sync_text_changed(self)
		end,
	}{
		ScrollablePanel{
			Color = background_color,
			Cursor = editable and "text_input" or nil,
			ScrollX = scroll_x,
			ScrollY = scroll_y,
			ScrollBarVisible = props.ScrollBarVisible,
			ScrollBarAutoHide = props.ScrollBarAutoHide,
			ScrollBarColor = props.ScrollBarColor or "scrollbar",
			ScrollBarTrackColor = props.ScrollBarTrackColor or "scrollbar_track",
			Padding = props.Padding or Rect() + 12,
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
			},
		}{
			Text{
				Ref = function(self)
					text_panel = self
				end,
				Text = props.Text or "",
				Cursor = editable and "text_input" or nil,
				Editable = editable,
				Wrap = wrap,
				Color = props.TextColor or "text_foreground",
				SelectionColor = props.SelectionColor or theme.GetColor("text_selection"),
				FontName = props.FontName,
				FontSize = props.FontSize,
				text = props.text,
				layout = {
					GrowWidth = 1,
					FitWidth = false,
					MinSize = Vec2(1, 0),
				},
			},
		},
	}

	function panel:GetText()
		return text_panel and text_panel.text:GetText() or ""
	end

	function panel:GetTextPanel()
		return text_panel
	end

	function panel:SetText(value)
		value = value or ""

		if text_panel and text_panel.text then text_panel.text:SetText(value) end

		last_text = value
		return self
	end

	function panel:RequestTextFocus()
		if text_panel and text_panel:IsValid() then
			text_panel:RequestFocus()
			return true
		end

		return false
	end

	if external_ref then external_ref(panel) end

	return panel
end
