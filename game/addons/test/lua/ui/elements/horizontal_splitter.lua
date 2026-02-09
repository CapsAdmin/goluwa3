local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
local window = require("window")
local timer = require("timer")
return function(props)
	local divider_width = props.DividerWidth or 6
	local initial_width = props.InitialWidth or 220
	props.InitialWidth = nil
	props.DividerWidth = nil
	local divider
	local state = {
		is_dragging = false,
		is_hovered = false,
	}
	local splitter = Panel.NewPanel(
		table.merge_many(
			{
				Name = "HorizontalSplitter",
				Color = theme.GetColor("invisible"),
				layout = {
					Direction = "x",
					GrowWidth = 1,
					GrowHeight = 1,
					ChildGap = 0,
					AlignmentY = "stretch",
				},
				PreChildAdd = function(self, child)
					if child.IsInternal then return true end

					local children = self:GetChildren()
					local actual_children_count = 0

					for _, c in ipairs(children) do
						if not c.IsInternal then actual_children_count = actual_children_count + 1 end
					end

					if actual_children_count >= 2 then
						error("HorizontalSplitter can only have 2 children, but attempted to add a third")
					end

					if actual_children_count == 0 then
						-- First child is the left panel
						if child.layout then
							child.layout:SetMinSize(Vec2(initial_width, 0))
							child.layout:SetMaxSize(Vec2(initial_width, 0))
							child.layout:SetGrowHeight(1)
							child.layout:SetFitWidth(false)
						end
					elseif actual_children_count == 1 then
						-- Second child is the right panel
						if child.layout then
							child.layout:SetGrowWidth(1)
							child.layout:SetGrowHeight(1)
						end

						self:AddChild(divider, 2)
					end

					return true
				end,
				PreRemoveChildren = function(self)
					local children = self:GetChildren()

					for i = #children, 1, -1 do
						local child = children[i]

						if not child.IsInternal then
							child:UnParent()
							child:Remove()
						end
					end

					return false
				end,
			},
			props
		)
	)
	divider = Panel.NewPanel(
		{
			IsInternal = true,
			Name = "Divider",
			Size = Vec2(divider_width, 0),
			layout = {
				GrowHeight = 1,
			},
			Color = Color(0, 0, 0, 0.2),
			Cursor = "horizontal_resize",
			OnHover = function(self, hovered)
				state.is_hovered = hovered

				if not state.is_dragging and self.rect then
					self.rect:SetColor(Color(0, 0, 0, hovered and 0.5 or 0.2))
				end
			end,
			gui_element = {
				OnDraw = function(self)
					theme.DrawDivider(self.Owner)
				end,
			},
			OnDraw = function() end,
			mouse_input = {
				OnMouseInput = function(self, button, press, local_pos)
					if button == "button_1" then
						state.is_dragging = press

						if press then
							if self.Owner.rect then
								self.Owner.rect:SetColor(theme.GetColor("primary"):Copy():SetAlpha(0.8))
							end
						else
							if self.Owner.rect then
								self.Owner.rect:SetColor(Color(0, 0, 0, state.is_hovered and 0.5 or 0.2))
							end
						end

						return true
					end
				end,
				OnGlobalMouseInput = function(self, button, press)
					if button == "button_1" and not press and state.is_dragging then
						state.is_dragging = false

						if self.Owner.rect then
							self.Owner.rect:SetColor(Color(0, 0, 0, state.is_hovered and 0.5 or 0.2))
						end
					end
				end,
				OnGlobalMouseMove = function(self, pos)
					if state.is_dragging then
						local lpos = splitter.transform:GlobalToLocal(pos)
						local new_width = math.max(50, lpos.x)
						local left_panel

						for _, child in ipairs(splitter:GetChildren()) do
							if not child.IsInternal then
								left_panel = child

								break
							end
						end

						if left_panel and left_panel.layout then
							left_panel.layout:SetMinSize(Vec2(new_width, 0))
							left_panel.layout:SetMaxSize(Vec2(new_width, 0))
							left_panel.layout:InvalidateLayout(true)
						end

						self:SetCursor("horizontal_resize")
						return true
					end

					if self:GetHovered() then
						self:SetCursor("horizontal_resize")
						return true
					end
				end,
			},
		}
	)
	return splitter
end
