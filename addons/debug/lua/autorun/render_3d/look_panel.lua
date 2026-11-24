local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local pvar_node = import("goluwa/render2d/ui/pvar_node.lua")
local ToneCurve = import("goluwa/render2d/ui/widgets/tone_curve.lua")
local Color = import("goluwa/structs/color.lua")
local grade = import("goluwa/render3d/grade.lua")
local exposure = import("goluwa/render3d/exposure.lua")
local lens = import("goluwa/render3d/lens.lua")
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

	local curve_keys = {}

	for _, field in ipairs(grade.fields) do
		if field.curve then curve_keys[#curve_keys + 1] = field.key end
	end

	local function get_curves()
		local values = {}

		for i, key in ipairs(curve_keys) do
			values[i] = pvars.Get(key)
		end

		return table.concat(values, "|") .. "|" .. grade.GetCurveDisplayRange()
	end

	local tone_curve

	local function sync_tone_curve()
		if not tone_curve or not tone_curve:IsValid() then return end

		tone_curve:SetRange(math.max(grade.GetCurveDisplayRange(), 1))

		for i, key in ipairs(curve_keys) do
			local text = pvars.Get(key)

			if text ~= tone_curve.Curves[i].Source then
				tone_curve.Curves[i].Source = text
				tone_curve:SetPoints(i, text ~= "" and grade.ParseCurve(text) or nil)
			end
		end
	end

	local curve_node = {
		Key = "grade/tone_curve",
		Type = "panel",
		GetValue = get_curves,
		Apply = sync_tone_curve,
		Build = function()
			local channels = {
				{Text = "all", Color = Color(0.9, 0.9, 0.9), Histogram = "luma"},
				{Text = "red", Color = Color(1, 0.35, 0.3), Histogram = "r"},
				{Text = "green", Color = Color(0.35, 0.9, 0.4), Histogram = "g"},
				{Text = "blue", Color = Color(0.4, 0.6, 1), Histogram = "b"},
			}
			tone_curve = ToneCurve{
				Curves = channels,
				OnGetHistogram = grade.GetHistogram,
				OnChange = function(index, points)
					grade.Stop()
					local text = points and grade.FormatCurve(points) or ""
					channels[index].Source = text
					pvars.SetSession(curve_keys[index], text)
				end,
			}
			sync_tone_curve()
			return tone_curve
		end,
	}

	for _, field in ipairs(grade.fields) do
		local info = grade.GetInfo(field)
		local group = add_group(items, grade_groups, "grade/group/", info.group, "Grade")

		if field.curve then
			if not group.Children[1] then add_node(group, curve_node) end

			goto continue
		end
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

		::continue::
	end

	local lut_group = add_group(items, grade_groups, "grade/group/", "Look LUT", "Grade")
	local lut_options = {{Text = "none", Value = ""}}

	for _, path in ipairs(grade.FindLuts()) do
		lut_options[#lut_options + 1] = {Text = (path:gsub("^luts/", "")), Value = path}
	end

	local function get_lut()
		return pvars.Get("r_grade_lut")
	end

	add_node(
		lut_group,
		{
			Key = "r_grade_lut",
			Text = "file",
			Description = "r_grade_lut: a look up table from any luts/ folder, type to search",
			Search = "r_grade_lut",
			Type = "enum",
			Options = lut_options,
			Value = get_lut(),
			GetValue = get_lut,
			OnChange = function(_, value)
				pvars.SetSession("r_grade_lut", value)
			end,
		}
	)

	for _, key in ipairs{"r_grade_lut_strength", "r_grade_lut_space", "r_grade_lut_order"} do
		local node = pvar_node.Build(pvars.GetObject(key):GetInfo(), function(value)
			pvars.SetSession(key, value)
		end)
		node.GetValue = function()
			return pvars.Get(key)
		end
		add_node(lut_group, node)
	end

	local lens_options = {}

	for name in pairs(lens.presets) do
		lens_options[#lens_options + 1] = name
	end

	table.sort(lens_options)

	for i, name in ipairs(lens_options) do
		lens_options[i] = {Text = name, Value = name}
	end

	local lens_preset = {
		Key = "lens/preset",
		Text = "preset",
		Description = "a lens and aperture to shoot through, every knob below at once. Changing a knob leaves the preset",
		Type = "enum",
		Options = lens_options,
		Value = lens.GetPreset(),
		GetValue = lens.GetPreset,
		OnChange = function(_, value)
			lens.SetPreset(value)
		end,
	}
	nodes[#nodes + 1] = lens_preset
	items[#items + 1] = {
		Key = "lens/presets",
		Text = "Preset",
		Tab = "Lens",
		Children = {lens_preset},
	}
	local lens_groups = {}

	for _, info in ipairs(lens.fields) do
		local group = add_group(items, lens_groups, "lens/group/", info.group, "Lens")
		local node = pvar_node.Build(info, function(value)
			lens.Set(info.key, value)
		end, function()
			return lens.Get(info.key)
		end)
		node.GetValue = function()
			return lens.Get(info.key)
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

					if value ~= node.Value then
						if node.Apply then
							node.Value = value
							node.Apply()
						else
							editor.current:UpdateValueForKey(node.Key, value)
						end
					end
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
		local size = react.UseMemo(||->Vec2(WIDTH, Panel.World.transform:GetSize().y - DESKTOP_BAR), {})
		return ui.Window{
			Title = "LOOK",
			Pinnable = true,
			Padding = "none",
			Size = size,
			Position = Vec2(0, DESKTOP_BAR),
			MinSize = Vec2(WIDTH, 200),
		}{LookEditor{}}
	end
)
local LookContent = LookEditor
desktop.RegisterProgram{
	Name = "Look",
	Icon = "eye",
	Positioned = true,
	Content = LookContent,
	Create = function()
		return react.Mount(LookView{}, Panel.World):GetEntity()
	end,
}
