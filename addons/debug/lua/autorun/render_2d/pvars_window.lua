local input = import("goluwa/input.lua")
local pvars = import("goluwa/cli/pvars.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local pvar_node = import("goluwa/render2d/ui/pvar_node.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local WIDTH = 520
local SEARCH_HEIGHT = 28
local panel = NULL
local property_editor
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

local function refresh_values()
	for _, info in pairs(pvars.GetAll()) do
		if pvar_node.IsSupported(info) then
			property_editor:UpdateValueForKey(info.key, pvars.Get(info.key))
		end
	end
end

local function reset_all()
	for _, info in pairs(pvars.GetAll()) do
		if pvar_node.IsSupported(info) then pvars.Set(info.key, nil) end
	end

	refresh_values()
end

local function is_editing()
	if not panel:IsValid() then return false end

	local focused = objects.GetFocusedObject()

	while focused and focused:IsValid() do
		if focused == panel then return true end

		focused = focused:GetParent()
	end

	return false
end

local function show()
	local world = Panel.World

	if not panel:IsValid() then
		panel = world:Ensure(
			Window{
				Key = "PvarsWindow",
				Title = "PVARS",
				RequestMouse = true,
				Padding = "none",
				MinSize = Vec2(WIDTH, 200),
				OnClose = function()
					panel.visual:SetVisible(false)
				end,
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
					OnTextChanged = function(_, text)
						property_editor:SetFilter(text)
					end,
					layout = {GrowWidth = 1},
				},
				ScrollablePanel{
					ScrollX = false,
					ScrollY = true,
					Padding = "M",
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
					},
				}{
					PropertyEditor{
						Ref = function(self)
							property_editor = self
						end,
						Items = build_items(),
						layout = {
							GrowWidth = 1,
						},
					},
				},
				Row{layout = {Padding = "M", FitHeight = true, GrowWidth = 1}}{
					Button{
						Text = "Reset all",
						Mode = "outline",
						OnClick = reset_all,
					},
				},
			}
		)
	else
		refresh_values()
	end

	local size = world.transform:GetSize()
	panel.transform:SetSize(Vec2(WIDTH, size.y))
	panel.transform:SetPosition(Vec2(size.x - WIDTH, 0))
	panel.visual:SetVisible(true)
end

input.Bind("c", "+show_pvars", function()
	show()
end)

input.Bind("c", "-show_pvars", function()
	if not panel:IsValid() then return end

	if is_editing() then return end

	panel.visual:SetVisible(false)
end)
