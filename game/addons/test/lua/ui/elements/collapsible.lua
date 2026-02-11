local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local Text = require("ui.elements.text")
local Clickable = require("ui.elements.clickable")
local theme = require("ui.theme")
local theme_shapes = require("ui.theme_shapes")
local render2d = require("render2d.render2d")
return function(props)
	local collapsed = props.Collapsed or false
	local body_panel = NULL
	local clip_panel = NULL
	local open_fraction = collapsed and 0 or 1
	local container = Panel.New(
		{
			props,
			{
				Name = "Collapsible",
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
	)

	local function update_height()
		if not body_panel:IsValid() or not clip_panel:IsValid() or not container:IsValid() then
			return
		end

		local h = body_panel.transform:GetHeight()
		local target_h = h * open_fraction
		clip_panel.transform:SetHeight(target_h)
		clip_panel.gui_element:SetVisible(open_fraction > 0.001)
		body_panel.transform:SetY(-(h - target_h))
		body_panel.transform:SetWidth(clip_panel.transform:GetWidth())
		container.layout:InvalidateLayout()
	end

	local header = Clickable(
		{
			IsInternal = true,
			Name = "Header",
			rect = {
				Color = theme.GetColor("primary"),
			},
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
				Padding = Rect() + theme.GetPadding("XS"),
				ChildGap = theme.GetSize("XXS"),
			},
			OnClick = function(self)
				collapsed = not collapsed
				container.animation:Animate(
					{
						id = "collapsible_slide",
						get = function()
							return open_fraction
						end,
						set = function(v)
							open_fraction = v
							update_height()
						end,
						to = collapsed and 0 or 1,
						time = 0.3,
						interpolation = "outExpo",
					}
				)
			end,
		}
	)(
		{
			Panel.New(
				{
					IsInternal = true,
					Name = "ArrowContainer",
					transform = {
						Size = Vec2(16, 16),
					},
					gui_element = {
						OnDraw = function(self)
							local size = 10
							local center = self.Owner.transform:GetSize() / 2
							render2d.PushMatrix()
							render2d.Translatef(center.x, center.y)
							render2d.Rotate(math.rad(open_fraction * 90))
							render2d.SetColor(theme.GetColor("text_foreground"):Unpack())
							theme_shapes.DrawArrow(0, 0, size)
							render2d.PopMatrix()
						end,
					},
				}
			),
			Text(
				{
					Text = props.Title or "Collapsible",
					FontName = "heading",
					layout = {
						GrowWidth = 1,
						FitHeight = true,
					},
				}
			),
		}
	)
	body_panel = Panel.New(
		{
			IsInternal = true,
			Name = "Body",
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				AlignmentX = "stretch",
				Padding = Rect() + theme.GetPadding("XS"),
				Floating = true,
			},
			transform = true,
			Events = {
				OnLayoutUpdated = function()
					update_height()
				end,
			},
		}
	)
	clip_panel = Panel.New(
		{
			IsInternal = true,
			Name = "ClipContainer",
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
		}
	)(body_panel)
	update_height()
	return container({
		header,
		clip_panel,
	})
end
