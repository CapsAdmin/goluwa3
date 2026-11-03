local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
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
		Words = {"b", "a"},
		Pairs = {{1, 2}, {3, 4}},
		Cue = "ambient/fire/ignite.wav",
		Cues = {"a.wav", "b.wav"},
		Hook = "return 1.0;",
		Box = {1, 2, 3, 4},
		Particles = {Shader = "a", ShaderParams = {X = 1}},
	}
	local played = {}
	local changes = 0
	local restructured = 0
	local focus
	local items = data_items.Build(
		data,
		{
			Changed = function()
				changes = changes + 1
			end,
			Restructured = function(_, new_focus)
				restructured = restructured + 1
				focus = new_focus or focus
			end,
			PlaySound = function(path)
				played[#played + 1] = path
			end,
			Name = "x",
			Schema = {
				Refs = {kind = {"a", "b"}},
				Fields = {
					Hook = {
						Code = "glsl",
						GetStatus = function(_, options)
							return "status " .. options.Name
						end,
					},
					["Particles.Shader"] = {
						Options = {"a", "b"},
						Restructure = true,
						OnSet = function(particles, name)
							particles.ShaderParams = {Y = 2}
						end,
					},
					Cue = {Sound = true},
					["Cues[]"] = {Sound = true},
					Mode = {Ref = "kind"},
					Layers = {Template = {Name = "new"}},
					Pairs = {Display = "table", Columns = {{Text = "a", Key = 1}, {Text = "b", Key = 2}}},
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
	T(by_text.Mode.RowButtons)["=="](nil)
	T(by_text.Hook.Type)["=="]("code")
	T(by_text.Hook.CodeLanguage)["=="]("glsl")
	T(by_text.Hook.GetStatus())["=="]("status x")
	T(by_text.Box.Type)["=="]("vec4")
	by_text.Box.OnChange(nil, Vec4(4, 3, 2, 1))
	T(data.Box[1])["=="](4)
	T(data.Box[4])["=="](1)
	local shader

	for _, group in ipairs(items) do
		for _, child in ipairs(group.Text == "Particles" and group.Children or {}) do
			if child.Text == "Shader" then shader = child end
		end
	end

	local restructures_before = restructured
	shader.OnChange(nil, "b")
	T(data.Particles.Shader)["=="]("b")
	T(data.Particles.ShaderParams.Y)["=="](2)
	T(restructured)["=="](restructures_before + 1)
	T(by_text.Cue.Type)["=="]("sound")
	by_text.Cue.PlayAction("x.wav")
	T(played[1])["=="]("x.wav")
	T(by_text.Words.Items[1].Type)["=="]("string")
	T(by_text.Cues.Items[2].Type)["=="]("sound")
	T(by_text.Cues.Items[2].PlayAction)["=="](by_text.Cue.PlayAction)
	local opened
	local openable = data_items.Build(
		{Mode = "a"},
		{
			Open = function(ref, name)
				opened = ref .. ":" .. name
			end,
			CanOpen = function()
				return true
			end,
			Schema = {Refs = {kind = {"a", "b"}}, Fields = {Mode = {Ref = "kind"}}},
		}
	)
	T(#openable[1].Children)["=="](1)
	openable[1].Children[1].RowButtons[1].OnClick()
	T(opened)["=="]("kind:a")

	local function find(list, text)
		for _, item in ipairs(list) do
			if item.Text == text then return item end
		end
	end

	local layers = find(items[1].Children, "Layers")
	T(layers.Type)["=="]("list")
	T(#layers.Items)["=="](2)
	T(layers.Items[1].Text)["=="]("item")
	layers.Actions.Move(1, 2)
	T(data.Layers[1].Name)["=="]("b")
	layers.Actions.Duplicate(1)
	T(#data.Layers)["=="](3)
	layers.Actions.Add()
	T(data.Layers[4].Name)["=="]("new")
	layers.Actions.Remove(1)
	T(#data.Layers)["=="](3)
	layers.Actions.Insert(1)
	T(data.Layers[1].Name)["=="]("new")
	T(focus.Path)["=="]("/Layers")
	T(focus.Index)["=="](1)
	layers.Actions.Clear()
	T(#data.Layers)["=="](0)
	local words = find(items[1].Children, "Words")
	words.Actions.Paste("one\ntwo\n\nthree")
	T(#data.Words)["=="](5)
	words.Actions.Sort()
	T(data.Words[1])["=="]("a")
	T(words.Actions.Copy():find("\"one\"", 1, true) ~= nil)["=="](true)
	words.Items[1].OnChange(nil, "z")
	T(data.Words[1])["=="]("z")
	local table_list = find(items[1].Children, "Pairs")
	T(table_list.Display)["=="]("table")
	table_list.Items[2].Cells[2].OnChange(nil, 9)
	T(data.Pairs[2][2])["=="](9)
	T(restructured)["=="](9)
end)

T.Test("data items show defaults for missing keys, group them and strip values that equal their default", function()
	local data = {Count = 5, Tint = {1, 0, 0, 1}, Spread = {1, 2}}
	local schema = {
		Refs = {},
		Fields = {Spread = {Range = true}, Count = {Integer = true}},
		Root = {
			Defaults = {Count = 1, Size = 0.5, Tint = {1, 1, 1, 1}, Name = "a", Spread = 0},
			Groups = {
				{Name = "Look", Keys = {"Size", "Tint"}},
				{Name = "Misc", Keys = {"Count", "Name", "Spread"}},
			},
		},
	}
	local changes, restructures = 0, 0
	local options = {
		Schema = schema,
		Name = "x",
		Changed = function()
			changes = changes + 1
		end,
		Restructured = function()
			restructures = restructures + 1
		end,
	}
	local items = data_items.Build(data, options)
	local plain = data_items.Build(
		{Count = 5, Nested = {Value = 1, Flag = true, Tint = {1, 0, 0, 1}}},
		{
			Schema = {Refs = {}, Fields = {}, Root = {}},
			Name = "x",
			Changed = function() end,
			Restructured = function() end,
		}
	)

	local function no_defaults(nodes)
		for _, node in ipairs(nodes) do
			T(node.Default)["=="](nil)

			if node.Children then no_defaults(node.Children) end
		end
	end

	no_defaults(plain)
	T(#items)["=="](2)
	T(items[1].Text)["=="]("Look")
	T(items[2].Text)["=="]("Misc")
	local size, tint = items[1].Children[1], items[1].Children[2]
	T(size.Text)["=="]("Size")
	T(size.Value)["=="](0.5)
	T(size.Default)["=="](0.5)
	T(size.RowButtons)["=="](nil)
	T(data.Size)["=="](nil)
	T(tint.Type)["=="]("vec4") -- no Color in the key name, so a plain vec4
	local count, name = items[2].Children[1], items[2].Children[2]
	T(count.Value)["=="](5)
	T(count.Default)["=="](1)
	T(count.RowButtons)["=="](nil)
	T(count.ShowStepper)["=="](nil)
	T(count.Type)["=="]("integer")
	T(count.Precision)["=="](0)
	T(size.Type)["=="]("number")
	T(name.Value)["=="]("a")
	size.OnChange(nil, 2)
	T(data.Size)["=="](2)
	local spread = items[2].Children[3]
	T(spread.Type)["=="]("vec2")
	T(spread.Default)["=="](nil)
	T(spread.ContextActions[1].Text)["=="]("Random")
	T(spread.ContextActions[1].Checked)["=="](true)
	T(spread.ContextActions[2].Text)["=="]("Reset to the default")
	spread.ContextActions[2].OnClick()
	T(data.Spread)["=="](nil)
	T(restructures)["=="](1)
	data.Size = 0.5
	data.Name = "b"
	data.Tint = {1, 1, 1, 1}
	data_items.StripDefaults(data, schema)
	T(data.Size)["=="](nil)
	T(data.Tint)["=="](nil)
	T(data.Name)["=="]("b")
end)

T.Test("data items add optional keys through one add node and remove them from their context menu", function()
	local data = {Loop = true, Preview = {Stage = "gizmo"}, Inputs = {Strength = {Default = 1}}}
	local restructures = 0
	local schema = {
		Refs = {},
		Fields = {
			Preview = {Keys = {Stage = "gizmo", Npc = "citizen", Loop = true}},
			Inputs = {NewKey = {Name = "Input", Template = {Default = 1}}},
		},
		Root = {Keys = {Loop = true, Preview = {}, Inputs = {}, Debris = {}}},
	}
	local options = {
		Schema = schema,
		Name = "x",
		Changed = function() end,
		Restructured = function()
			restructures = restructures + 1
		end,
	}
	local items = data_items.Build(data, options)
	local general = items[1]
	T(general.Text)["=="]("general")
	local loop
	local preview
	local inputs
	local add

	for _, child in ipairs(general.Children) do
		if child.Text == "Loop" then loop = child end

		if child.Type == "add" then add = child end
	end

	for _, item in ipairs(items) do
		if item.Text == "Preview" then preview = item end

		if item.Text == "Inputs" then inputs = item end
	end

	T(loop.ContextActions[1].Text)["=="]("Remove")
	T(add ~= nil)["=="](true)
	T(#add.Items)["=="](1)
	T(add.Items[1].Text)["=="]("Debris")
	add.Items[1].OnClick()
	T(type(data.Debris))["=="]("table")
	T(restructures)["=="](1)
	local preview_add

	for _, child in ipairs(preview.Children) do
		if child.Type == "add" then preview_add = child end
	end

	T(#preview_add.Items)["=="](2)
	T(preview_add.Items[1].Text)["=="]("Loop")
	T(preview_add.Items[2].Text)["=="]("Npc")
	preview_add.Items[2].OnClick()
	T(data.Preview.Npc)["=="]("citizen")
	local stage

	for _, child in ipairs(preview.Children) do
		if child.Text == "Stage" then stage = child end
	end

	T(stage.ContextActions[1].Text)["=="]("Remove")
	stage.ContextActions[1].OnClick()
	T(data.Preview.Stage)["=="](nil)
	loop.ContextActions[1].OnClick()
	T(data.Loop)["=="](nil)
	T(preview.ContextActions[1].Text)["=="]("Remove")
	local inputs_add

	for _, child in ipairs(inputs.Children) do
		if child.Type == "add" then inputs_add = child end

		if child.Text == "Strength" then
			T(child.ContextActions[1].Text)["=="]("Remove")
		end
	end

	T(inputs_add.Items[1].Text)["=="]("new Input")
	inputs_add.Items[1].OnClick()
	T(data.Inputs.Input_1.Default)["=="](1)
	local grouped = data_items.Build(
		{},
		{
			Schema = {
				Refs = {},
				Fields = {},
				Root = {
					Keys = {Inputs = {}},
					Defaults = {Count = 1},
					Groups = {{Name = "Misc", Keys = {"Count"}}},
				},
			},
			Name = "x",
			Changed = function() end,
			Restructured = function() end,
		}
	)
	T(grouped[#grouped].Text)["=="]("optional")
	T(grouped[#grouped].Children[1].Type)["=="]("add")
end)

T.Test("data items turn a number or color into a random range or a curve over life from its context menu", function()
	local data = {Size = 0.5, TintColor = {1, 0, 0, 1}, Life = 2}
	local restructures = 0
	local schema = {
		Refs = {},
		Fields = {
			Size = {Band = "scalar", Min = 0, Max = 2},
			TintColor = {Band = "color"},
			Life = {Range = true},
		},
		Root = {
			Defaults = {
				Size = 0.1,
				TintColor = {1, 1, 1, 1},
				Life = 1,
				FadeColor = {Keys = {{0, {1, 1, 1, 1}}, {1, {1, 1, 1, 0}}}},
			},
		},
	}
	local options = {
		Schema = schema,
		Name = "x",
		Changed = function() end,
		Restructured = function()
			restructures = restructures + 1
		end,
	}
	schema.Fields.FadeColor = {Band = "color"}

	local function rebuild()
		local by_text = {}

		for _, item in ipairs(data_items.Build(data, options)[1].Children) do
			by_text[item.Text] = item
		end

		return by_text
	end

	local function action(item, text)
		for _, entry in ipairs(item.ContextActions) do
			if entry.Text == text then return entry end
		end
	end

	local rows = rebuild()
	T(rows.Size.Type)["=="]("number")
	T(rows.TintColor.Type)["=="]("color")
	T(rows.FadeColor.Type)["=="]("curve")
	T(rows.FadeColor.Kind)["=="]("color")
	T(rows.FadeColor.Default)["=="](rows.FadeColor.Value)
	T(action(rows.Size, "Random").Checked)["=="](false)
	T(action(rows.Size, "Curve over life").Checked)["=="](false)
	T(action(rows.Life, "Curve over life"))["=="](nil)
	action(rows.Size, "Random").OnClick()
	T(data.Size[1])["=="](0.5)
	T(data.Size[2])["=="](0.5)
	rows = rebuild()
	T(rows["Size (min, max)"].Type)["=="]("vec2")
	T(rows.Size)["=="](nil)
	data.Size = {0.2, 0.6}
	rows = rebuild()
	action(rows["Size (min, max)"], "Curve over life").OnClick()
	T(data.Size.Keys[1][2])["=="](0.2)
	T(data.Size.Keys[2][2])["=="](0.2)
	T(data.Size.MaxKeys[2][2])["=="](0.6)
	rows = rebuild()
	T(rows.Size.Type)["=="]("curve")
	T(rows.Size.Kind)["=="]("scalar")
	T(rows.Size.Max)["=="](2)
	T(action(rows.Size, "Random").Checked)["=="](true)
	T(action(rows.Size, "Curve over life").Checked)["=="](true)
	rows.Size.OnChange(nil, {Keys = {{0, 1}, {1, 0}}})
	T(data.Size.Keys[1][2])["=="](1)
	rows = rebuild()
	action(rows.Size, "Random").OnClick()
	T(data.Size.MaxKeys[1][2])["=="](1)
	rows = rebuild()
	action(rows.Size, "Random").OnClick()
	T(data.Size.MaxKeys)["=="](nil)
	rows = rebuild()
	action(rows.Size, "Curve over life").OnClick()
	T(data.Size)["=="](1)
	action(rebuild().TintColor, "Random").OnClick()
	T(data.TintColor[1][1])["=="](1)
	T(data.TintColor[2][3])["=="](0)
	rows = rebuild()
	T(rows.TintColor.Type)["=="]("color_range")
	rows.TintColor.OnChange(nil, {{0, 1, 0, 1}, {0, 0, 1, 1}})
	T(data.TintColor[2][3])["=="](1)
	action(rebuild().TintColor, "Random").OnClick()
	T(data.TintColor[1])["=="](0)
	data.TintColor = {1, 0, 0, 1}
	action(rebuild().TintColor, "Curve over life").OnClick()
	T(data.TintColor.Keys[2][2][1])["=="](1)
	action(rebuild().TintColor, "Reset to the default").OnClick()
	T(data.TintColor)["=="](nil)
	local fade = action(rebuild().FadeColor, "Reset to the default")
	T(fade)["=="](nil)
	data_items.StripDefaults(data, {Root = schema.Root})
	T(data.FadeColor)["=="](nil)
end)
