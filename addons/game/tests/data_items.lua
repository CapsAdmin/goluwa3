local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local data_items = import("lua/data_items.lua")

T.Test("data items edit a plain table in place and skip functions", function()
	local data = {
		Color = {1, 0.5, 0.2, 1},
		Think = function() end,
		Offset = {0, 1, 2},
		Particles = {Drag = 2},
		List = {"a", "b"},
		On = true,
		Mode = "c",
		Layers = {{Name = "a"}, {Name = "b"}},
	}
	local changes = 0
	local restructured = 0
	local items = data_items.Build(
		data,
		{
			Changed = function()
				changes = changes + 1
			end,
			Restructured = function()
				restructured = restructured + 1
			end,
			Schema = {
				Refs = {kind = {"a", "b"}},
				Fields = {
					Mode = {Ref = "kind"},
					["Layers[]"] = {},
					Layers = {Template = {Name = "new"}},
				},
			},
		}
	)
	T(items[1].Text)["=="]("general")
	local by_text = {}

	for _, item in ipairs(items[1].Children) do
		by_text[item.Text] = item
	end

	T(by_text.Think)["=="](nil)
	T(by_text.Color.Type)["=="]("color")
	T(by_text.Offset.Type)["=="]("vec3")
	T(by_text.On.Type)["=="]("boolean")
	by_text.Offset.OnChange(nil, Vec3(3, 4, 5))
	T(data.Offset[2])["=="](4)
	by_text.Color.OnChange(nil, Color(0, 1, 0, 1))
	T(data.Color[2])["=="](1)
	T(changes)["=="](2)
	T(by_text.Mode.Type)["=="]("enum")
	T(by_text.Mode.Options[1].Text)["=="]("c (missing)")
	local layers

	for _, item in ipairs(items) do
		if item.Text == "Layers" then layers = item end
	end

	local function find_action(group, text)
		for _, child in ipairs(group.Children) do
			if child.ButtonText == text then return child end
		end
	end

	find_action(layers.Children[1], "move down").OnAction()
	T(data.Layers[1].Name)["=="]("b")
	find_action(layers.Children[1], "duplicate").OnAction()
	T(#data.Layers)["=="](3)
	find_action(layers, "add item").OnAction()
	T(data.Layers[4].Name)["=="]("new")
	find_action(layers.Children[1], "remove").OnAction()
	T(#data.Layers)["=="](3)
	T(restructured)["=="](4)
end)
