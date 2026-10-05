local input = import("goluwa/input.lua")
local pvars = import("goluwa/cli/pvars.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local WIDTH = 420
local panel = NULL
local property_editor
local node_types = {
	boolean = "boolean",
	number = "number",
	string = "string",
}

local function build_node(info)
	local node = {
		Key = info.key,
		Text = info.friendly,
		Description = info.help,
		Type = node_types[info.type],
		Value = pvars.Get(info.key),
		Default = info.default,
		OnChange = function(_, value)
			pvars.Set(info.key, value)
		end,
	}

	if info.enums then
		node.Type = "enum"
		node.Options = {}

		for i, value in ipairs(info.enums) do
			node.Options[i] = {Text = tostring(value), Value = value}
		end
	elseif info.type == "number" then
		node.Min = info.min
		node.Max = info.max
		node.ShowSlider = info.min ~= nil and info.max ~= nil

		if info.integer then
			node.NumberType = "int"
			node.Precision = 0
		else
			node.Precision = 3
		end
	end

	return node
end

local function build_items()
	local items = {}

	for _, group in ipairs(pvars.GetGroups()) do
		local children = {}

		for _, info in ipairs(group.infos) do
			if node_types[info.type] then children[#children + 1] = build_node(info) end
		end

		if #children > 0 then
			items[#items + 1] = {
				Key = "pvars/" .. group.name,
				Text = group.name,
				Collapsed = true,
				Children = children,
			}
		end
	end

	return items
end

local function refresh_values()
	for _, info in pairs(pvars.GetAll()) do
		if node_types[info.type] then
			property_editor:UpdateValueForKey(info.key, pvars.Get(info.key))
		end
	end
end

local function reset_all()
	for _, info in pairs(pvars.GetAll()) do
		if node_types[info.type] then pvars.Set(info.key, nil) end
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
				MinSize = Vec2(WIDTH, 200),
				OnClose = function()
					panel.visual:SetVisible(false)
				end,
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
							property_editor = self
						end,
						Items = build_items(),
						layout = {
							GrowWidth = 1,
						},
					},
				},
				Button{
					Text = "Reset all",
					Mode = "outline",
					OnClick = reset_all,
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
