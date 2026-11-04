local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local react = import("goluwa/render2d/ui/react.lua")
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local TreeTable = react.Element(import("goluwa/render2d/ui/widgets/tree_table.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local TextEdit = react.Element(import("goluwa/render2d/ui/elements/text_edit.lua"))
local Checkbox = react.Element(import("goluwa/render2d/ui/elements/checkbox.lua"))
local Slider = react.Element(import("goluwa/render2d/ui/elements/slider.lua"))
local system = import("goluwa/system.lua")
local kit = import("lua/editor_kit.lua")
local ViewerWindow = kit.ViewerWindow
local WINDOW_SIZE = Vec2(430, 680)
local WINDOW_POSITION = Vec2(16, 48)
local INPUT_HEIGHT = 26
local SCRUB_HOLD = 0.2
local FORWARD = {move_x = 1, move_y = 0}
local INITIAL_PARAMETERS = {move_x = 1}
local COLUMNS = {
	{Key = "Text", Text = "Name", Grow = true, MinWidth = 140},
	{
		Key = "Duration",
		Text = "Length",
		Width = 70,
		Format = |value|->value > 0 and string.format("%.2fs", value) or "pose",
	},
	{Key = "Loop", Text = "Loop", Width = 50, Format = |value|->value and "yes" or "no"},
	{
		Key = "Speed",
		Text = "m/s",
		Width = 50,
		Format = |value|->value > 0 and string.format("%.2f", value) or "",
	},
	{Key = "Params", Text = "Blend", Width = 90},
}

local function create_nodes(skeleton)
	local nodes = {}

	for i, clip in ipairs(skeleton.Clips) do
		nodes[i] = {
			Key = clip.Name,
			Text = clip.Name,
			Clip = clip,
			Duration = clip.Duration,
			Loop = clip.Loop ~= false,
			Speed = clip:GetGroundSpeed(FORWARD),
			Params = clip.param_names and table.concat(clip.param_names, ", ") or "",
			Lower = clip.Name:lower(),
		}
	end

	return nodes
end

local function filter_nodes(nodes, query)
	local tokens = {}

	for token in query:lower():gmatch("%S+") do
		tokens[#tokens + 1] = token
	end

	if #tokens == 0 then return nodes end

	local out = {}

	for _, node in ipairs(nodes) do
		local matches = true

		for _, token in ipairs(tokens) do
			if not node.Lower:find(token, 1, true) then
				matches = false

				break
			end
		end

		if matches then out[#out + 1] = node end
	end

	return out
end

return react.Component(
	|props|-> do
		local animator = props.Animator
		local skeleton = props.Skeleton
		local nodes = react.UseMemo(||->create_nodes(skeleton), {skeleton})
		local query, set_query = react.UseState("")
		local selected, set_selected = react.UseState(nil)
		local playing, set_playing = react.UseState(true)
		local time_text, set_time_text = react.UseState("")
		local scrub = react.UseRef()
		local scrub_hold = react.UseRef(0)
		local shown = react.UseMemo(||->filter_nodes(nodes, query), {nodes, query})
		local ranges = react.UseMemo(
			||-> do
				local list = {}

				for _, name in ipairs(skeleton.PoseParameterNames) do
					list[#list + 1] = {name = name, range = skeleton.PoseParameterRanges[name]}
				end

				return list
			end,
			{skeleton}
		)
		react.UseResource(
			||-> do
				for name, value in pairs(INITIAL_PARAMETERS) do
					if skeleton.PoseParameterRanges[name] then
						animator:SetPoseParameterByName(name, value)
					end
				end

				return true
			end,
			||->nil,
			{animator}
		)
		react.UseEvent(
			"Update",
			||-> do
				local clip = animator.clip

				if not clip or not scrub.current then return end

				local duration = math.max(clip.Duration, 1e-3)
				local slider = scrub.current

				if slider.Max ~= duration then slider:SetMax(duration) end

				if system.GetUnscaledElapsedTime() > scrub_hold.current then
					slider:SetValue(math.clamp(animator:GetTime(), 0, duration))
				end

				local text = string.format("%.2f / %.2f s", animator:GetTime(), clip.Duration)

				if text ~= time_text then set_time_text(text) end
			end
		)
		local play = react.UseCallback(
			|node|-> do
				if not node then return end

				set_selected(node.Key)
				animator:SetSequence(node.Clip.Name)
				animator:SetPlaying(true)
				set_playing(true)
			end,
			{}
		)
		local pose_rows = {}

		for i, info in ipairs(ranges) do
			pose_rows[i] = Row{
				Key = info.name,
				layout = {GrowWidth = 1, ChildGap = 8, AlignmentY = "center"},
			}{
				Text{
					Text = info.name,
					Color = "text_disabled",
					layout = {FitWidth = false, MinSize = Vec2(110, 0), MaxSize = Vec2(110, 0)},
				},
				Slider{
					Mode = "horizontal",
					Min = info.range[1],
					Max = info.range[2],
					Value = INITIAL_PARAMETERS[info.name] ?? 0,
					OnChange = |value|->animator:SetPoseParameterByName(info.name, value),
					layout = {GrowWidth = 1, MinSize = Vec2(80, 14), MaxSize = Vec2(0, 14), FitWidth = false},
				},
			}
		end

		return ViewerWindow{
			Title = props.Title,
			Size = WINDOW_SIZE,
			Position = WINDOW_POSITION,
			layout = {FitHeight = false, FitWidth = false},
		}{
			Column{
				layout = {
					GrowWidth = 1,
					GrowHeight = 1,
					FitHeight = false,
					AlignmentX = "stretch",
					ChildGap = 6,
					Padding = Rect() + 8,
				},
			}{
				Row{layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "center"}}{
					TextEdit{
						Hint = "search clips",
						Size = Vec2(0, INPUT_HEIGHT),
						MinSize = Vec2(120, INPUT_HEIGHT),
						MaxSize = Vec2(0, INPUT_HEIGHT),
						Wrap = false,
						ScrollX = false,
						ScrollY = false,
						OnTextChanged = |_,text|->set_query(text),
						layout = {GrowWidth = 1},
					},
					Text{
						Text = #shown .. " / " .. #nodes,
						Color = "text_disabled",
						layout = {FitWidth = true, MinSize = Vec2(60, 0)},
					},
				},
				TreeTable{
					Mode = "list",
					Items = shown,
					Columns = COLUMNS,
					SelectedKey = selected,
					OnSelect = play,
					OnActivate = play,
					layout = {GrowWidth = 1, GrowHeight = 1},
				},
				Row{layout = {GrowWidth = 1, ChildGap = 8, AlignmentY = "center"}}{
					Button{
						Text = playing and "Pause" or "Play",
						Mode = "outline",
						OnClick = ||-> do
							local value = not animator.Playing
							animator:SetPlaying(value)
							set_playing(value)
						end,
					},
					Slider{
						Mode = "horizontal",
						Min = 0,
						Max = 1,
						Value = 0,
						Ref = scrub,
						OnChange = |value|-> do
							animator:SetPlaying(false)
							animator:SetTime(value)
							set_playing(false)
							scrub_hold.current = system.GetUnscaledElapsedTime() + SCRUB_HOLD
						end,
						Tooltip = "time in the clip",
						layout = {GrowWidth = 1, MinSize = Vec2(80, 16), MaxSize = Vec2(0, 16), FitWidth = false},
					},
					Text{
						Text = time_text,
						Color = "text_disabled",
						layout = {FitWidth = true, MinSize = Vec2(100, 0)},
					},
				},
				Row{layout = {GrowWidth = 1, ChildGap = 8, AlignmentY = "center"}}{
					Text{Text = "Speed", Color = "text_disabled", layout = {FitWidth = true}},
					Slider{
						Mode = "horizontal",
						Min = 0.1,
						Max = 2,
						Value = 1,
						OnChange = |value|->animator:SetSpeed(value),
						Tooltip = "playback speed",
						layout = {GrowWidth = 1, MinSize = Vec2(80, 16), MaxSize = Vec2(0, 16), FitWidth = false},
					},
					Checkbox{Text = "Loop", Value = true, OnChange = |value|->animator:SetLoop(value)},
				},
				#ranges > 0 and
				Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = 2, AlignmentX = "stretch"}}(pose_rows),
			},
		}
	end
)
