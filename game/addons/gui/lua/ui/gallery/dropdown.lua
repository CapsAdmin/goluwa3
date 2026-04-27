local Column = import("../elements/column.lua")
local Dropdown = import("../elements/dropdown.lua")
local Row = import("../elements/row.lua")
local Text = import("../elements/text.lua")

local function build_options(prefix, count)
	local options = {}

	for i = 1, count do
		options[i] = {
			Text = string.format("%s %02d", prefix, i),
			Value = string.format("%s_%02d", prefix:gsub("%s+", "_"):lower(), i),
		}
	end

	return options
end

local function get_option_text(options, value, fallback)
	for _, option in ipairs(options) do
		if option.Value == value then return option.Text end
	end

	return fallback or "Select..."
end

local function build_case(title, description, children)
	local panel = Column{
		layout = {
			Direction = "y",
			GrowWidth = 1,
			FitHeight = true,
			AlignmentX = "stretch",
			ChildGap = 6,
		},
	}{
		Text{
			Text = title,
			Font = "body_strong S",
			IgnoreMouseInput = true,
		},
		Text{
			Text = description,
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {
				GrowWidth = 1,
			},
		},
	}

	for _, child in ipairs(children) do
		panel:AddChild(child)
	end

	return panel
end

return {
	Name = "dropdown",
	Create = function()
		local accent_options = {
			{Text = "Sunset Orange", Value = "sunset"},
			{Text = "Ocean Blue", Value = "ocean"},
			{Text = "Forest Green", Value = "forest"},
			{Text = "Slate Grey", Value = "slate"},
		}
		local project_options = {
			{Text = "Prototype", Value = "prototype"},
			{Text = "Vertical Slice", Value = "slice"},
			{Text = "Content Review", Value = "review"},
			{Text = "Release Candidate", Value = "release"},
		}
		local density_options = {
			{Text = "Compact", Value = "compact"},
			{Text = "Comfortable", Value = "comfortable"},
			{Text = "Spacious", Value = "spacious"},
		}
		local asset_options = build_options("Asset Pack", 48)
		local preset_options = build_options("Workspace Preset", 24)
		local state = {
			accent = "ocean",
			project = "prototype",
			density = "comfortable",
			asset = "asset_pack_08",
			preset = "workspace_preset_03",
		}

		local function make_dropdown(key, options, extra_props)
			extra_props = extra_props or {}
			return Dropdown{
				Text = get_option_text(options, state[key], extra_props.FallbackText),
				Options = options,
				Searchable = extra_props.Searchable,
				SearchThreshold = extra_props.SearchThreshold,
				SearchInputHeight = extra_props.SearchInputHeight,
				EmptySearchText = extra_props.EmptySearchText,
				Padding = extra_props.Padding,
				GetText = function()
					return get_option_text(options, state[key], extra_props.FallbackText)
				end,
				OnSelect = function(value)
					state[key] = value
				end,
				layout = {
					GrowWidth = 1,
				},
			}
		end

		return Column{
			layout = {
				Direction = "y",
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = 16,
			},
		}{
			Text{
				Text = "Dropdown",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "A small showcase covering short menus, long searchable lists, and compact trigger styles. Use it to verify the dropdown feels correct as a normal control, not as a diagnostics harness.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Row{
				layout = {
					Direction = "x",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentY = "start",
					ChildGap = 16,
				},
			}{
				build_case(
					"Simple Selection",
					"A short option set that opens as a plain menu and mirrors the selected value in the trigger.",
					{
						make_dropdown("accent", accent_options),
					}
				),
				build_case(
					"Form Control",
					"Typical settings-style dropdown with a compact list and a stable selected label.",
					{
						make_dropdown("project", project_options),
						make_dropdown("density", density_options, {Padding = "XS"}),
					}
				),
			},
			Row{
				layout = {
					Direction = "x",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentY = "start",
					ChildGap = 16,
				},
			}{
				build_case(
					"Searchable Catalog",
					"A long list that switches to the scrollable searchable menu once the option count crosses the threshold.",
					{
						make_dropdown("asset", asset_options, {Searchable = true}),
					}
				),
				build_case(
					"Forced Search Mode",
					"Useful when the list is always large enough that immediate filtering is the better interaction.",
					{
						make_dropdown(
							"preset",
							preset_options,
							{
								Searchable = true,
								SearchThreshold = 0,
								SearchInputHeight = 28,
								EmptySearchText = "No presets match",
							}
						),
					}
				),
			},
		}
	end,
}
