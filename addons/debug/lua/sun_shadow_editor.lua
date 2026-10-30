local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local weather = import("goluwa/render3d/weather.lua")
local POLL_INTERVAL = 0.1
local nodes = {}
local SIZE_OPTIONS = {}

for i, size in ipairs{512, 1024, 2048, 4096, 8192} do
	SIZE_OPTIONS[i] = {Text = tostring(size), Value = size}
end

local FORMAT_OPTIONS = {
	{Text = "d16_unorm", Value = "d16_unorm"},
	{Text = "d32_sfloat", Value = "d32_sfloat"},
}
local SHADOW_GROUPS = {
	{
		category = "cascades",
		text = "Cascades",
		help = "shadow maps that follow the camera, each one covers the view out to its split",
		settings = {
			{
				"enabled",
				"enabled",
				"boolean",
				"off destroys the cascades, nothing is lit by them",
			},
			{
				"count",
				"count",
				"integer",
				"how many cascades, each is a texture of the size below",
				{Min = 1, Max = 4, Precision = 0, ShowSlider = true},
			},
			{
				"size",
				"size",
				"enum",
				"texels per side of every cascade",
				{Options = SIZE_OPTIONS},
			},
			{
				"format",
				"depth format",
				"enum",
				"d16 has 65536 depth steps over the cascade's depth range",
				{Options = FORMAT_OPTIONS},
			},
			{
				"distance",
				"distance",
				"number",
				"farthest the last cascade reaches, meters",
				{Min = 20, Max = 10000, Precision = 0, ShowSlider = true},
			},
			{
				"split_lambda",
				"split lambda",
				"number",
				"0 splits the distance evenly, 1 by powers",
				{Min = 0, Max = 1, Precision = 2, ShowSlider = true},
			},
			{
				"zoom",
				"zoom 1",
				"number",
				"above 1 the cascade fits a smaller part of its slice and the next one covers the rest",
				{Min = 0.25, Max = 8, Precision = 2, ShowSlider = true},
				1,
			},
			{
				"zoom",
				"zoom 2",
				"number",
				"zoom of the second cascade",
				{Min = 0.25, Max = 8, Precision = 2, ShowSlider = true},
				2,
			},
			{
				"zoom",
				"zoom 3",
				"number",
				"zoom of the third cascade",
				{Min = 0.25, Max = 8, Precision = 2, ShowSlider = true},
				3,
			},
			{
				"zoom",
				"zoom 4",
				"number",
				"zoom of the fourth cascade",
				{Min = 0.25, Max = 8, Precision = 2, ShowSlider = true},
				4,
			},
			{
				"min_caster_texel_size",
				"min caster size",
				"number",
				"casters smaller than this many texels are not drawn",
				{Min = 0, Max = 16, Precision = 1, ShowSlider = true},
			},
			{
				"update_interval",
				"update interval",
				"integer",
				"frames between draws of the cascades",
				{Min = 1, Max = 8, Precision = 0, ShowSlider = true},
			},
			{
				"cache_far_cascade",
				"cache far cascade",
				"boolean",
				"the farthest cascade is only drawn again when the world changed or the camera moved or turned",
			},
			{
				"far_cascade_move",
				"far cascade move",
				"number",
				"meters the camera moves before the cached cascade is drawn again",
				{Min = 1, Max = 1000, Precision = 0, ShowSlider = true},
			},
		},
	},
	{
		category = "exact",
		text = "Exact cascade",
		help = "the first cascade: a small, finely sampled cascade close to the camera that is redrawn every frame and the only one where vegetation animates",
		settings = {
			{"enabled", "enabled", "boolean", "off destroys the exact cascade"},
			{"size", "size", "enum", "texels per side", {Options = SIZE_OPTIONS}},
			{
				"format",
				"depth format",
				"enum",
				"d16 has 65536 depth steps over the cascade's depth range",
				{Options = FORMAT_OPTIONS},
			},
			{
				"distance",
				"distance",
				"number",
				"how far from the camera it reaches, meters",
				{Min = 2, Max = 200, Precision = 1, ShowSlider = true},
			},
			{
				"zoom",
				"zoom",
				"number",
				"above 1 it fits a smaller part of the view",
				{Min = 0.25, Max = 8, Precision = 2, ShowSlider = true},
			},
			{
				"min_caster_texel_size",
				"min caster size",
				"number",
				"casters smaller than this many texels are not drawn",
				{Min = 0, Max = 16, Precision = 1, ShowSlider = true},
			},
			{
				"update_interval",
				"update interval",
				"integer",
				"frames between draws",
				{Min = 1, Max = 8, Precision = 0, ShowSlider = true},
			},
		},
	},
	{
		category = "bias",
		text = "Bias",
		help = "how far a lit point is moved before it is compared with the shadow maps, against acne and against light leaking in under and through walls",
		settings = {
			{
				"normal",
				"normal offset",
				"number",
				"texels the point is moved along its surface normal, more at a slant. lower stops light from leaking through thin walls",
				{Min = 0, Max = 4, Precision = 2, ShowSlider = true},
			},
			{
				"light",
				"light offset",
				"number",
				"how far the point is moved towards the sun, scaled so that 1 is the default. lower stops light from leaking at the base of a wall, below 0 it moves away from the sun, too low shows acne",
				{Min = -10, Max = 10, Precision = 2, ShowSlider = true},
			},
		},
	},
}

local function describe_cascade(category, i)
	local map = weather.shadow_maps.sun

	if category == "cascades" and weather.GetSunShadow("exact").enabled then i = i + 1 end

	if not map or i > map:GetCascadeCount() then return "off" end

	return string.format(
		"to %.0f m, texel %.3f m",
		map:GetCascadeSplits()[i] or 0,
		map:GetCascadeTexelWorldSize(i)
	)
end

local function build_items()
	nodes = {}
	local items = {
		{
			Key = "shadow/sun",
			Text = "Sun shadows",
			Children = {
				{
					Type = "action",
					Key = "shadow/reset",
					Text = "defaults",
					Description = "every sun shadow setting back to its default, the shadow maps are made again",
					ButtonText = "Reset",
					OnAction = ||->weather.ResetSunShadow(),
				},
			},
		},
	}

	for _, group in ipairs(SHADOW_GROUPS) do
		local category = group.category
		local children = {}

		for _, setting in ipairs(group.settings) do
			local key, text, node_type, help, fields, index = unpack(setting)

			local function get()
				local value = weather.GetSunShadow(category)[key]

				if index then return value[index] end

				return value
			end

			local node = {
				Key = "shadow/" .. category .. "/" .. key .. (index and "/" .. index or ""),
				Text = text,
				Description = help,
				Type = node_type,
				Value = get(),
				GetValue = get,
			}

			function node.OnChange(_, value)
				if index then
					local list = weather.GetSunShadow(category)[key]
					list[index] = value
					value = list
				end

				weather.SetSunShadow(category, {[key] = value})
				node.Value = get()
			end

			table.merge(node, fields or {})
			nodes[#nodes + 1] = node
			children[#children + 1] = node
		end

		for i = 1, category == "cascades" and 4 or category == "exact" and 1 or 0 do
			local node = {
				Key = "shadow/" .. category .. "/result/" .. i,
				Text = category == "cascades" and "cascade " .. i or "reach",
				Description = "how far it reaches and the world size of one texel",
				Type = "string",
				Value = describe_cascade(category, i),
				GetValue = ||->describe_cascade(category, i),
				OnChange = ||->false,
			}
			nodes[#nodes + 1] = node
			children[#children + 1] = node
		end

		items[#items + 1] = {
			Key = "shadow/" .. category,
			Text = group.text,
			Description = group.help,
			Children = children,
		}
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

return react.Component(
	|props|-> do
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
			layout = {GrowWidth = 1, MinSize = Vec2(0, props.Height), MaxSize = Vec2(0, props.Height)},
		}{
			ui.PropertyEditor{Ref = editor, Items = items, layout = {GrowWidth = 1}},
		}
	end
)
