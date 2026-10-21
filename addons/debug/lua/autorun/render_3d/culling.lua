local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Color = import("goluwa/structs/color.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local scene_bridge = import("goluwa/render3d/scene/bridge.lua")
local scene_meshes = import("goluwa/render3d/scene/meshes.lua")
local scene_visibility = import("goluwa/render3d/scene/visibility.lua")
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

commands.Add("scene_draw_dump", function(count)
	count = tonumber(count) or 40
	local camera = render3d.GetCamera():GetPosition()
	local view_projection = render3d.GetCamera():BuildViewMatrix() * render3d.GetCamera():BuildProjectionMatrix()
	local by_id = {}

	for _, component in ipairs(visual_module.Instances or {}) do
		for _, item in ipairs(component.scene_instances or {}) do
			by_id[item.id] = {component = component, item = item}

		end
	end

	local lines = {}
	local totals = {opaque = 0, translucent = 0, contains_camera = 0, no_occlusion = 0, unknown = 0}

	for kind, name in ipairs{"opaque", "translucent"} do
		local result = scene_draw.ReadBackCull(kind - 1)

		for id in pairs(result.by_id) do
			local owner = by_id[id]
			totals[name] = totals[name] + 1

			if not owner then
				totals.unknown = totals.unknown + 1
			else
				local component = owner.component
				local box = scene_bridge.GetEntryBox(owner.item.entry, owner.item.matrix) or component:GetWorldAABB()
				local contains = box and
					camera.x >= box.min_x and
					camera.x <= box.max_x and
					camera.y >= box.min_y and
					camera.y <= box.max_y and
					camera.z >= box.min_z and
					camera.z <= box.max_z
				local size = box and
					math.max(box.max_x - box.min_x, box.max_y - box.min_y, box.max_z - box.min_z) or
					0

				local behind_eye = false

				if box and not contains then
					local m = view_projection

					for i = 0, 7 do
						local x = bit.band(i, 1) ~= 0 and box.max_x or box.min_x
						local y = bit.band(i, 2) ~= 0 and box.max_y or box.min_y
						local z = bit.band(i, 4) ~= 0 and box.max_z or box.min_z

						if m.m03 * x + m.m13 * y + m.m23 * z + m.m33 <= 0 then
							behind_eye = true

							break
						end
					end
				end

				if behind_eye then totals.reaches_behind_eye = (totals.reaches_behind_eye or 0) + 1 end

				if contains then totals.contains_camera = totals.contains_camera + 1 end

				if not component.UseOcclusionCulling then
					totals.no_occlusion = totals.no_occlusion + 1
				end

				lines[#lines + 1] = {
					size = size,
					text = string.format(
						"%-11s %-32s level %d  tris %6d  size %7.1f%s%s",
						name,
						tostring(component.Owner and component.Owner.Name or "?"):sub(1, 32),
						owner.item.level or 0,
						(scene_meshes.GetRecord(owner.item.mesh_row) or {}).triangle_count or 0,
						size,
						contains and "  holds the camera" or (behind_eye and "  reaches behind the eye" or ""),
						component.UseOcclusionCulling and "" or "  no occlusion test"
					),
				}
			end
		end
	end

	table.sort(lines, function(a, b)
		return a.size > b.size
	end)

	print(
		string.format(
			"[scene_draw_dump] %d opaque and %d translucent rows drawn, %d hold the camera, %d more reach behind the eye, %d are not occlusion tested, %d unknown",
			totals.opaque,
			totals.translucent,
			totals.contains_camera,
			totals.reaches_behind_eye or 0,
			totals.no_occlusion,
			totals.unknown
		)
	)

	for i = 1, math.min(#lines, count) do
		print("[scene_draw_dump] " .. lines[i].text)
	end
end)

commands.Add("scene_draw_visibility", function(rays)
	local result = scene_visibility.Estimate(tonumber(rays) or 128)
	local by_id = {}

	for _, component in ipairs(visual_module.Instances or {}) do
		for _, item in ipairs(component.scene_instances or {}) do
			by_id[item.id] = {component = component, item = item}
		end
	end

	local unseen = {}
	local not_measurable = 0

	for id, entry in pairs(result.by_id) do
		if entry.self == 0 then
			if entry.solid then
				local owner = by_id[id]
				local box = owner and scene_bridge.GetEntryBox(owner.item.entry, owner.item.matrix)
				local size = box and
					math.max(box.max_x - box.min_x, box.max_y - box.min_y, box.max_z - box.min_z) or
					0
				unseen[#unseen + 1] = {
					size = size,
					text = string.format(
						"%-32s size %7.1f  %d rays: %d hit another row, %d hit nothing",
						tostring(owner and owner.component.Owner and owner.component.Owner.Name or "?"):sub(1, 32),
						size,
						entry.samples,
						entry.other,
						entry.sky
					),
				}
			else
				not_measurable = not_measurable + 1
			end
		end
	end

	table.sort(unseen, function(a, b)
		return a.size > b.size
	end)

	print(
		string.format(
			"[scene_draw_visibility] %d rows drawn, %d seen by a ray, %d not seen (%d of them cannot be told: not in the ray traced scene or not solid)",
			result.drawn,
			result.seen,
			result.unseen,
			not_measurable
		)
	)

	for i = 1, math.min(#unseen, 30) do
		print("[scene_draw_visibility] not seen: " .. unseen[i].text)
	end
end)
