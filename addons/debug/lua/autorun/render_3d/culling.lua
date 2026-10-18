local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Color = import("goluwa/structs/color.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local visual_module = import("goluwa/entities/components/visual.lua")
local visual = import("goluwa/entities/components/visual.lua").Library
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local perf = import("lua/perf.lua")

do
	local Visual = visual_module
	local visual = visual_module.Library
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

	local function set_boxes_enabled(enabled)
		show_culling_boxes = enabled == true
		print("[Culling Debug] Boxes " .. (show_culling_boxes and "ON" or "OFF"))
	end

	local function get_occlusion_mode_label()
		if not visual.IsOcclusionCullingEnabled() then return "disabled" end

		return tostring(gpu_culling.GetOcclusionMode())
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
		local gpu = scene_draw.debug_result

		-- with r_scene_draw_debug on, what the gpu drew about a second ago, otherwise what the cpu would
		if gpu then
			for _, component in ipairs(Visual.Instances or {}) do
				for _, item in ipairs(component.scene_instances or {}) do
					if gpu.opaque.by_id[item.id] or gpu.translucent.by_id[item.id] then
						visible_lookup[component] = true

						break
					end
				end
			end
		else
			for _, component in ipairs(visual.GetVisibleVisuals()) do
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

	commands.Add("culling_debug_boxes", function()
		set_boxes_enabled(not show_culling_boxes)
	end)

	local function build_rows()
	local counts = collect_culling_state()
	local occlusion_stats = visual.GetOcclusionStats()
	local rows = {
		{
			label = "frustum",
			value = (visual.noculling or not gpu_culling.culling_enabled) and "disabled" or "enabled",
		},
		{
			label = "occlusion",
			value = string.format(
				"%s (%s)",
				visual.IsOcclusionCullingEnabled() and "enabled" or "disabled",
				get_occlusion_mode_label()
			),
		},
	}

	if visual.freeze_frustum_planes then
		rows[#rows + 1] = {label = "frustum planes frozen", color = "warn"}
	end

	rows[#rows + 1] = {
		label = "decided by",
		value = scene_draw.debug_result and "the gpu (r_scene_draw_debug)" or "the cpu (set r_scene_draw_debug to see the gpu's)",
		color = scene_draw.debug_result and nil or "dim",
	}
	rows[#rows + 1] = {label = "submitted visuals", value = counts.submitted .. " / " .. counts.total}
	rows[#rows + 1] = {label = "culled visuals", value = tostring(counts.culled), color = "warn"}
	rows[#rows + 1] = {label = "occlusion managed visuals", value = tostring(counts.conditional)}
	rows[#rows + 1] = {
		label = "submitted with conditional rendering",
		value = tostring(occlusion_stats.submitted_with_conditional or 0),
		color = "dim",
	}
		return rows
	end

	perf.RegisterTab(
		"CULLING",
		5,
		react.Component(|| -> ui.StatTable{Size = Vec2(660, 470), Rows = react.UsePoll(build_rows, perf.POLL_INTERVAL)})
	)

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
end
