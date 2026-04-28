local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Text = import("lua/ui/elements/text.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local theme = import("lua/ui/theme.lua")

local function resolve_size(value)
	if type(value) == "string" then return theme.GetSize(value) end

	return value
end

local function resolve_color(value, fallback)
	if value == nil then value = fallback end

	if type(value) == "string" then return theme.GetColor(value) end

	return value
end

return function(props)
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local header_tooltip = props.Tooltip
	local header_tooltip_max_width = props.TooltipMaxWidth
	local header_tooltip_options = props.TooltipOptions
	local header_tooltip_offset = props.TooltipOffset
	local header_height = props.HeaderHeight
	local header_mode = props.HeaderMode or "outline"
	local header_text_color = props.HeaderTextColor or "text"
	local header_padding = props.HeaderPadding or "XS"
	local header_gap = props.HeaderGap or "XXS"
	local header_font_name = props.HeaderFontName or "body"
	local header_font_size = props.HeaderFontSize or "M"
	local content_padding = props.ContentPadding or "none"
	local arrow_size = resolve_size(props.HeaderArrowSize) or 16
	local disclosure_size = resolve_size(props.HeaderDisclosureSize) or 10
	local collapsed = props.Collapsed or false
	local body_panel = NULL
	local clip_panel = NULL
	local open_fraction = collapsed and 0 or 1
	local container = Panel.New{
		props,
		{
			Name = "Collapsible",
			OnSetProperty = theme.OnSetProperty,
			transform = true,
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
			},
			PreChildAdd = function(self, child)
				if child.IsInternal then return end

				if not body_panel:IsValid() then return end

				body_panel:AddChild(child)
				return false
			end,
			PreRemoveChildren = function(self)
				if not body_panel:IsValid() then return end

				body_panel:RemoveChildren()
				return false
			end,
			gui_element = true,
			animation = true,
		},
	}

	local function update_height()
		if not body_panel:IsValid() or not clip_panel:IsValid() or not container:IsValid() then
			return
		end

		local clip_w = clip_panel.transform:GetWidth()

		if body_panel.transform:GetWidth() ~= clip_w then
			body_panel.transform:SetWidth(clip_w)
		end

		local h = body_panel.transform:GetHeight()
		local target_h = h * open_fraction
		clip_panel.transform:SetHeight(target_h)
		clip_panel.gui_element:SetVisible(open_fraction > 0.001)
		body_panel.transform:SetY(-(h - target_h))
		container.layout:InvalidateLayout()
	end

	local function set_collapsed(value, instant)
		collapsed = value == true
		local target = collapsed and 0 or 1

		if props.OnToggle then props.OnToggle(collapsed) end

		if instant then
			open_fraction = target
			update_height()
			return
		end

		container.animation:Animate{
			id = "collapsible_slide",
			get = function()
				return open_fraction
			end,
			set = function(v)
				open_fraction = v
				update_height()
			end,
			to = target,
			time = 0.3,
			interpolation = "outExpo",
		}
	end

	local header = Clickable{
		IsInternal = true,
		Name = "Header",
		Tooltip = header_tooltip,
		TooltipOptions = header_tooltip_options,
		TooltipMaxWidth = header_tooltip_max_width,
		TooltipOffset = header_tooltip_offset,
		Mode = header_mode,
		layout = {
			Direction = "x",
			AlignmentY = "center",
			FitHeight = true,
			MinSize = header_height and Vec2(0, header_height) or nil,
			MaxSize = header_height and Vec2(0, header_height) or nil,
			Padding = header_padding,
			ChildGap = header_gap,
		},
		OnClick = function(self)
			set_collapsed(not collapsed)
		end,
	}{
		Panel.New{
			IsInternal = true,
			Name = "ArrowContainer",
			OnSetProperty = theme.OnSetProperty,
			transform = {
				Size = Vec2() + theme.GetFontSize(header_font_size),
			},
			gui_element = {
				OnDraw = function(self)
					theme.active:DrawIcon(
						"disclosure",
						self.Owner,
						{
							thickness = 2,
							open_fraction = open_fraction,
							color = resolve_color(header_text_color, "text"),
						}
					)
				end,
			},
			mouse_input = {
				Cursor = "pointer",
				IgnoreMouseInput = true,
			},
		},
		Text{
			Text = props.Title or "Collapsible",
			Color = header_text_color,
			FontName = header_font_name,
			FontSize = header_font_size,
			layout = {
				GrowWidth = 1,
				FitHeight = true,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		},
	}
	body_panel = Panel.New{
		IsInternal = true,
		Name = "Body",
		OnSetProperty = theme.OnSetProperty,
		layout = {
			Direction = "y",
			FitHeight = true,
			GrowWidth = 1,
			AlignmentX = "stretch",
			Padding = content_padding,
			Floating = true,
		},
		transform = true,
		gui_element = true,
		Events = {
			OnLayoutUpdated = function()
				update_height()
			end,
		},
	}
	clip_panel = Panel.New{
		IsInternal = true,
		Name = "ClipContainer",
		OnSetProperty = theme.OnSetProperty,
		Ref = function(self)
			self:AddLocalListener("OnTransformChanged", update_height)
			self:AddLocalListener("OnLayoutUpdated", update_height)
		end,
		transform = {
			Size = Vec2(0, 0),
		},
		layout = {
			FitHeight = false,
			GrowWidth = 1,
		},
		gui_element = {
			Clipping = true,
			Visible = not collapsed,
		},
	}(body_panel)

	function container:SetCollapsed(value, instant)
		set_collapsed(value, instant)
		return self
	end

	function container:GetCollapsed()
		return collapsed
	end

	function container:ToggleCollapsed(instant)
		set_collapsed(not collapsed, instant)
		return self
	end

	update_height()
	container = container{
		header,
		clip_panel,
	}

	if external_ref then external_ref(container) end

	return container
end
