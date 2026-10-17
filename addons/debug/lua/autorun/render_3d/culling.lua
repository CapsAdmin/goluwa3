local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Color = import("goluwa/structs/color.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
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

commands.Add("dump_main_gpu_culling_stats", function()
	local stats = visual.GetMainGPUCullingStats()
	local instancing = gbuffer_instancing.GetStats()

	if not stats.frame then
		print("[main_gpu_culling_stats] no stats recorded yet")
		return
	end

	local gpu_entries_per_draw = stats.gpu_packed_draw_calls > 0 and
		stats.gpu_packed_entry_count / stats.gpu_packed_draw_calls or
		0
	print(
		string.format(
			"[main_gpu_culling_stats] frame=%d instancing_frame=%d",
			stats.frame,
			instancing.frame
		)
	)
	print(
		string.format(
			"[main_gpu_culling_stats] visible=%d gpu_packed_entries=%d gpu_packed_draws=%d gpu_active_batches=%d/%d gpu_entries_per_draw=%.2f fallback_visible=%d fallback_submitted=%d cpu_instanced_draws=%d cpu_singleton_draws=%d queued_instances=%d",
			stats.visible_entry_count or 0,
			stats.gpu_packed_entry_count or 0,
			stats.gpu_packed_draw_calls or 0,
			stats.gpu_active_batch_count or 0,
			stats.gpu_total_batch_count or 0,
			gpu_entries_per_draw,
			stats.fallback_visible_entry_count or 0,
			stats.fallback_submitted_entry_count or 0,
			instancing.instanced_draws,
			instancing.singleton_draws,
			instancing.queued_instances
		)
	)
end)

commands.Add("dump_shadow_gpu_culling_stats", function()
	local stats = visual.GetAllShadowGPUCullingStats()
	local rows = {}

	for shadow_map, map_stats in pairs(stats) do
		for cascade_idx, cascade_stats in pairs(map_stats.cascades or {}) do
			rows[#rows + 1] = {
				shadow_map = shadow_map,
				cascade_idx = cascade_idx,
				frame = cascade_stats.frame or 0,
				visible_entry_count = cascade_stats.visible_entry_count or 0,
				fallback_visible_entry_count = cascade_stats.fallback_visible_entry_count or 0,
				gpu_packed_entry_count = cascade_stats.gpu_packed_entry_count or 0,
				gpu_packed_draw_calls = cascade_stats.gpu_packed_draw_calls or 0,
				gpu_active_batch_count = cascade_stats.gpu_active_batch_count or 0,
				gpu_total_batch_count = cascade_stats.gpu_total_batch_count or 0,
				fallback_submitted_entry_count = cascade_stats.fallback_submitted_entry_count or 0,
				fallback_instanced_draw_calls = cascade_stats.fallback_instanced_draw_calls or 0,
				fallback_singleton_draw_calls = cascade_stats.fallback_singleton_draw_calls or 0,
				fallback_missing_world_matrix_count = cascade_stats.fallback_missing_world_matrix_count or 0,
			}
		end
	end

	if not rows[1] then
		print("[shadow_gpu_culling_stats] no stats recorded yet")
		return
	end

	table.sort(rows, function(a, b)
		if a.frame ~= b.frame then return a.frame > b.frame end

		if a.cascade_idx ~= b.cascade_idx then return a.cascade_idx < b.cascade_idx end

		return tostring(a.shadow_map) < tostring(b.shadow_map)
	end)

	local latest_frame = rows[1].frame
	local total_visible = 0
	local total_fallback_visible = 0
	local total_gpu_packed = 0
	local total_gpu_draw_calls = 0
	local total_gpu_active_batches = 0
	local total_gpu_total_batches = 0
	local total_fallback_submitted = 0
	local total_fallback_instanced_draw_calls = 0
	local total_fallback_singleton_draw_calls = 0
	local total_missing_world_matrix = 0
	print(string.format("[shadow_gpu_culling_stats] frame=%d", latest_frame))

	for _, row in ipairs(rows) do
		if row.frame == latest_frame then
			total_visible = total_visible + row.visible_entry_count
			total_fallback_visible = total_fallback_visible + row.fallback_visible_entry_count
			total_gpu_packed = total_gpu_packed + row.gpu_packed_entry_count
			total_gpu_draw_calls = total_gpu_draw_calls + row.gpu_packed_draw_calls
			total_gpu_active_batches = total_gpu_active_batches + row.gpu_active_batch_count
			total_gpu_total_batches = total_gpu_total_batches + row.gpu_total_batch_count
			total_fallback_submitted = total_fallback_submitted + row.fallback_submitted_entry_count
			total_fallback_instanced_draw_calls = total_fallback_instanced_draw_calls + row.fallback_instanced_draw_calls
			total_fallback_singleton_draw_calls = total_fallback_singleton_draw_calls + row.fallback_singleton_draw_calls
			total_missing_world_matrix = total_missing_world_matrix + row.fallback_missing_world_matrix_count
			local gpu_entries_per_draw = row.gpu_packed_draw_calls > 0 and
				row.gpu_packed_entry_count / row.gpu_packed_draw_calls or
				0
			print(
				string.format(
					"[shadow_gpu_culling_stats] map=%s cascade=%d visible=%d gpu_packed_entries=%d gpu_packed_draws=%d gpu_active_batches=%d/%d gpu_entries_per_draw=%.2f fallback_visible=%d fallback_submitted=%d fallback_instanced_draws=%d fallback_singleton_draws=%d missing_world_matrix=%d",
					tostring(row.shadow_map),
					row.cascade_idx,
					row.visible_entry_count,
					row.gpu_packed_entry_count,
					row.gpu_packed_draw_calls,
					row.gpu_active_batch_count,
					row.gpu_total_batch_count,
					gpu_entries_per_draw,
					row.fallback_visible_entry_count,
					row.fallback_submitted_entry_count,
					row.fallback_instanced_draw_calls,
					row.fallback_singleton_draw_calls,
					row.fallback_missing_world_matrix_count
				)
			)
		end
	end

	local total_gpu_entries_per_draw = total_gpu_draw_calls > 0 and total_gpu_packed / total_gpu_draw_calls or 0
	print(
		string.format(
			"[shadow_gpu_culling_stats] total visible=%d gpu_packed_entries=%d gpu_packed_draws=%d gpu_active_batches=%d/%d gpu_entries_per_draw=%.2f fallback_visible=%d fallback_submitted=%d fallback_instanced_draws=%d fallback_singleton_draws=%d missing_world_matrix=%d",
			total_visible,
			total_gpu_packed,
			total_gpu_draw_calls,
			total_gpu_active_batches,
			total_gpu_total_batches,
			total_gpu_entries_per_draw,
			total_fallback_visible,
			total_fallback_submitted,
			total_fallback_instanced_draw_calls,
			total_fallback_singleton_draw_calls,
			total_missing_world_matrix
		)
	)
end)
