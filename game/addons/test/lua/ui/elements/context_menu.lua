local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Panel = require("ecs.entities.2d.panel")
local Frame = runfile("lua/ui/elements/frame.lua")
return function(props)
	local menu_ent
	local container_ent
	local is_closing = false

	local function UpdateAnimations()
		if not menu_ent then return end

		menu_ent.animation:Animate(
			{
				id = "menu_open_close",
				get = function()
					return menu_ent.transform:GetDrawScaleOffset()
				end,
				set = function(v)
					menu_ent.transform:SetDrawScaleOffset(v)
				end,
				to = is_closing and Vec2(1, 0) or Vec2(1, 1),
				time = 0.2,
				interpolation = "outExpo",
				callback = function()
					if is_closing and props.OnClose then props.OnClose(container_ent) end
				end,
			}
		)
	end

	return Panel(
		{
			Ref = function(self)
				container_ent = self
			end,
			Name = "ContextMenuContainer",
			Size = Vec2(render2d.GetSize()),
			Color = Color(0, 0, 0, 0), -- Invisible background to catch clicks
			mouse_input = {
				BringToFrontOnClick = true,
				OnMouseInput = function(self, button, press)
					if press and button == "button_1" then
						is_closing = true
						UpdateAnimations()
						return true
					end
				end,
			},
			OnVisibilityChanged = function(self, visible)
				if visible then is_closing = false else is_closing = true end

				print("ContextMenu visibility changed:", visible, is_closing)
				UpdateAnimations()
			end,
			Children = {
				Frame(
					{
						Name = "ContextMenu",
						Pivot = Vec2(0, 0),
						Position = props.Position or Vec2(100, 100),
						Size = props.Size or Vec2(200, 0),
						Layout = {"SizeToChildrenHeight"},
						Stack = true,
						StackDown = true,
						Padding = Rect(5, 5, 5, 5),
						-- Stop clicks on the menu from closing it via the background panel
						OnMouseInput = function(self, button, press)
							return true
						end,
						Children = props.Children,
						Ref = function(self)
							self:RequestFocus()
							menu_ent = self
							self.DrawScaleOffset = Vec2(1, 0)
							UpdateAnimations()
						end,
						key_input = {
							OnKeyInput = function(self, key, press)
								if press and key == "escape" then
									is_closing = true
									UpdateAnimations()
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
