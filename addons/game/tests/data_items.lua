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
	local data = {Count = 5, Tint = {1, 0, 0, 1}}
	local schema = {
		Refs = {},
		Fields = {},
		Root = {
			Defaults = {Count = 1, Size = 0.5, Tint = {1, 1, 1, 1}, Name = "a"},
			Groups = {
				{Name = "Look", Keys = {"Size", "Tint"}},
				{Name = "Misc", Keys = {"Count", "Name"}},
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
	T(count.RowButtons[1].Tooltip)["=="]("reset to the default")
	T(name.Value)["=="]("a")
	size.OnChange(nil, 2)
	T(data.Size)["=="](2)
	count.RowButtons[1].OnClick()
	T(data.Count)["=="](nil)
	T(restructures)["=="](1)
	data.Size = 0.5
	data.Name = "b"
	data.Tint = {1, 1, 1, 1}
	data_items.StripDefaults(data, schema)
	T(data.Size)["=="](nil)
	T(data.Tint)["=="](nil)
	T(data.Name)["=="]("b")
end)
