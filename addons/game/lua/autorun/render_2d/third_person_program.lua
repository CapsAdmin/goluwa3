local desktop = import("goluwa/render2d/ui/desktop.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local pvar_node = import("goluwa/render2d/ui/pvar_node.lua")
local third_person = import("lua/third_person.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local PropertyEditor = react.Element(import("goluwa/render2d/ui/widgets/property_editor.lua"))
local TextEdit = react.Element(import("goluwa/render2d/ui/elements/text_edit.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local ScrollablePanel = react.Element(import("goluwa/render2d/ui/elements/scrollable_panel.lua"))
local WIDTH = 460
local SEARCH_HEIGHT = 28
local editor_ref
local selected_preset

local function refresh_values()
	for _, key in ipairs(third_person.Order) do
		local info = third_person.Definitions[key]
		editor_ref:UpdateValueForKey(info.key, pvars.Get(info.key))
	end
end

local function on_change(info)
	return function(value)
		pvars.Set(info.key, value)
	end
end

local function build_items()
	local items = {}
	local options = {}
	local by_name = {}

	for i, preset in ipairs(third_person.Presets) do
		options[i] = {Text = preset.Name, Value = preset.Name}
		by_name[preset.Name] = preset
	end

	items[1] = {
		Key = "third_person/presets",
		Text = "Presets",
		Children = {
			{
				Key = "third_person/preset",
				Text = "preset",
				Description = "selecting a preset overrides every setting below",
				Type = "enum",
				Options = options,
				Value = selected_preset,
				OnChange = function(_, name)
					selected_preset = name
					third_person.ApplyPreset(by_name[name])
					refresh_values()
				end,
			},
		},
	}

	for _, group in ipairs(third_person.Groups) do
		local children = {}

		for _, key in ipairs(third_person.Order) do
			local info = third_person.Definitions[key]

			if info.group == "Third person " .. group then
				children[#children + 1] = pvar_node.Build(info, on_change(info))
			end
		end

		items[#items + 1] = {
			Key = "third_person/" .. group,
			Text = group:sub(1, 1):upper() .. group:sub(2),
			Collapsed = group ~= "camera",
			Children = children,
		}
	end

	return items
end

local Content = react.Component(
	||-> do
		local filter, set_filter = react.UseState("")
		local items = react.UseMemo(build_items, {})
		local editor = react.UseRef()
		react.UseLayoutEffect(
			||-> do
				editor_ref = editor.current
			end,
			{}
		)
		return Column{
			layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false, AlignmentX = "stretch"},
		}{
			TextEdit{
				Hint = "Search",
				Wrap = false,
				ScrollX = false,
				ScrollY = false,
				ScrollbarVisible = false,
				Size = Vec2(0, SEARCH_HEIGHT),
				MinSize = Vec2(0, SEARCH_HEIGHT),
				MaxSize = Vec2(0, SEARCH_HEIGHT),
				OnTextChanged = |_,text|->set_filter(text),
				layout = {GrowWidth = 1},
			},
			ScrollablePanel{
				ScrollX = false,
				ScrollY = true,
				Padding = "M",
				layout = {GrowWidth = 1, GrowHeight = 1},
			}{
				PropertyEditor{Ref = editor, Items = items, Filter = filter, layout = {GrowWidth = 1}},
			},
		}
	end
)
local View = react.Component(
	||-> do
		local world_size = react.UseMemo(||->Panel.World.transform:GetSize(), {})
		return Window{
			Title = "THIRD PERSON",
			Size = Vec2(WIDTH, world_size.y),
			Position = Vec2(world_size.x - WIDTH, 0),
			MinSize = Vec2(WIDTH, 200),
		}{Content{}}
	end
)
desktop.RegisterProgram{
	Name = "Third person",
	Icon = "settings",
	Positioned = true,
	Content = Content,
	OnOpen = ||-> do
		if editor_ref and editor_ref:IsValid() then refresh_values() end
	end,
	Create = function()
		return react.Mount(View{}, Panel.World):GetEntity()
	end,
}
