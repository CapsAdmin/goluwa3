local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local system = import("goluwa/system.lua")
local Ghost = import("goluwa/render2d/ui/elements/ghost.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Icon = import("goluwa/render2d/ui/elements/icon.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local META = Panel:CreateTemplate("property_list")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
}
META.CMP.mouse_input = {}
META:StartStorable()
META:GetSet("Editor", nil)
META:GetSet("Node", nil)
META:GetSet("Path", "")
META:GetSet("Level", 1)
META:GetSet("Indent", 0)
META:EndStorable()
local GRIP_WIDTH = 16
local INDEX_WIDTH = 22
local ACTION_WIDTH = 22
local DRAG_THRESHOLD = 4

local function get_rows(list)
	return list._rows
end

function META.OpenItemMenu(list, index)
	local actions = list.Node.Actions
	local count = #list.Node.Items
	Panel.OpenContextMenu(
		{
			OnClose = function(self)
				self:Remove()
			end,
		},
		{
			MenuItem{
				Text = "Insert above",
				Icon = "plus",
				OnClick = function()
					actions.Insert(index)
				end,
			},
			MenuItem{
				Text = "Insert below",
				Icon = "plus",
				OnClick = function()
					actions.Insert(index + 1)
				end,
			},
			MenuItem{
				Text = "Duplicate",
				Icon = "copy",
				OnClick = function()
					actions.Duplicate(index)
				end,
			},
			MenuSpacer{},
			MenuItem{
				Text = "Move to top",
				Disabled = index == 1,
				OnClick = function()
					actions.Move(index, 1)
				end,
			},
			MenuItem{
				Text = "Move to bottom",
				Disabled = index == count,
				OnClick = function()
					actions.Move(index, count)
				end,
			},
			MenuSpacer{},
			MenuItem{
				Text = "Delete",
				Icon = "trash",
				OnClick = function()
					actions.Remove(index)
				end,
			},
		}
	)
end

function META:register_control(control, index)
	if control.EditClickCount == nil then return end

	control:SetEditClickCount(2)

	if control.OnDragValue == nil then
		self._drag_controls[#self._drag_controls + 1] = {control = control, index = index}
	end
end

function META:begin_drag(index, pos)
	local source = self._chips and self._chips[index] or self._rows[index]
	self._drag = {
		from = index,
		drop = index,
		ghost = Ghost{
			Parent = Panel.World,
			Source = source,
			GrabPosition = pos,
			Radius = self._chips and source.transform:GetHeight() / 2 or 3,
		},
	}
end

function META:get_chip_drop_index(pos)
	local drop
	local best = math.huge

	for index, chip in ipairs(self._chips) do
		local size = chip.transform:GetSize()
		local top_left = chip.transform:LocalToGlobal(Vec2(0, 0))
		local center = top_left.x + size.x / 2
		local dy = pos.y < top_left.y and
			top_left.y - pos.y or
			pos.y > top_left.y + size.y and
			pos.y - top_left.y - size.y or
			0
		local distance = dy * 8 + math.abs(pos.x - center)

		if distance < best then
			best = distance
			drop = pos.x < center and index or index + 1
		end
	end

	return drop
end

function META:get_drop_index(pos)
	if self._chips then return self:get_chip_drop_index(pos) end

	local rows = get_rows(self)

	for i, row in ipairs(rows) do
		local local_pos = row.transform:GlobalToLocal(pos)

		if local_pos.y < row.transform:GetHeight() / 2 then return i end
	end

	return #rows + 1
end

function META:end_drag()
	local drag = self._drag
	self._drag = nil

	if not drag then return end

	drag.ghost:Remove()
	local to = drag.drop > drag.from and drag.drop - 1 or drag.drop

	if to ~= drag.from then self.Node.Actions.Move(drag.from, to) end
end

function META:OnGlobalMouseMove(pos)
	local pending = self._pending

	if
		pending and
		(
			math.abs(pos.x - pending.pos.x) >= DRAG_THRESHOLD or
			math.abs(pos.y - pending.pos.y) >= DRAG_THRESHOLD
		)
	then
		self._pending = nil
		self:begin_drag(pending.index, pending.pos)
	end

	if self._drag then
		self._drag.drop = self:get_drop_index(pos)
		return true
	end
end

function META:OnGlobalMouseInput(button, press, pos)
	if button ~= "button_1" then return end

	if press then
		for _, entry in ipairs(self._drag_controls) do
			if entry.control.visual:IsHovered(pos) and not entry.control:IsEditing() then
				self._pending = {index = entry.index, pos = pos:Copy()}

				break
			end
		end

		return
	end

	self._pending = nil

	if self._drag then self:end_drag() end
end

local function draw_row(row)
	local list = row.List
	local drag = list._drag
	local size = row.transform:GetSize()
	local active = theme.active

	if drag and drag.drop ~= drag.from and drag.drop ~= drag.from + 1 then
		local color = active:GetColor("primary")

		if drag.drop == row.Index then
			active:DrawRoundRect(0, 0, size.x, 2, 0, color, 1)
		elseif drag.drop == row.Index + 1 and row.Index == #list._rows then
			active:DrawRoundRect(0, size.y - 2, size.x, 2, 0, color, 1)
		end
	end
end

local function on_row_input(row, button, press)
	if button == "button_2" and press then
		row.List:OpenItemMenu(row.Index)
		return true
	end
end

local function on_grip_input(grip, button, press)
	if button == "button_1" and press then
		grip.List:begin_drag(grip.Index, system.GetWindow():GetMousePosition())
		return true
	end
end

local function on_duplicate(button)
	button.List.Node.Actions.Duplicate(button.Index)
end

local function on_remove(button)
	button.List.Node.Actions.Remove(button.Index)
end

function META:create_row(index, height)
	local row = Panel.New{
		Name = "property_list_row",
		List = self,
		Index = index,
		transform = true,
		visual = true,
		mouse_input = true,
		layout = {
			Direction = "x",
			GrowWidth = 1,
			FitHeight = true,
			AlignmentY = "center",
			ChildGap = 4,
			MinSize = Vec2(0, height),
			Padding = Rect(2 + self.Indent, 0, 4, 0),
		},
		OnDraw = draw_row,
		OnMouseInput = on_row_input,
	}
	local grip = Panel.New{
		Parent = row,
		Name = "property_list_grip",
		List = self,
		Index = index,
		transform = true,
		mouse_input = {Cursor = "hand"},
		layout = {
			Direction = "x",
			AlignmentX = "center",
			AlignmentY = "center",
			MinSize = Vec2(GRIP_WIDTH, height),
			MaxSize = Vec2(GRIP_WIDTH, height),
			GrowWidth = 0,
		},
		OnMouseInput = on_grip_input,
	}
	Icon{
		Parent = grip,
		Icon = "more_vertical",
		IconColor = "text_disabled",
		Size = "icon",
		IgnoreMouseInput = true,
	}
	return row
end

function META:add_action_buttons(row, index)
	IconButton{
		Parent = row,
		List = self,
		Index = index,
		Icon = "copy",
		Tooltip = "Duplicate",
		OnClick = on_duplicate,
	}
	IconButton{
		Parent = row,
		List = self,
		Index = index,
		Icon = "close",
		Tooltip = "Delete",
		OnClick = on_remove,
	}
end

function META:add_index(row, index, height)
	Text{
		Parent = row,
		Text = tostring(index),
		Color = "text_disabled",
		FontSize = self.Editor._font_size,
		IgnoreMouseInput = true,
		AlignX = 1,
		AlignY = 0.5,
		layout = {
			MinSize = Vec2(INDEX_WIDTH, height),
			MaxSize = Vec2(INDEX_WIDTH, height),
			GrowWidth = 0,
		},
	}
end

local function stretch(control, width, height)
	if width then
		control.layout:SetMinSize(Vec2(width, height))
		control.layout:SetMaxSize(Vec2(width, height))
		control.layout:SetGrowWidth(0)
	else
		control.layout:SetGrowWidth(1)
	end
end

local CHIP_MIN_TEXT_WIDTH = 36
local CHIP_GAP = 6

local function draw_chip(chip)
	local size = chip.transform:GetSize()
	local active = theme.active
	local drag = chip.List._drag
	active:DrawRoundRect(0, 0, size.x, size.y, size.y / 2, active:GetColor("surface_alt"), 1)

	if drag and drag.drop ~= drag.from and drag.drop ~= drag.from + 1 then
		local color = active:GetColor("primary")

		if drag.drop == chip.Index then
			active:DrawRoundRect(-4, 0, 2, size.y, 0, color, 1)
		elseif drag.drop == chip.Index + 1 and chip.Index == #chip.List._chips then
			active:DrawRoundRect(size.x + 2, 0, 2, size.y, 0, color, 1)
		end
	end
end

function META:create_chips(height)
	local node, editor = self.Node, self.Editor
	local line = Panel.New{
		Parent = self,
		transform = true,
		layout = {
			Direction = "x",
			GrowWidth = 1,
			FitHeight = true,
			WrapChildren = true,
			ChildGap = CHIP_GAP,
			AlignmentY = "center",
			Padding = Rect(8 + self.Indent, 3, 8, 0),
		},
	}
	self._chips = {}

	for index, item in ipairs(node.Items) do
		local chip = Panel.New{
			Parent = line,
			Name = "property_list_chip",
			List = self,
			Index = index,
			transform = true,
			visual = true,
			mouse_input = true,
			layout = {
				Direction = "x",
				AlignmentY = "center",
				ChildGap = 0,
				Padding = Rect(6, 0, 6, 0),
				FitWidth = true,
				FitHeight = true,
			},
			OnDraw = draw_chip,
			OnMouseInput = on_row_input,
		}
		item.ContextActions = {
			{
				Text = "Remove",
				Icon = "trash",
				OnClick = function()
					node.Actions.Remove(index)
				end,
			},
		}
		local control = editor:create_control(item, self.Path .. "/" .. index, item.Key)
		self:register_control(control, index)
		control.layout:SetMinSize(Vec2(CHIP_MIN_TEXT_WIDTH, height))
		control.layout:SetMaxSize(Vec2(0, height))
		control.layout:SetGrowWidth(0)
		control.layout:SetFitWidth(true)
		control._text.layout:SetGrowWidth(0)
		control._text.layout:SetFitWidth(true)
		chip:AddChild(control)
		chip.Control = control
		self._chips[index] = chip

		if node.FocusIndex == index then self.FocusControl = control end
	end

	IconButton{Parent = line, Icon = "plus", Tooltip = "Add item", OnClick = node.Actions.Add}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local node, editor = self.Node, self.Editor
	self._rows = {}
	self._drag_controls = {}
	local display = node.Display or "rows"
	local item_height = editor:get_row_height(node)

	if display == "chips" then
		self:create_chips(item_height)
		return
	end

	if #node.Items == 0 then
		Text{
			Parent = self,
			Text = "No items. Use + in the header to add one.",
			Color = "text_disabled",
			FontSize = editor._font_size,
			IgnoreMouseInput = true,
			layout = {Padding = Rect(8 + self.Indent, 4, 8, 4)},
		}
		return
	end

	if display == "table" then
		local head = Panel.New{
			Parent = self,
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				FitHeight = true,
				ChildGap = 4,
				Padding = Rect(2 + self.Indent, 2, 4, 0),
			},
		}
		Panel.New{
			Parent = head,
			transform = true,
			layout = {MinSize = Vec2(GRIP_WIDTH, 0), MaxSize = Vec2(GRIP_WIDTH, 0), GrowWidth = 0},
		}

		for _, column in ipairs(node.Columns) do
			Text{
				Parent = head,
				Text = column.Text,
				Color = "text_disabled",
				FontSize = editor._font_size,
				IgnoreMouseInput = true,
				layout = column.Width and
					{MinSize = Vec2(column.Width, 0), MaxSize = Vec2(column.Width, 0), GrowWidth = 0} or
					{GrowWidth = 1, MinSize = Vec2(10, 0), FitWidth = false},
			}
		end

		Panel.New{
			Parent = head,
			transform = true,
			layout = {
				MinSize = Vec2(ACTION_WIDTH * 2 + 4, 0),
				MaxSize = Vec2(ACTION_WIDTH * 2 + 4, 0),
				GrowWidth = 0,
			},
		}
	end

	for index, item in ipairs(node.Items) do
		if item.Children then
			self:AddChild(
				editor:build_item_group(
					self,
					item,
					index,
					self.Path .. "/" .. index,
					self.Level + 1,
					index == #node.Items
				)
			)

			goto continue
		end

		local row = self:create_row(index, item_height)
		self._rows[index] = row
		self:AddChild(row)

		if display == "table" then
			for column_index, cell in ipairs(item.Cells) do
				local control = editor:create_control(cell, self.Path .. "/" .. index .. "/" .. column_index, cell.Key)
				stretch(control, node.Columns[column_index].Width, item_height)
				row:AddChild(control)
				self:register_control(control, index)
			end
		else
			self:add_index(row, index, item_height)
			local control = editor:create_control(item, self.Path .. "/" .. index, item.Key)
			stretch(control)
			row:AddChild(control)
			self:register_control(control, index)

			if node.FocusIndex == index and control.BeginEdit then
				self.FocusControl = control
			end
		end

		self:add_action_buttons(row, index)

		::continue::
	end
end

function META:Focus()
	if self.FocusControl then self.FocusControl:BeginEdit() end
end

return META:Register()
