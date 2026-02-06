local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
local window = require("window")
return function(props)
	local divider_width = props.DividerWidth or 6
	local initial_width = props.InitialWidth or 220
	props.InitialWidth = nil
	props.DividerWidth = nil
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
			},
			props
		)
	)
	local state = {
		is_dragging = false,
		is_hovered = false,
	}
	local divider = Panel.NewPanel(
		{
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
						local children = splitter:GetChildren()

						if children[1] and children[1].layout then
							children[1].layout:SetMinSize(Vec2(new_width, 0))
							children[1].layout:SetMaxSize(Vec2(new_width, 0))
							children[1].layout:InvalidateLayout(true)
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

	function divider:OnDraw() -- We use the rect component for the color, but we could add custom drawing here if needed.
	end

	-- We override AddChild to handle the divider placement
	local old_AddChild = splitter.AddChild

	function splitter:AddChild(child)
		if child == divider then
			old_AddChild(self, child)
			return
		end

		local children = self:GetChildren()
		local actual_children_count = 0

		for _, c in ipairs(children) do
			if c ~= divider then actual_children_count = actual_children_count + 1 end
		end

		if actual_children_count == 0 then
			-- First child is the left panel
			if child.layout then
				child.layout:SetMinSize(Vec2(initial_width, 0))
				child.layout:SetMaxSize(Vec2(initial_width, 0))
				child.layout:SetGrowHeight(1)
				child.layout:SetFitWidth(false)
			end

			old_AddChild(self, child)
			self:AddChild(divider)
		elseif actual_children_count == 1 then
			-- Second child is the right panel
			if child.layout then
				child.layout:SetGrowWidth(1)
				child.layout:SetGrowHeight(1)
			end

			old_AddChild(self, child)
		else
			old_AddChild(self, child)
		end
	end

	return splitter
end
