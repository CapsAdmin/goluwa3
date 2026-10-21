local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local StatTable = import("goluwa/render2d/ui/widgets/stat_table.lua")

local function create_world()
	local old_world = Panel.World
	local world = Panel.New{ComponentSet = {"transform", "visual"}}
	world.transform:SetSize(Vec2(512, 512))
	Panel.World = world
	return old_world, world
end

local function rows_of(count)
	local rows = {}

	for index = 1, count do
		rows[index] = {label = "row " .. index, value = tostring(index)}
	end

	return rows
end

T.Test2D("stat table draws the rows it is given and keeps the first row inside them", function()
	local old_world, world = create_world()
	local table_ = StatTable{Size = Vec2(300, 200), Rows = rows_of(3)}
	table_:SetParent(world)
	table_.FirstRow = 40
	world.visual:DrawRecursive()
	T(table_.FirstRow)["=="](0)
	local many = rows_of(100)
	table_:SetRows(many)
	table_.FirstRow = 5
	world.visual:DrawRecursive()
	T(table_.FirstRow)["=="](5)
	table_.FirstRow = 500
	world.visual:DrawRecursive()
	T(table_.FirstRow)["<"](100)
	T(table_.FirstRow)[">"](0)
	T(table_.Rows)["=="](many)
	table_:Remove()
	Panel.World = old_world
end)
