local event = import("goluwa/event.lua")
local commands = import("goluwa/commands.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local debug_draw = import("goluwa/render3d/debug_draw.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local visual_module = import("goluwa/ecs/components/3d/visual.lua")
local Visual = visual_module
local visual = visual_module.Library
local show_culling_panel = false
local show_culling_boxes = false
local colors = {
	visible = {0.25, 0.95, 0.35, 0.9},
	conditional = {1.0, 0.82, 0.22, 0.95},
	culled = {1.0, 0.28, 0.24, 0.95},
	text = {0.92, 0.95, 1.0, 1.0},
	muted = {0.62, 0.69, 0.78, 1.0},
	accent = {0.50, 0.82, 1.0, 1.0},
	warning = {1.0, 0.9, 0.35, 1.0},
}

local function set_panel_enabled(enabled)
	show_culling_panel = enabled == true
	print("[Culling Debug] Panel " .. (show_culling_panel and "ON" or "OFF"))
end

local function set_boxes_enabled(enabled)
	show_culling_boxes = enabled == true
	print("[Culling Debug] Boxes " .. (show_culling_boxes and "ON" or "OFF"))
end

local function get_occlusion_mode_label()
	if not visual.IsOcclusionCullingEnabled() then return "disabled" end

	if gpu_culling.IsEnabled() and gpu_culling.GetOcclusionMode then
		return tostring(gpu_culling.GetOcclusionMode())
	end

	return "queries"
end

local function collect_culling_state()
	local counts = {
		total = 0,
		visible = 0,
		submitted = 0,
		conditional = 0,
		culled = 0,
	}
	local state_by_component = {}
	local visible_lookup = {}
	local visible_records, visible_entry_index_ptr, visible_entry_count = visual.GetVisibleVisuals()

	if visible_entry_index_ptr then
		for i = 0, visible_entry_count - 1 do
			local entry_index = tonumber(visible_entry_index_ptr[i])
			local record = visible_records and visible_records[entry_index + 1] or nil
			local component = record and record.component or nil

			if component then visible_lookup[component] = true end
		end
	else
		for _, component in ipairs(visible_records or {}) do
			visible_lookup[component] = true
		end
	end

	for _, component in ipairs(Visual.Instances or {}) do
		if component.Visible then
			counts.total = counts.total + 1
			local state = "culled"

			if visible_lookup[component] then
				state = component.using_conditional_rendering and "conditional" or "visible"
			end

			state_by_component[component] = state
			counts[state] = counts[state] + 1

			if state ~= "culled" then counts.submitted = counts.submitted + 1 end
		end
	end

	return counts, state_by_component
end

commands.Add("culling_debug_panel", function()
	set_panel_enabled(not show_culling_panel)
end)

commands.Add("culling_debug_boxes", function()
	set_boxes_enabled(not show_culling_boxes)
end)

commands.Add("culling_debug_all", function()
	local enabled = not (show_culling_panel and show_culling_boxes)
	show_culling_panel = enabled
	show_culling_boxes = enabled
	print("[Culling Debug] Panel " .. (show_culling_panel and "ON" or "OFF"))
	print("[Culling Debug] Boxes " .. (show_culling_boxes and "ON" or "OFF"))
end)

event.AddListener("Draw2D", "culling_debug_panel", function()
	if not show_culling_panel then return end

	fonts.SetFont(fonts.GetDefaultFont())
	local font = fonts.GetFont()
	local x = 12
	local y = 52
	local line_height = 18
	local counts = select(1, collect_culling_state())
	local occlusion_stats = visual.GetOcclusionStats()
	local panel_width = 360
	local panel_height = 186
	render2d.SetTexture(nil)
	render2d.SetColor(0.05, 0.07, 0.10, 0.93)
	gfx.DrawRoundedRect(x - 8, y - 10, panel_width, panel_height, 10)
	render2d.SetColor(colors.text[1], colors.text[2], colors.text[3], colors.text[4])
	font:DrawText("Culling Debug", x, y)
	y = y + line_height
	render2d.SetColor(colors.accent[1], colors.accent[2], colors.accent[3], colors.accent[4])
	font:DrawText(string.format("Frustum: %s", visual.noculling and "disabled" or "enabled"), x, y)
	y = y + line_height
	render2d.SetColor(colors.accent[1], colors.accent[2], colors.accent[3], colors.accent[4])
	font:DrawText(
		string.format(
			"Occlusion: %s (%s)",
			visual.IsOcclusionCullingEnabled() and "enabled" or "disabled",
			get_occlusion_mode_label()
		),
		x,
		y
	)
	y = y + line_height

	if visual.freeze_culling then
		render2d.SetColor(colors.warning[1], colors.warning[2], colors.warning[3], colors.warning[4])
		font:DrawText("Culling frozen", x, y)
		y = y + line_height
	end

	render2d.SetColor(colors.text[1], colors.text[2], colors.text[3], colors.text[4])
	font:DrawText(string.format("Submitted visuals: %d / %d", counts.submitted, counts.total), x, y)
	y = y + line_height
	render2d.SetColor(colors.culled[1], colors.culled[2], colors.culled[3], colors.culled[4])
	font:DrawText(string.format("Culled visuals: %d", counts.culled), x, y)
	y = y + line_height
	render2d.SetColor(colors.conditional[1], colors.conditional[2], colors.conditional[3], colors.conditional[4])
	font:DrawText(string.format("Occlusion-managed visuals: %d", counts.conditional), x, y)
	y = y + line_height
	render2d.SetColor(colors.muted[1], colors.muted[2], colors.muted[3], colors.muted[4])
	font:DrawText(
		string.format(
			"Submitted with conditional rendering: %d",
			occlusion_stats.submitted_with_conditional or 0
		),
		x,
		y
	)
	y = y + line_height
	render2d.SetColor(colors.muted[1], colors.muted[2], colors.muted[3], colors.muted[4])
	font:DrawText("Commands: culling_debug_panel, culling_debug_boxes, culling_debug_all", x, y)
end)

event.AddListener(
	"Draw3DGeometry",
	"culling_debug_boxes",
	function(cmd, dt)
		if not show_culling_boxes then return end

		local _, state_by_component = collect_culling_state()

		for index, component in ipairs(Visual.Instances or {}) do
			if component.Visible then
				local aabb = component:GetWorldAABB()

				if aabb and aabb.min_x ~= math.huge and aabb.min_x <= aabb.max_x then
					local state = state_by_component[component] or "culled"
					local color = colors[state]
					debug_draw.DrawWireAABB{
						id = "culling_debug_" .. tostring(index) .. "_" .. tostring(component),
						aabb = aabb,
						color = color,
						width = state == "culled" and 2 or 1,
						time = dt or 0.05,
					}
				end
			end
		end
	end,
	{priority = -100}
)
