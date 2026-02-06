local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Panel = require("ecs.panel")
local Frame = runfile("lua/ui/elements/frame.lua")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	local menu_ent
	local container_ent
	local is_closing = false

	local function UpdateAnimations()
		if not menu_ent or not menu_ent:IsValid() then return end

		_G.MENU = menu_ent
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
					if is_closing and menu_ent:IsValid() and props.OnClose then
						props.OnClose(container_ent)
					end
				end,
			}
		)
	end

	return Panel.NewPanel(
		{
			Ref = function(self)
				container_ent = self
			end,
			Name = "ContextMenuContainer",
			Size = Vec2(render2d.GetSize()),
			Color = theme.Colors.Invisible, -- Invisible background to catch clicks
			mouse_input = {
				BringToFrontOnClick = true,
				OnMouseInput = function(self, button, press)
					if press and button == "button_1" then
						is_closing = true
						UpdateAnimations()
						self:SetIgnoreMouseInput(true)
						return true
					end
				end,
			},
			OnVisibilityChanged = function(self, visible)
				if visible then is_closing = false else is_closing = true end

				UpdateAnimations()
			end,
			key_input = {
				OnKeyInput = function(self, key, press)
					if press and key == "escape" then
						is_closing = true
						UpdateAnimations()
						self.mouse_input:SetIgnoreMouseInput(true)
						return true
					end
				end,
			},
			Children = {
				Frame(
					{
						Name = "ContextMenu",
						Pivot = Vec2(0, 0),
						Position = props.Position or Vec2(100, 100),
						Size = props.Size or theme.Sizes.ContextMenuSize,
						layout = {
							Floating = true,
							Direction = "y",
							ChildGap = 0,
							AlignmentX = "left",
							FitHeight = true,
							FitWidth = true,
						},
						OnMouseInput = function(self, button, press)
							return true
						end,
						Children = props.Children,
						Ref = function(self)
							self:RequestFocus()
							menu_ent = self
							UpdateAnimations()
						end,
						key_input = {
							OnKeyInput = function(self, key, press)
								if press and key == "escape" then
									is_closing = true
									UpdateAnimations()
									self.Owner:GetParent().mouse_input:SetIgnoreMouseInput(true)
									return true
								end
							end,
						},
					}
				),
			},
		}
	)
end
