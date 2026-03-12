local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Text = import("lua/ui/elements/text.lua")
local ScrollablePanel = import("lua/ui/elements/scrollable_panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	props = props or {}
	local size = props.Size or props.MinSize or props.MaxSize or Vec2(400, 180)
	local panel_color = props.PanelColor or "card"
	local background_color = props.BackgroundColor or "surface"
	return Panel.New{
		Name = "text_edit",
		OnSetProperty = theme.OnSetProperty,
		transform = {
			Size = size,
		},
		layout = {
			Direction = "y",
			GrowWidth = 1,
			MinSize = props.MinSize or size,
			MaxSize = props.MaxSize or size,
			props.layout,
		},
		gui_element = {
			Color = panel_color,
			BorderRadius = props.BorderRadius or 8,
			OnDraw = function(self)
				theme.panels.surface(self)
			end,
		},
		mouse_input = true,
		clickable = true,
		animation = true,
	}{
		ScrollablePanel{
			Color = background_color,
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
				Text = props.Text or "",
				Editable = props.Editable ~= false,
				Wrap = props.Wrap ~= false,
				Color = props.TextColor or "text_foreground",
				FontName = props.FontName,
				FontSize = props.FontSize,
				text = props.text,
				layout = {
					GrowWidth = 1,
				},
			},
		},
	}
end