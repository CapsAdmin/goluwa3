local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
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

function META:begin_drag(index)
	self._drag = {from = index, drop = index}
end

function META:get_drop_index(pos)
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

	local to = drag.drop > drag.from and drag.drop - 1 or drag.drop

	if to ~= drag.from then self.Node.Actions.Move(drag.from, to) end
end

function META:OnGlobalMouseMove(pos)
	if self._drag then
		self._drag.drop = self:get_drop_index(pos)
		return true
	end
end

function META:OnGlobalMouseInput(button, press)
	if self._drag and not press and button == "button_1" then self:end_drag() end
end

local function draw_row(row)
	local list = row.List
	local drag = list._drag
	local size = row.transform:GetSize()
	local active = theme.active

	if drag and drag.from == row.Index then
		active:DrawRoundRect(0, 0, size.x, size.y, 0, active:GetColor("primary"), 0.15)
	end

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
		grip.List:begin_drag(grip.Index)
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
	local item = self.Node.Items[index]

	if item.PlayAction then
		IconButton{Parent = row, Icon = "play", Tooltip = "Play", OnClick = item.PlayAction}
	end

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

local CHIP_CHARACTER_WIDTH = 7
local CHIP_EXTRA_WIDTH = 34
local CHIP_GAP = 6

local function draw_chip(chip)
	local size = chip.transform:GetSize()
	local active = theme.active
	active:DrawRoundRect(0, 0, size.x, size.y, size.y / 2, active:GetColor("surface_alt"), 1)
end

function META:create_chips(height)
	local node, editor = self.Node, self.Editor
	local width = editor.transform:GetWidth()
	local available = width > 100 and width - 28 or 400
	local line, used

	local function new_line()
		line = Panel.New{
			Parent = self,
			transform = true,
			layout = {
				Direction = "x",
				GrowWidth = 1,
				FitHeight = true,
				ChildGap = CHIP_GAP,
				Padding = Rect(8 + self.Indent, 3, 8, 0),
			},
		}
		used = 0
	end

	new_line()

	for index, item in ipairs(node.Items) do
		local text_width = math.max(36, #tostring(item.Value) * CHIP_CHARACTER_WIDTH + 12)
		local chip_width = text_width + CHIP_EXTRA_WIDTH

		if used > 0 and used + chip_width > available then new_line() end

		used = used + chip_width + CHIP_GAP
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
				Padding = Rect(6, 0, 2, 0),
				FitWidth = true,
				FitHeight = true,
			},
			OnDraw = draw_chip,
			OnMouseInput = on_row_input,
		}
		local control = editor:create_control(item, self.Path .. "/" .. index, item.Key)
		stretch(control, text_width, height)
		chip:AddChild(control)
		IconButton{
			Parent = chip,
			List = self,
			Index = index,
			Icon = "close",
			Tooltip = "Delete",
			OnClick = on_remove,
		}

		if node.FocusIndex == index and control.BeginEdit then
			self.FocusControl = control
		end
	end
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local node, editor = self.Node, self.Editor
	self._rows = {}
	local display = node.Display or "rows"
	local item_height = editor:get_row_height(node)

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

	if display == "chips" then
		self:create_chips(item_height)
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
			end
		else
			self:add_index(row, index, item_height)
			local control = editor:create_control(item, self.Path .. "/" .. index, item.Key)
			stretch(control)
			row:AddChild(control)

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
