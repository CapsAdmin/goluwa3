local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("splitter")
META.CMP.transform = {}
META.CMP.layout = {
	GrowWidth = 1,
	GrowHeight = 1,
	ChildGap = 0,
}
META.CMP.visual = {}
META.CMP.mouse_input = {}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Vertical", false)
META:GetSet("InitialSize", 220)
META:GetSet("DividerWidth", nil)
META:GetSet("MinSplitSize", nil)
META:EndStorable()

local function on_divider_draw(divider)
	theme.active:Draw(divider)
end

local function on_divider_hover(divider, hovered)
	divider.Splitter._hovered = hovered
end

local function on_divider_mouse_input(divider, button, press)
	if button ~= "button_1" then return end

	local splitter = divider.Splitter
	splitter._dragging = press

	if press then
		splitter._drag_start_mouse = divider.mouse_input:GetGlobalMousePosition():Copy()
		splitter._drag_start_size = splitter._size
	else
		splitter._drag_start_mouse = nil
	end

	return true
end

local function on_divider_global_mouse_input(divider, button, press)
	local splitter = divider.Splitter

	if button == "button_1" and not press and splitter._dragging then
		splitter._dragging = false
		splitter._drag_start_mouse = nil
	end
end

local function on_divider_global_mouse_move(divider, pos)
	local splitter = divider.Splitter

	if splitter._dragging then
		local delta = pos - (splitter._drag_start_mouse or pos)
		splitter:SetSplitSize(splitter._drag_start_size + (splitter.Vertical and delta.y or delta.x), true)
		divider.mouse_input:SetCursor(splitter._cursor)
		return true
	end

	if divider.mouse_input:GetHovered() then
		divider.mouse_input:SetCursor(splitter._cursor)
		return true
	end
end

function META:OnCreate(props)
	local vertical = props.Vertical or false
	props.layout = {
		Direction = vertical and "y" or "x",
		AlignmentX = vertical and "stretch" or nil,
		AlignmentY = vertical and nil or "stretch",
		props.layout,
	}
	META.BaseClass.OnCreate(self, props)
	local divider_width = theme.active:ResolveSize(self.DividerWidth or "XS")
	self._min_split_size = theme.active:ResolveSize(self.MinSplitSize or "XXL")
	self._size = self.InitialSize
	self._dragging = false
	self._hovered = false
	self._drag_start_size = self.InitialSize
	self._cursor = vertical and "vertical_resize" or "horizontal_resize"
	self._divider = Panel.New{
		IsInternal = true,
		Name = "splitter_divider",
		Splitter = self,
		transform = {
			Size = vertical and Vec2(0, divider_width) or Vec2(divider_width, 0),
		},
		layout = {
			GrowHeight = vertical and 0 or 1,
			GrowWidth = vertical and 1 or 0,
		},
		mouse_input = {Cursor = self._cursor},
		visual = true,
		animation = true,
		clickable = true,
		OnHover = on_divider_hover,
		OnMouseInput = on_divider_mouse_input,
		OnGlobalMouseInput = on_divider_global_mouse_input,
		OnGlobalMouseMove = on_divider_global_mouse_move,
		OnDraw = on_divider_draw,
	}
end

function META.OnChange(size, splitter) end

function META:get_external_children()
	local first
	local second

	for _, child in ipairs(self:GetChildren()) do
		if not child.IsInternal then
			if not first then
				first = child
			else
				second = child

				break
			end
		end
	end

	return first, second
end

function META:get_split_limits(first, second)
	local vertical = self.Vertical
	local divider_size = self._divider.transform:GetSize()
	divider_size = vertical and divider_size.y or divider_size.x
	local min_size = self._min_split_size
	local max_size = math.huge
	local current_total

	if first and second then
		current_total = divider_size + (
				vertical and
				first.transform:GetHeight() + second.transform:GetHeight()
				or
				first.transform:GetWidth() + second.transform:GetWidth()
			)
	else
		local size = self.transform:GetSize()
		current_total = vertical and size.y or size.x
	end

	local second_min_size = 0

	if second and second.layout then
		local min = second.layout:GetMinSize()
		second_min_size = vertical and min.y or min.x
	end

	return min_size,
	math.max(min_size, current_total - divider_size - second_min_size)
end

function META:SetSplitSize(size, emit_change)
	local first, second = self:get_external_children()
	local min_size, max_size = self:get_split_limits(first, second)
	self._size = math.clamp(size, min_size, max_size)

	if first and first.layout then
		if self.Vertical then
			first.layout:SetMinSize(Vec2(0, self._size))
			first.layout:SetMaxSize(Vec2(0, self._size))
		else
			first.layout:SetMinSize(Vec2(self._size, 0))
			first.layout:SetMaxSize(Vec2(self._size, 0))
		end

		first.layout:InvalidateLayout(true)
	end

	if emit_change then self.OnChange(self._size, self) end

	return self
end

function META:GetSplitSize()
	return self._size
end

function META:PreChildAdd(child)
	if child.IsInternal then return end

	local first, second = self:get_external_children()

	if second then
		error("Splitter can only have 2 children, but attempted to add a third")
	end

	if not child.layout then return end

	if not first then
		local initial_size = self.InitialSize

		if self.Vertical then
			child.layout:SetMinSize(Vec2(0, initial_size))
			child.layout:SetMaxSize(Vec2(0, initial_size))
			child.layout:SetGrowHeight(0)
			child.layout:SetGrowWidth(1)
			child.layout:SetFitHeight(false)
		else
			child.layout:SetMinSize(Vec2(initial_size, 0))
			child.layout:SetMaxSize(Vec2(initial_size, 0))
			child.layout:SetGrowWidth(0)
			child.layout:SetGrowHeight(1)
			child.layout:SetFitWidth(false)
		end
	else
		child.layout:SetGrowWidth(1)
		child.layout:SetGrowHeight(1)
		self:AddChild(self._divider, 2)
	end
end

function META:PreRemoveChildren()
	self:RemoveExternalChildren()
	return false
end

return META:Register()
