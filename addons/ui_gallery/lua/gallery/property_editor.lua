local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local objects = import("goluwa/objects/objects.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
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

local function build_items(state)
	local function changed(key)
		return function(node, value)
			state[key] = value
			state.refresh()
		end
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
					Value = state.name,
					Default = "Beacon Drone",
					Description = "Shown in the inspector.",
					OnChange = changed("name"),
				},
				{
					Key = "appearance/visible",
					Text = "Visible",
					Type = "boolean",
					Value = state.visible,
					Default = true,
					OnChange = changed("visible"),
				},
				{
					Key = "appearance/material",
					Text = "Material",
					Type = "enum",
					Value = state.material,
					Default = "glass",
					Options = {
						{Text = "Glass", Value = "glass"},
						{Text = "Scanlines", Value = "scanlines"},
						{Text = "Hologram", Value = "hologram"},
						{Text = "Chrome", Value = "chrome"},
					},
					OnChange = changed("material"),
				},
				{
					Key = "appearance/opacity",
					Text = "Opacity",
					Type = "number",
					Value = state.opacity,
					Default = 0.72,
					Min = 0,
					Max = 1,
					Precision = 2,
					ShowSlider = true,
					OnChange = changed("opacity"),
				},
				{
					Key = "appearance/color",
					Text = "Tint",
					Type = "color",
					Value = state.color,
					Default = Color(0.2, 0.7, 1, 1),
					OnChange = changed("color"),
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
					Value = state.spin,
					Default = 38,
					Min = 0,
					Max = 360,
					Precision = 1,
					ShowStepper = true,
					OnChange = changed("spin"),
				},
				{
					Key = "motion/count",
					Text = "Count",
					Type = "integer",
					Value = state.count,
					Default = 4,
					Min = 1,
					Max = 16,
					Precision = 0,
					ShowStepper = true,
					OnChange = changed("count"),
				},
				{
					Key = "motion/offset",
					Text = "Offset",
					Type = "vec3",
					Value = state.offset,
					Default = Vec3(0, 6, 2),
					Precision = 1,
					OnChange = changed("offset"),
				},
				{
					Key = "motion/rotation",
					Text = "Rotation",
					Type = "ang3",
					Value = state.rotation,
					Default = Ang3(0, 0, 0),
					Precision = 1,
					OnChange = changed("rotation"),
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
					Value = state.notes,
					OnChange = changed("notes"),
				},
				{
					Key = "notes/reset",
					Text = "Reset",
					Type = "action",
					ButtonText = "Reset to defaults",
					OnAction = function()
						state.reset()
					end,
				},
			},
		},
	}
end

local function new_state()
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

local function snapshot(state)
	return string.format(
		"name = %s\nvisible = %s\nmaterial = %s\nopacity = %.2f\ncolor = %s\nspin = %.1f\ncount = %d\noffset = %s\nrotation = %s\nnotes = %q",
		state.name,
		tostring(state.visible),
		state.material,
		state.opacity,
		tostring(state.color),
		state.spin,
		state.count,
		tostring(state.offset),
		tostring(state.rotation),
		state.notes
	)
end

return {
	Name = "property editor",
	Section = "Data",
	Order = 3,
	Create = function()
		local state = new_state()
		local view = TextEdit{
			Editable = false,
			Wrap = true,
			ScrollY = true,
			Size = Vec2(0, 280),
			MinSize = Vec2(0, 280),
			MaxSize = Vec2(0, 280),
		}
		local editor

		function state.refresh()
			view:SetText(snapshot(state))
		end

		function state.reset()
			local fresh = new_state()

			for key, value in pairs(fresh) do
				state[key] = value
			end

			editor:SetItems(build_items(state))
			state.refresh()
		end

		editor = PropertyEditor{Items = build_items(state)}
		state.refresh()
		local demo = DemoObject.New()
		local inspector = PropertyEditor{}
		inspector:SetObject(demo)
		return kit.Page{
			Title = "Property editor",
			Description = "Grouped, labelled editors for numbers, strings, booleans, enums, vectors, colors, assets and actions. Right click any row to copy, paste or reset it.",
		}{
			kit.Section{
				Title = "Hand built items",
				Description = "Items are nodes with a Type and a Value. OnChange(node, value) can veto a change by returning false.",
			}{
				Splitter{InitialSize = 460, layout = {MinSize = Vec2(0, 300), MaxSize = Vec2(0, 300)}}{
					ScrollablePanel{layout = {GrowWidth = 1, GrowHeight = 1}}{editor},
					Frame{Padding = "S", layout = {GrowWidth = 1, GrowHeight = 1}}{
						Column{
							layout = {GrowWidth = 1, GrowHeight = 1, AlignmentX = "stretch", ChildGap = "XS"},
						}{
							Text{Text = "Live state", Font = "body_strong S", IgnoreMouseInput = true},
							view,
						},
					},
				},
			},
			kit.Section{
				Title = "Object inspector",
				Description = "SetObject builds the items from an object's storable properties, including enums, vectors and colors.",
			}{
				Frame{Padding = "XS", layout = {GrowWidth = 1, FitHeight = true}}{inspector},
			},
		}
	end,
}
