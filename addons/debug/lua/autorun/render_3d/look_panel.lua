local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local pvar_node = import("goluwa/render2d/ui/pvar_node.lua")
local grade = import("goluwa/render3d/grade.lua")
local exposure = import("goluwa/render3d/exposure.lua")
local pvars = import("goluwa/cli/pvars.lua")
local WIDTH = 460
local POLL_INTERVAL = 0.1
local DESKTOP_BAR = 104
local CAMERA_GROUPS = {Camera = true, Manual = true}
local CAMERA_EFFECTS = {"r_motion_blur", "r_motion_blur_max", "r_dof", "r_dof_max", "r_grain"}
local nodes = {}
local grade_blend_seconds = grade.BLEND_TIME

local function add_group(items, groups, key, text, tab)
	local group = groups[text]

	if not group then
		group = {Key = key .. text, Text = text, Tab = tab, Children = {}}
		groups[text] = group
		items[#items + 1] = group
	end

	return group
end

local function add_node(group, node)
	nodes[#nodes + 1] = node
	group.Children[#group.Children + 1] = node
end

local function build_items()
	nodes = {}
	local items = {}
	local camera_groups = {}
	local eye_groups = {}
	local eye_items = {}

	for _, info in ipairs(exposure.fields) do
		local tab = CAMERA_GROUPS[info.group] and "Camera" or info.group == "Eye" and "Eye"

		if tab then
			local group = add_group(
				tab == "Camera" and items or eye_items,
				tab == "Camera" and camera_groups or eye_groups,
				"look/" .. tab .. "/",
				info.group,
				tab
			)
			local node = pvar_node.Build(info, function(value)
				exposure.Set(info.key, value)
			end, function()
				return exposure.Get(info.key)
			end)
			node.GetValue = function()
				return exposure.Get(info.key)
			end
			add_node(group, node)
		end
	end

	local effects = add_group(items, camera_groups, "look/Camera/", "Effects", "Camera")

	for _, key in ipairs(CAMERA_EFFECTS) do
		local info = pvars.GetObject(key):GetInfo()
		local node = pvar_node.Build(info, function(value)
			pvars.SetSession(key, value)
		end)
		node.Text = (key:sub(3):gsub("_", " "))
		node.GetValue = function()
			return pvars.Get(key)
		end
		add_node(effects, node)
	end

	local grade_options = {}

	for name in pairs(grade.presets) do
		grade_options[#grade_options + 1] = name
	end

	table.sort(grade_options)

	for i, name in ipairs(grade_options) do
		grade_options[i] = {Text = name, Value = name}
	end

	local function get_grade_preset()
		local preset = grade.GetPreset()
		return type(preset) == "string" and preset or nil
	end

	local grade_preset = {
		Key = "grade/preset",
		Text = "preset",
		Description = "blend the whole look into a grade preset",
		Type = "enum",
		Options = grade_options,
		Value = get_grade_preset(),
		GetValue = get_grade_preset,
		OnChange = function(_, value)
			grade.SetPreset(value, grade_blend_seconds)
		end,
	}
	nodes[#nodes + 1] = grade_preset
	items[#items + 1] = {
		Key = "grade/presets",
		Text = "Preset",
		Tab = "Grade",
		Children = {
			grade_preset,
			{
				Key = "grade/blend_time",
				Text = "blend time",
				Description = "seconds a preset takes to blend in",
				Type = "number",
				Min = 0,
				Max = 10,
				ShowSlider = true,
				Precision = 1,
				Value = grade_blend_seconds,
				OnChange = function(node, value)
					grade_blend_seconds = value
					node.Value = value
				end,
			},
			{
				Type = "action",
				Key = "grade/neutral",
				Text = "neutral",
				Description = "every setting a preset sets back to its default, at once",
				ButtonText = "Reset",
				OnAction = function()
					grade.SetPreset("neutral", 0)
				end,
			},
		},
	}
	local grade_groups = {}

	for _, field in ipairs(grade.fields) do
		local info = grade.GetInfo(field)
		local group = add_group(items, grade_groups, "grade/group/", info.group, "Grade")
		local node = pvar_node.Build(info, function(value)
			grade.Stop()
			grade.SetValue(field, value)
		end, function()
			return grade.GetValue(field)
		end)
		node.GetValue = function()
			return grade.GetValue(field)
		end
		add_node(group, node)
	end

	for _, item in ipairs(eye_items) do
		items[#items + 1] = item
	end

	return items
end

local last_values = {}

local function read_values()
	local values = {}
	local changed = false

	for _, node in ipairs(nodes) do
		local value = node.GetValue()
		values[node.Key] = value

		if value ~= last_values[node.Key] then changed = true end
	end

	if not changed then return last_values end

	last_values = values
	return values
end

local LookEditor = react.Component(
	||-> do
		local editor = react.UseRef()
		local items = react.UseMemo(build_items, {})
		local values = react.UsePoll(read_values, POLL_INTERVAL)
		react.UseEffect(
			||-> do
				for _, node in ipairs(nodes) do
					local value = values[node.Key]

					if value ~= node.Value then editor.current:UpdateValueForKey(node.Key, value) end
				end
			end,
			{values, items}
		)
		return ui.ScrollablePanel{
			ScrollX = false,
			ScrollY = true,
			Padding = "M",
			layout = {GrowWidth = 1, GrowHeight = 1},
		}{
			ui.PropertyEditor{Ref = editor, Items = items, layout = {GrowWidth = 1}},
		}
	end
)
local LookView = react.Component(
	||-> do
		local shown, set_shown = react.UseState(true)
		local size = react.UseMemo(||->Vec2(WIDTH, Panel.World.transform:GetSize().y - DESKTOP_BAR), {})
		return ui.Window{
			Title = "LOOK",
			Pinnable = true,
			Padding = "none",
			Size = size,
			Position = Vec2(0, DESKTOP_BAR),
			MinSize = Vec2(WIDTH, 200),
			OnVisibilityChanged = |_,visible|->set_shown(visible),
		}{shown and LookEditor{}}
	end
)
local LookContent = react.Component(|props|->props.Shown ~= false and LookEditor{})
desktop.RegisterProgram{
	Name = "Look",
	Icon = "eye",
	Positioned = true,
	Content = LookContent,
	Create = function()
		return react.Mount(LookView{}, Panel.World):GetEntity()
	end,
}
