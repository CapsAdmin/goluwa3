local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local objects = import("goluwa/objects/objects.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local DemoObject = objects.CreateTemplate("gallery_demo_object")
DemoObject:StartStorable()
DemoObject:GetSet("ABoolean", true)
DemoObject:GetSet("AnEnum", "option_b", {enums = {"option_a", "option_b", "option_c"}})
DemoObject:GetSet("AString", "hello world")
DemoObject:GetSet("ANumber", 3.14159)
DemoObject:GetSet("AnInteger", 42, {validate = "integer"})
DemoObject:GetSet("AVec2", Vec2(1, 2), {type = "vec2"})
DemoObject:GetSet("AVec3", Vec3(1, 2, 3), {type = "vec3"})
DemoObject:GetSet("AAng3", Ang3(0, 90, 0), {type = "ang3"})
DemoObject:GetSet("ARect", Rect(0, 0, 100, 200), {type = "rect"})
DemoObject:GetSet("AQuat", Quat(0, 0, 0, 1), {type = "quat"})
DemoObject:GetSet("AColor", Color(1, 0.5, 0.2, 1), {type = "color"})
DemoObject:EndStorable()
DemoObject:Register()

local function new_values()
	return {
		name = "Beacon Drone",
		visible = true,
		material = "glass",
		opacity = 0.72,
		color = Color(0.2, 0.7, 1, 1),
		spin = 38,
		count = 4,
		offset = Vec3(0, 6, 2),
		rotation = Ang3(0, 0, 0),
		notes = "Ambient helper prop used to test grouped property editing.",
	}
end

local function build_items(values, changed, reset)
	local function on_change(key)
		return |_,value|->changed(key, value)
	end

	return {
		{
			Key = "appearance",
			Text = "Appearance",
			Expanded = true,
			Description = "Surface and presentation controls.",
			Children = {
				{
					Key = "appearance/name",
					Text = "Display name",
					Type = "string",
					Value = values.name,
					Default = "Beacon Drone",
					Description = "Shown in the inspector.",
					OnChange = on_change("name"),
				},
				{
					Key = "appearance/visible",
					Text = "Visible",
					Type = "boolean",
					Value = values.visible,
					Default = true,
					OnChange = on_change("visible"),
				},
				{
					Key = "appearance/material",
					Text = "Material",
					Type = "enum",
					Value = values.material,
					Default = "glass",
					Options = {
						{Text = "Glass", Value = "glass"},
						{Text = "Scanlines", Value = "scanlines"},
						{Text = "Hologram", Value = "hologram"},
						{Text = "Chrome", Value = "chrome"},
					},
					OnChange = on_change("material"),
				},
				{
					Key = "appearance/opacity",
					Text = "Opacity",
					Type = "number",
					Value = values.opacity,
					Default = 0.72,
					Min = 0,
					Max = 1,
					Precision = 2,
					ShowSlider = true,
					OnChange = on_change("opacity"),
				},
				{
					Key = "appearance/color",
					Text = "Tint",
					Type = "color",
					Value = values.color,
					Default = Color(0.2, 0.7, 1, 1),
					OnChange = on_change("color"),
				},
			},
		},
		{
			Key = "motion",
			Text = "Motion",
			Expanded = true,
			Description = "Numbers with ranges, steppers and drag editing.",
			Children = {
				{
					Key = "motion/spin",
					Text = "Spin speed",
					Type = "number",
					Value = values.spin,
					Default = 38,
					Min = 0,
					Max = 360,
					Precision = 1,
					ShowStepper = true,
					OnChange = on_change("spin"),
				},
				{
					Key = "motion/count",
					Text = "Count",
					Type = "integer",
					Value = values.count,
					Default = 4,
					Min = 1,
					Max = 16,
					Precision = 0,
					ShowStepper = true,
					OnChange = on_change("count"),
				},
				{
					Key = "motion/offset",
					Text = "Offset",
					Type = "vec3",
					Value = values.offset,
					Default = Vec3(0, 6, 2),
					Precision = 1,
					OnChange = on_change("offset"),
				},
				{
					Key = "motion/rotation",
					Text = "Rotation",
					Type = "ang3",
					Value = values.rotation,
					Default = Ang3(0, 0, 0),
					Precision = 1,
					OnChange = on_change("rotation"),
				},
			},
		},
		{
			Key = "notes",
			Text = "Notes",
			Expanded = false,
			Description = "Long text and actions.",
			Children = {
				{
					Key = "notes/text",
					Text = "Notes",
					Type = "string",
					Multiline = true,
					Value = values.notes,
					OnChange = on_change("notes"),
				},
				{
					Key = "notes/reset",
					Text = "Reset",
					Type = "action",
					ButtonText = "Reset to defaults",
					OnAction = reset,
				},
			},
		},
	}
end

local function snapshot(values)
	return string.format(
		"name = %s\nvisible = %s\nmaterial = %s\nopacity = %.2f\ncolor = %s\nspin = %.1f\ncount = %d\noffset = %s\nrotation = %s\nnotes = %q",
		values.name,
		tostring(values.visible),
		values.material,
		values.opacity,
		tostring(values.color),
		values.spin,
		values.count,
		tostring(values.offset),
		tostring(values.rotation),
		values.notes
	)
end

local function new_lists()
	return {
		sounds = {"ambient/fire/mtov_flame2.wav", "ambient/fire/ignite.wav", "physics/glass/glass_impact_bullet1.wav"},
		words = {"misery", "sin", "suffering", "darkness", "hades", "corruption"},
		wobble = {{3.1, 1.4}, {7.3, 0.5}},
		layers = {{name = "ring", alpha = 1}, {name = "flare", alpha = 0.8}, {name = "glow", alpha = 0.4}},
	}
end

local function build_list_items(lists, update)
	local function actions(name, template)
		local function change(fn)
			local list = table.copy(lists[name])
			fn(list)
			update(name, list)
		end

		return {
			Add = function()
				change(function(list)
					list[#list + 1] = template(list[#list])
				end)
			end,
			Insert = function(index)
				change(function(list)
					table.insert(list, index, template(list[index] or list[#list]))
				end)
			end,
			Duplicate = function(index)
				change(function(list)
					table.insert(list, index + 1, table.copy(list[index]))
				end)
			end,
			Remove = function(index)
				change(function(list)
					table.remove(list, index)
				end)
			end,
			Move = function(from, to)
				change(function(list)
					table.insert(list, to, table.remove(list, from))
				end)
			end,
			Clear = function()
				update(name, {})
			end,
			Sort = function()
				change(function(list)
					table.sort(list)
				end)
			end,
		}
	end

	local function scalar_items(name, extra)
		local items = {}

		for i, value in ipairs(lists[name]) do
			items[i] = table.merge(
				{
					Key = "lists/" .. name .. "/" .. i,
					Type = "string",
					Value = value,
					OnChange = function(_, new)
						lists[name][i] = new
					end,
				},
				extra or {}
			)
		end

		return items
	end

	local wobble_items = {}

	for i, pair in ipairs(lists.wobble) do
		wobble_items[i] = {
			Key = "lists/wobble/" .. i,
			Cells = {
				{Key = "lists/wobble/" .. i .. "/1", Type = "number", Value = pair[1], ShowStepper = true, OnChange = function(_, new)
					pair[1] = new
				end},
				{Key = "lists/wobble/" .. i .. "/2", Type = "number", Value = pair[2], ShowStepper = true, OnChange = function(_, new)
					pair[2] = new
				end},
			},
		}
	end

	local layer_items = {}

	for i, layer in ipairs(lists.layers) do
		layer_items[i] = {
			Key = "lists/layers/" .. i .. "/" .. layer.name,
			Text = layer.name,
			Children = {
				{Key = "lists/layers/" .. i .. "/name", Text = "name", Type = "string", Value = layer.name, OnChange = function(_, new)
					layer.name = new
				end},
				{Key = "lists/layers/" .. i .. "/alpha", Text = "alpha", Type = "number", Value = layer.alpha, Min = 0, Max = 1, ShowSlider = true, OnChange = function(_, new)
					layer.alpha = new
				end},
			},
		}
	end

	return {
		{
			Key = "lists",
			Text = "Lists",
			Expanded = true,
			Children = {
				{
					Key = "lists/sounds",
					Text = "HitSounds",
					Type = "list",
					Items = scalar_items("sounds", {PlayAction = function() end}),
					Actions = actions("sounds", function(last)
						return last or ""
					end),
				},
				{
					Key = "lists/words",
					Text = "Names",
					Type = "list",
					Display = "chips",
					Items = scalar_items("words"),
					Actions = actions("words", function()
						return "word"
					end),
				},
				{
					Key = "lists/wobble",
					Text = "Wobble",
					Type = "list",
					Display = "table",
					Columns = {{Text = "frequency"}, {Text = "amplitude"}},
					Items = wobble_items,
					Actions = actions("wobble", function(last)
						return last and {last[1] * 2, last[2] / 2} or {3, 1}
					end),
				},
				{
					Key = "lists/layers",
					Text = "Layers",
					Type = "list",
					Items = layer_items,
					Actions = actions("layers", function(last)
						return {name = "layer", alpha = last and last.alpha or 1}
					end),
				},
			},
		},
	}
end

return {
	Name = "property editor",
	Section = "Data",
	Order = 3,
	View = react.Component(
		||-> do
			local values, set_values = react.UseState(new_values)
			local resets, set_resets = react.UseState(0)
			local lists, set_lists = react.UseState(new_lists)
			local list_version, set_list_version = react.UseState(0)
			local inspector = react.UseRef()
			local demo = react.UseResource(||->DemoObject.New(), |object|->object:Remove(), {})
			local items = react.UseMemo(
				||->build_items(
					values,
					|key,value|->set_values(|current|->table.merge(table.shallow_copy(current), {[key] = value})),
					||-> do
						set_values(new_values())
						set_resets(|count|->count + 1)
					end
				),
				{resets}
			)
			local list_items = react.UseMemo(
				||->build_list_items(lists, |name, list|-> do
					lists[name] = list
					set_list_version(|count|->count + 1)
				end),
				{list_version}
			)
			react.UseEffect(||->inspector.current:SetObject(demo), {demo})
			return kit.Page{
				Title = "Property editor",
				Description = "Grouped, labelled editors for numbers, strings, booleans, enums, vectors, colors, assets and actions. Right click any row to copy, paste or reset it.",
			}{
				kit.Section{
					Title = "Hand built items",
					Description = "Items are nodes with a Type and a Value. OnChange(node, value) can veto a change by returning false.",
				}{
					ui.Splitter{InitialSize = 460, layout = {MinSize = Vec2(0, 300), MaxSize = Vec2(0, 300)}}{
						ui.ScrollablePanel{layout = {GrowWidth = 1, GrowHeight = 1}}{
							ui.PropertyEditor{Key = resets, Items = items},
						},
						ui.Frame{Padding = "S", layout = {GrowWidth = 1, GrowHeight = 1}}{
							ui.Column{
								layout = {GrowWidth = 1, GrowHeight = 1, AlignmentX = "stretch", ChildGap = "XS"},
							}{
								ui.Text{Text = "Live state", Font = "body_strong S", IgnoreMouseInput = true},
								ui.TextEdit{
									Editable = false,
									Wrap = true,
									ScrollY = true,
									Text = snapshot(values),
									Size = Vec2(0, 280),
									MinSize = Vec2(0, 280),
									MaxSize = Vec2(0, 280),
								},
							},
						},
					},
				},
				kit.Section{
					Title = "Lists",
					Description = "A node with Type = list. Rows have a drag handle, duplicate and delete buttons and a right click menu. Chips wrap, tables show one line per item, and group items expand. The header has the count, a + button and a menu with sort and clear. The owner keeps the data: every action calls back and the items are rebuilt.",
				}{
					ui.Frame{Padding = "XS", layout = {GrowWidth = 1, FitHeight = true}}{
						ui.PropertyEditor{Key = list_version, Items = list_items},
					},
				},
				kit.Section{
					Title = "Object inspector",
					Description = "SetObject builds the items from an object's storable properties, including enums, vectors and colors.",
				}{
					ui.Frame{Padding = "XS", layout = {GrowWidth = 1, FitHeight = true}}{ui.PropertyEditor{Ref = inspector}},
				},
			}
		end
	),
}
