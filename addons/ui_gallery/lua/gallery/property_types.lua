local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local objects = import("goluwa/objects/objects.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
-- create a demo object type with all property kinds
local DemoObject = objects.CreateTemplate("demo_object")
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
DemoObject:GetSet("AMaterial", nil, {type = "render3d_material"})
DemoObject:GetSet("ATexture", nil, {type = "render_texture"})
DemoObject:EndStorable()
DemoObject:Register()
return {
	Name = "property types",
	Create = function()
		local demo_obj = DemoObject.New()
		local snapshot_view

		local function refresh_snapshot()
			if snapshot_view and snapshot_view:IsValid() then
				snapshot_view:SetText(table.tostring(demo_obj:GetStorableTable()))
			end
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Property Types",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "Every property type fed through a real object via SetObject.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Splitter{
				InitialSize = 300,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(0, 480),
					MaxSize = Vec2(0, 480),
				},
			}{
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						FitHeight = false,
						AlignmentX = "stretch",
						ChildGap = 10,
					},
				}{
					ScrollablePanel{
						ScrollX = false,
						ScrollY = true,
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
						},
					}{
						PropertyEditor{
							Ref = function(self)
								self:SetObject(demo_obj)
							end,
							OnChange = function()
								refresh_snapshot()
							end,
							layout = {
								GrowHeight = 1,
								FitWidth = false,
							},
						},
					},
				},
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						AlignmentX = "stretch",
						ChildGap = 10,
					},
				}{
					Frame{
						Padding = "S",
						layout = {
							GrowWidth = 1,
						},
					}{
						Column{
							layout = {
								GrowWidth = 1,
								AlignmentX = "stretch",
								ChildGap = 8,
							},
						}{
							Text{
								Text = "Live Storable Table",
								Font = "body_strong S",
								IgnoreMouseInput = true,
							},
							TextEdit{
								Ref = function(self)
									snapshot_view = self
									refresh_snapshot()
								end,
								Editable = false,
								Size = Vec2(0, 320),
								MinSize = Vec2(0, 320),
								MaxSize = Vec2(0, 320),
								Wrap = true,
								layout = {
									GrowWidth = 1,
								},
							},
						},
					},
				},
			},
		}
	end,
}
