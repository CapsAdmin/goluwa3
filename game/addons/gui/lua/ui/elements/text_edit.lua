local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Text = import("lua/ui/elements/text.lua")
local ScrollablePanel = import("lua/ui/elements/scrollable_panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	props = props or {}
	local external_ref = props.Ref
	local size = props.Size or Vec2(400, 180)
	local min_size = props.MinSize or Vec2(100, size.y)
	local max_size = props.MaxSize or Vec2(0, size.y)
	local editable = props.Editable ~= false
	local panel_color = props.PanelColor or "card"
	local background_color = props.BackgroundColor or "surface"
	local text_panel
	local panel = Panel.New{
		Name = "text_edit",
		OnSetProperty = theme.OnSetProperty,
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
	}{
		ScrollablePanel{
			Color = background_color,
			Cursor = editable and "text_input" or nil,
			ScrollX = props.ScrollX,
			ScrollY = props.ScrollY,
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
				Wrap = props.Wrap ~= false,
				Color = props.TextColor or "text_foreground",
				SelectionColor = props.SelectionColor or theme.GetColor("text_selection"),
				FontName = props.FontName,
				FontSize = props.FontSize,
				text = props.text,
				layout = {
					GrowWidth = 1,
				},
			},
		},
	}

	function panel:GetText()
		return text_panel and text_panel.text:GetText() or ""
	end

	function panel:SetText(value)
		if text_panel and text_panel.text then text_panel.text:SetText(value or "") end

		return self
	end

	if external_ref then external_ref(panel) end

	return panel
end
