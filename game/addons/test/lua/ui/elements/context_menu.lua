local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Panel = require("ecs.panel")
local Frame = require("ui.elements.frame")
local theme = require("ui.theme")
return function(props)
	local menu_ent
	local is_closing = false

	local function UpdateAnimations(ent)
		if not menu_ent or not menu_ent:IsValid() then return end

		print("open", is_closing)
		_G.MENU = menu_ent

		if is_closing then
			menu_ent.transform:SetDrawScaleOffset(Vec2(1, 1))
		else
			menu_ent.transform:SetDrawScaleOffset(Vec2(1, 0))
		end

		menu_ent.animation:Animate(
			{
				id = "menu_open_close",
				get = function()
					local s = menu_ent.transform:GetDrawScaleOffset()
					return s
				end,
				set = function(v)
					menu_ent.transform:SetDrawScaleOffset(Vec2(1, v.y))
				end,
				to = is_closing and Vec2(1, 0) or Vec2(1, 1),
				time = 0.2,
				interpolation = "outExpo",
				callback = function()
					if is_closing and menu_ent:IsValid() and props.OnClose and ent:IsValid() then
						props.OnClose(ent)
					end
				end,
			}
		)
		menu_ent.animation:Animate(
			{
				id = "menu_open_close_fade",
				get = function()
					local s = menu_ent.rect:GetDrawAlpha()
					return s
				end,
				set = function(v)
					menu_ent.rect:SetDrawAlpha(v)
				end,
				to = is_closing and 0 or 1,
				time = 1,
				interpolation = "outExpo",
			}
		)
	end

	return Panel.NewPanel(
		{
			PreChildAdd = function(self, child)
				if child.IsInternal then return end

				if menu_ent then menu_ent:AddChild(child) end

				return false
			end,
			PreRemoveChildren = function(self)
				if menu_ent then menu_ent:RemoveChildren() end

				return false
			end,
			Name = "ContextMenuContainer",
			Size = Vec2(render2d.GetSize()),
			Color = theme.GetColor("invisible"),
			mouse_input = {
				BringToFrontOnClick = true,
				OnMouseInput = function(self, button, press)
					if press and button == "button_1" then
						is_closing = true
						UpdateAnimations(self.Owner)
						self:SetIgnoreMouseInput(true)
						return true
					end
				end,
			},
			OnVisibilityChanged = function(self, visible)
				if visible then is_closing = false else is_closing = true end

				UpdateAnimations(self)
			end,
			key_input = {
				OnKeyInput = function(self, key, press)
					if press and key == "escape" then
						is_closing = true
						UpdateAnimations(self.Owner)
						self.mouse_input:SetIgnoreMouseInput(true)
						return true
					end
				end,
			},
		}
	)(
		{
			Frame(
				{
					IsInternal = true,
					Name = "ContextMenu",
					Pivot = Vec2(0, 0),
					Position = props.Position or Vec2(100, 100),
					Size = props.Size or (Vec2() + theme.GetSize("M")),
					Emphasis = 0,
					Padding = "XS",
					layout = {
						Floating = true,
						Direction = "y",
						ChildGap = 0,
						AlignmentX = "stretch",
						FitHeight = true,
						FitWidth = true,
					},
					OnMouseInput = function(self, button, press)
						return true
					end,
					Ref = function(self)
						self:RequestFocus()
						menu_ent = self
						UpdateAnimations(self)
					end,
					key_input = {
						OnKeyInput = function(self, key, press)
							if press and key == "escape" then
								is_closing = true
								UpdateAnimations(self.Owner)

								if self.Owner:HasParent() then
									self.Owner:GetParent().mouse_input:SetIgnoreMouseInput(true)
									return true
								end
							end
						end,
					},
				}
			),
		}
	)
end
