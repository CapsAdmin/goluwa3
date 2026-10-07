local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local VirtualGrid = import("goluwa/render2d/ui/elements/virtual_grid.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

local function create_world()
	local old_world = Panel.World
	local world = Panel.New{ComponentSet = {"transform", "visual"}}
	world:SetName("TestWorld")
	world.transform:SetSize(Vec2(512, 512))
	Panel.World = world
	return old_world, world
end

local function settle(world, grid)
	for _ = 1, 3 do
		grid.layout:UpdateLayout()
		world.visual:DrawRecursive()
	end
end

T.Test2D("virtual grid fits columns to its width and sizes the content to every row", function()
	local old_world, world = create_world()
	local items = {}

	for i = 1, 100 do
		items[i] = {id = i}
	end

	local grid = VirtualGrid{
		CellWidth = 100,
		ExtraHeight = 20,
		Gap = 10,
		ContentPadding = 10,
		Items = items,
		OnDrawItem = function() end,
	}
	grid:SetParent(world)
	grid.transform:SetSize(Vec2(450, 300))
	settle(world, grid)
	local columns = grid:GetColumns()
	T(columns)[">="](3)
	T(columns)["<="](4)
	local pitch_x, pitch_y = grid:GetPitch()
	local rows = math.ceil(#items / columns)
	T(grid:GetContentPanel().transform:GetHeight())["=="](20 + rows * pitch_y - 10)
	grid:Remove()
	Panel.World = old_world
end)

T.Test2D("virtual grid only draws the cells that are in view and scrolls a selection into view", function()
	local old_world, world = create_world()
	local items = {}
	local drawn = {}

	for i = 1, 400 do
		items[i] = {id = i}
	end

	local grid = VirtualGrid{
		CellWidth = 100,
		ExtraHeight = 20,
		Gap = 10,
		ContentPadding = 10,
		Items = items,
		OnDrawItem = function(item, index, x, y, w, h)
			drawn[index] = {x = x, y = y, w = w, h = h}
		end,
	}
	grid:SetParent(world)
	grid.transform:SetSize(Vec2(450, 300))
	settle(world, grid)
	local count = 0

	for _ in pairs(drawn) do
		count = count + 1
	end

	T(count)[">"](0)
	T(count)["<"](40)
	T(drawn[1] ~= nil)["=="](true)
	T(drawn[400] == nil)["=="](true)
	grid:SetSelectedIndex(400)
	T(grid:GetSelectedIndex())["=="](400)
	T(grid:GetViewport().transform:GetScroll().y)[">"](0)
	table.clear(drawn)
	settle(world, grid)
	T(drawn[400] ~= nil)["=="](true)
	T(drawn[1] == nil)["=="](true)
	grid:Remove()
	Panel.World = old_world
end)

T.Test2D("virtual grid reports selection changes once and resets them when the items change", function()
	local old_world, world = create_world()
	local selected = {}
	local items = {{id = "a"}, {id = "b"}, {id = "c"}}
	local grid = VirtualGrid{
		CellWidth = 100,
		ExtraHeight = 20,
		Items = items,
		OnDrawItem = function() end,
		OnSelect = function(item, index)
			selected[#selected + 1] = item and item.id or "none"
		end,
	}
	grid:SetParent(world)
	grid.transform:SetSize(Vec2(450, 300))
	settle(world, grid)
	grid:SetSelectedIndex(2)
	grid:SetSelectedIndex(2)
	grid:SelectItem(items[3])
	grid:SetSelectedIndex(nil)
	T(table.concat(selected, ","))["=="]("b,c,none")
	grid:SetItems({{id = "x"}})
	T(grid:GetSelectedIndex() == nil)["=="](true)
	T(#grid:GetItems())["=="](1)
	grid:Remove()
	Panel.World = old_world
end)
