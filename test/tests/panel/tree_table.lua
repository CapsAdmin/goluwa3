local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local TreeTable = import("goluwa/render2d/ui/widgets/tree_table.lua")

local function make_items()
	return {
		{
			Key = "b",
			Text = "b",
			IsFolder = true,
			Size = 2,
			Children = {
				{Key = "b/x10", Text = "x10", Size = 5},
				{Key = "b/x2", Text = "x2", Size = 50},
			},
		},
		{Key = "z", Text = "z", Size = 30},
		{Key = "a", Text = "a", Size = 10},
		{Key = "c", Text = "c", IsFolder = true, Size = 0, Children = {}},
	}
end

local COLUMNS = {
	{Key = "Text", Text = "Name", Grow = true},
	{Key = "Size", Text = "Size", Width = 80},
}

local function names(table_widget)
	local out = {}

	for i, row in ipairs(table_widget:GetRows()) do
		out[i] = row.node.Text
	end

	return table.concat(out, ",")
end

T.Test2D("tree table expands folders inline, sorts naturally with folders first and keeps selection", function()
	local selected, toggled, activated, sorted
	local widget = TreeTable{
		Parent = Panel.World,
		Items = make_items(),
		Columns = COLUMNS,
		transform = {Size = Vec2(400, 300)},
		OnSelect = function(node)
			selected = node and node.Text
		end,
		OnToggle = function(node, expanded)
			toggled = node.Text .. tostring(expanded)
		end,
		OnActivate = function(node)
			activated = node.Text
		end,
		OnSort = function(column, descending)
			sorted = column.Key .. tostring(descending)
		end,
	}
	T(names(widget))["=="]("b,c,z,a")
	widget:SetSort("Text", false)
	T(names(widget))["=="]("b,c,a,z")
	T(sorted)["=="]("Textfalse")
	widget:Expand(widget:GetRows()[1].node)
	T(toggled)["=="]("btrue")
	T(names(widget))["=="]("b,x2,x10,c,a,z")
	T(widget:GetRows()[2].depth)["=="](1)
	widget:SetSort("Size", true)
	T(names(widget))["=="]("b,x2,x10,c,z,a")
	widget:SetSelectedIndex(3)
	T(selected)["=="]("x10")
	widget:Collapse(widget:GetRows()[1].node)
	T(names(widget))["=="]("b,c,z,a")
	T(widget:GetSelectedNode())["=="](nil)
	widget:SetMode("list")
	T(names(widget))["=="]("b,c,z,a")
	widget:Expand(widget:GetRows()[1].node)
	T(names(widget))["=="]("b,c,z,a")
	widget:SetSelectedIndex(3)
	local content = widget:GetContentPanel()
	content:CallLocalEvent("OnKeyInput", "up", true)
	T(selected)["=="]("c")
	content:CallLocalEvent("OnKeyInput", "enter", true)
	T(activated)["=="]("c")
	widget:Remove()
end)

T.Test2D("tree table sorts from header clicks, toggles from the chevron and activates on double click", function()
	local activated
	local widget = TreeTable{
		Parent = Panel.World,
		Items = make_items(),
		Columns = COLUMNS,
		transform = {Size = Vec2(400, 300)},
		OnActivate = function(node)
			activated = node.Text
		end,
	}
	widget:update_columns(300)
	local header = widget._header
	header:CallLocalEvent("OnMouseInput", "button_1", true, Vec2(widget._positions[2] + 10, 5))
	T(widget.SortKey)["=="]("Size")
	T(widget.SortDescending)["=="](false)
	T(names(widget))["=="]("c,b,a,z")
	header:CallLocalEvent("OnMouseInput", "button_1", true, Vec2(widget._positions[2] + 10, 5))
	T(widget.SortDescending)["=="](true)
	T(names(widget))["=="]("b,c,z,a")
	local content = widget:GetContentPanel()
	local row_height = widget:GetRows() and
		widget:GetRows()[1] and
		content.layout.MinSize.y / #widget:GetRows()
	content:CallLocalEvent(
		"OnMouseInput",
		"button_1",
		true,
		Vec2(widget:get_toggle_x(0) + 2, row_height / 2)
	)
	T(widget:IsExpanded(widget:GetRows()[1].node))["=="](true)
	T(names(widget))["=="]("b,x2,x10,c,z,a")
	content:CallLocalEvent("OnMouseInput", "button_1", true, Vec2(200, row_height * 2.5))
	content:CallLocalEvent("OnMouseInput", "button_1", true, Vec2(200, row_height * 2.5))
	T(activated)["=="]("x10")
	widget:Remove()
end)

T.Test2D("tree table border drags move the border with the cursor and leave the grow column the remainder", function()
	local columns = {
		{Key = "Text", Text = "Name", Grow = true, MinWidth = 100},
		{Key = "Size", Text = "Size", Width = 80},
		{Key = "Type", Text = "Type", Width = 60},
	}
	local widget = TreeTable{
		Parent = Panel.World,
		Items = make_items(),
		Columns = columns,
		transform = {Size = Vec2(400, 300)},
	}

	local function begin(index)
		widget:update_columns(400)
		return {
			index = index,
			grow_index = widget._grow_index,
			widths = {table.unpack(widget._widths)},
		}
	end

	widget:resize_column(begin(2), -30)
	widget:update_columns(400)
	T(widget._widths[3])["=="](90)
	T(widget._widths[2])["=="](80)
	T(widget._positions[3])["=="](310 - 0)
	T(widget._widths[1])["=="](230)
	widget:resize_column(begin(2), 1000)
	widget:update_columns(400)
	T(widget._widths[3])["=="](40)
	widget:resize_column(begin(2), -1000)
	widget:update_columns(400)
	T(widget._widths[1])["=="](100)
	T(columns[3].Width)["=="](60)
	widget:Remove()
end)
