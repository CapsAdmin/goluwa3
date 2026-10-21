local desktop = import("goluwa/render2d/ui/desktop.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local PropertyEditor = react.Element(import("goluwa/render2d/ui/widgets/property_editor.lua"))
local pvar_node = import("goluwa/render2d/ui/pvar_node.lua")
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local TextEdit = react.Element(import("goluwa/render2d/ui/elements/text_edit.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local ScrollablePanel = react.Element(import("goluwa/render2d/ui/elements/scrollable_panel.lua"))
local WIDTH = 520
local SEARCH_HEIGHT = 28
local function build_items()
	local items = {}

	for _, category in ipairs(pvars.GetCategories()) do
		for _, group in ipairs(category.groups) do
			local children = {}

			for _, info in ipairs(group.infos) do
				if pvar_node.IsSupported(info) then
					children[#children + 1] = pvar_node.Build(info, function(value)
						pvars.Set(info.key, value)
					end)
				end
			end

			if #children > 0 then
				items[#items + 1] = {
					Key = "pvars/" .. category.name .. "/" .. group.name,
					Text = group.name,
					Tab = category.name,
					Collapsed = true,
					Children = children,
				}
			end
		end
	end

	return items
end

local function refresh_values(editor)
	for _, info in pairs(pvars.GetAll()) do
		if pvar_node.IsSupported(info) then
			editor:UpdateValueForKey(info.key, pvars.Get(info.key))
		end
	end
end

local function reset_all(editor)
	for _, info in pairs(pvars.GetAll()) do
		if pvar_node.IsSupported(info) then pvars.Set(info.key, nil) end
	end

	refresh_values(editor)
end

local window_editor

local PvarsContent = react.Component(|| -> do
	local filter, set_filter = react.UseState("")
	local items = react.UseMemo(build_items, {})
	local editor = react.UseRef()

	react.UseLayoutEffect(|| -> do
		window_editor = editor.current
		refresh_values(editor.current)
	end, {})

	return Column{layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false, AlignmentX = "stretch"}}{
		TextEdit{
			Hint = "Search",
			Wrap = false,
			ScrollX = false,
			ScrollY = false,
			ScrollbarVisible = false,
			Size = Vec2(0, SEARCH_HEIGHT),
			MinSize = Vec2(0, SEARCH_HEIGHT),
			MaxSize = Vec2(0, SEARCH_HEIGHT),
			OnTextChanged = |_, text| -> set_filter(text),
			layout = {GrowWidth = 1},
		},
		ScrollablePanel{ScrollX = false, ScrollY = true, Padding = "M", layout = {GrowWidth = 1, GrowHeight = 1}}{
			PropertyEditor{Ref = editor, Items = items, Filter = filter, layout = {GrowWidth = 1}},
		},
		Row{layout = {Padding = "M", FitHeight = true, GrowWidth = 1}}{
			Button{Text = "Reset all", Mode = "outline", OnClick = || -> reset_all(editor.current)},
		},
	}
end)
local PvarsView = react.Component(|| -> do
	local world_size = react.UseMemo(|| -> Panel.World.transform:GetSize(), {})

	return Window{
		Title = "PVARS",
		Size = Vec2(WIDTH, world_size.y),
		Position = Vec2(world_size.x - WIDTH, 0),
		MinSize = Vec2(WIDTH, 200),
	}{PvarsContent{}}
end)

desktop.RegisterProgram{
	Name = "Pvars",
	Icon = "settings",
	Positioned = true,
	Content = PvarsContent,
	OnOpen = || -> do
		if window_editor and window_editor:IsValid() then refresh_values(window_editor) end
	end,
	Create = function()
		return react.Mount(PvarsView{}, Panel.World):GetEntity()
	end,
}
