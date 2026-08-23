local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Color = import("goluwa/structs/color.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local visual_module = import("goluwa/entities/components/visual.lua")
local Visual = visual_module
local visual = visual_module.Library
local show_culling_panel = false
local show_culling_boxes = false
local colors = {
	visible = Color(0.25, 0.95, 0.35, 0.9),
	conditional = Color(1.0, 0.82, 0.22, 0.95),
	culled = Color(1.0, 0.28, 0.24, 0.95),
	text = Color(0.92, 0.95, 1.0, 1.0),
	muted = Color(0.62, 0.69, 0.78, 1.0),
	accent = Color(0.50, 0.82, 1.0, 1.0),
	warning = Color(1.0, 0.9, 0.35, 1.0),
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

	local x = 12
	local y = 52
	local line_height = 18
	local counts = select(1, collect_culling_state())
	local occlusion_stats = visual.GetOcclusionStats()
	local panel_width = 360
	local panel_height = 186
	render2d.SetTexture(nil)
	render2d.SetColor(0.05, 0.07, 0.10, 0.93)
	render2d.DrawRoundedRect(x - 8, y - 10, panel_width, panel_height, 10)
	render2d.DrawText{
		text = "Culling Debug",
		x = x,
		y = y,
		foreground_color = colors.text,
		softness = 0,
	}
	y = y + line_height
	render2d.DrawText{
		text = string.format("Frustum: %s", visual.noculling and "disabled" or "enabled"),
		x = x,
		y = y,
		foreground_color = colors.accent,
	}
	y = y + line_height
	render2d.DrawText{
		text = string.format(
			"Occlusion: %s (%s)",
			visual.IsOcclusionCullingEnabled() and "enabled" or "disabled",
			get_occlusion_mode_label()
		),
		x = x,
		y = y,
		foreground_color = colors.accent,
	}
	y = y + line_height

	if visual.freeze_frustum_planes then
		render2d.DrawText{
			text = "Frustum planes frozen",
			x = x,
			y = y,
			foreground_color = colors.warning,
		}
		y = y + line_height
	end

	render2d.DrawText{
		text = string.format("Submitted visuals: %d / %d", counts.submitted, counts.total),
		x = x,
		y = y,
		foreground_color = colors.text,
	}
	y = y + line_height
	render2d.DrawText{
		text = string.format("Culled visuals: %d", counts.culled),
		x = x,
		y = y,
		foreground_color = colors.culled,
	}
	y = y + line_height
	render2d.DrawText{
		text = string.format("Occlusion-managed visuals: %d", counts.conditional),
		x = x,
		y = y,
		foreground_color = colors.conditional,
	}
	y = y + line_height
	render2d.DrawText{
		text = string.format(
			"Submitted with conditional rendering: %d",
			occlusion_stats.submitted_with_conditional or 0
		),
		x = x,
		y = y,
		foreground_color = colors.muted,
	}
	y = y + line_height
	render2d.DrawText{
		text = "Commands: culling_debug_panel, culling_debug_boxes, culling_debug_all",
		x = x,
		y = y,
		foreground_color = colors.muted,
	}
end)

event.AddListener(
	"Draw3DGeometry",
	"culling_debug_boxes",
	function(cmd, dt)
		if not show_culling_boxes then return end

		local _, state_by_component = collect_culling_state()

		for index, component in ipairs(Visual.Instances) do
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
					}
				end
			end
		end
	end,
	{priority = -100}
)

event.AddListener("KeyInput", "culling_debug", function(key, press)
	if not press then return end

	if key == "f" then
		visual.freeze_frustum_planes = not visual.freeze_frustum_planes
		print("frustum planes frozen = ", visual.freeze_frustum_planes)
	end
end)
