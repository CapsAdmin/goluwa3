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

-- the values only start the editor off, it keeps them itself and reports every change through changed(key)
local function build_items(values, changed, reset)
	local function on_change(key)
		return |_, value| -> changed(key, value)
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

return {
	Name = "property editor",
	Section = "Data",
	Order = 3,
	View = react.Component(|| -> do
		local values, set_values = react.UseState(new_values)
		local resets, set_resets = react.UseState(0)
		local inspector = react.UseRef()
		local demo = react.UseResource(|| -> DemoObject.New(), |object| -> object:Remove(), {})
		-- a reset makes a new editor with the default items, the first ones are only used when it opens
		local items = react.UseMemo(
			|| -> build_items(
				values,
				|key, value| -> set_values(|current| -> table.merge(table.shallow_copy(current), {[key] = value})),
				|| -> do
					set_values(new_values())
					set_resets(|count| -> count + 1)
				end
			),
			{resets}
		)

		react.UseEffect(|| -> inspector.current:SetObject(demo), {demo})

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
						ui.Column{layout = {GrowWidth = 1, GrowHeight = 1, AlignmentX = "stretch", ChildGap = "XS"}}{
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
				Title = "Object inspector",
				Description = "SetObject builds the items from an object's storable properties, including enums, vectors and colors.",
			}{
				ui.Frame{Padding = "XS", layout = {GrowWidth = 1, FitHeight = true}}{ui.PropertyEditor{Ref = inspector}},
			},
		}
	end),
}
