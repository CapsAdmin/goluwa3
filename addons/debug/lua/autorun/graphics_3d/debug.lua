local event = import("goluwa/event.lua")
local commands = import("goluwa/commands.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local input = import("goluwa/input.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local vulkan_memory = import("goluwa/render/vulkan/internal/memory.lua")
local callstack = import("goluwa/helpers/callstack.lua")
local Visual = import("goluwa/ecs/components/3d/visual.lua").Library
local fonts = import("goluwa/render2d/fonts.lua")
local renderdoc = import("goluwa/bindings/renderdoc.lua")

local function format_bytes(bytes)
	bytes = math.max(0, tonumber(bytes) or 0)

	if bytes >= 1024 * 1024 * 1024 then
		return string.format("%.2f GiB", bytes / 1024 / 1024 / 1024)
	end

	if bytes >= 1024 * 1024 then
		return string.format("%.2f MiB", bytes / 1024 / 1024)
	end

	if bytes >= 1024 then return string.format("%.2f KiB", bytes / 1024) end

	return string.format("%d B", bytes)
end

local function normalize_traceback(traceback)
	traceback = tostring(traceback or "unknown traceback")
	traceback = traceback:trim()

	if traceback == "" then return "unknown traceback" end

	return traceback
end

local function trim_traceback(traceback)
	traceback = normalize_traceback(traceback)
	local lines = callstack.format(traceback)

	if not lines[1] then return traceback end

	local start_index

	for i, line in ipairs(lines) do
		if line:find("goluwa/render/vulkan/internal/buffer.lua:", nil, true) then
			start_index = i

			break
		end
	end

	if not start_index then
		for i, line in ipairs(lines) do
			if line:find("goluwa/render/vulkan/internal/image.lua:", nil, true) then
				start_index = i

				break
			end
		end
	end

	if not start_index then
		for i, line in ipairs(lines) do
			if line:find("goluwa/render/vulkan/internal/", nil, true) then
				start_index = i

				break
			end
		end
	end

	if not start_index then return traceback end

	local end_index = #lines

	for i = start_index, #lines do
		if lines[i]:find("main.lua:", nil, true) then
			end_index = i

			break
		end
	end

	local out = {}

	for i = start_index, end_index do
		list.insert(out, lines[i])

		if i ~= end_index and lines[i] == "stack traceback:" then
			list.insert(out, "")
		end
	end

	if not out[1] then return traceback end

	return table.concat(out, "\n")
end

local function indent_traceback(traceback)
	local out = {}

	for _, line in ipairs(traceback:split("\n")) do
		list.insert(out, "  " .. line)
	end

	return table.concat(out, "\n")
end

commands.Add("dump_vulkan_memory=number[20]", function(limit)
	limit = math.max(1, math.floor(tonumber(limit) or 20))
	local total_bytes = 0
	local allocation_count = 0
	local freed_count = tonumber(vulkan_memory.total_freed_count) or 0
	local freed_bytes = tonumber(vulkan_memory.total_freed_bytes) or 0
	local hotspots = {}

	for _, allocation in pairs(vulkan_memory.Instances) do
		if allocation and allocation.size then
			local size = tonumber(allocation.size) or 0
			local traceback = trim_traceback(allocation.traceback)
			local hotspot = hotspots[traceback]

			if not hotspot then
				hotspot = {
					traceback = traceback,
					count = 0,
					bytes = 0,
				}
				hotspots[traceback] = hotspot
			end

			hotspot.count = hotspot.count + 1
			hotspot.bytes = hotspot.bytes + size
			total_bytes = total_bytes + size
			allocation_count = allocation_count + 1
		end
	end

	local sorted = {}

	for _, hotspot in pairs(hotspots) do
		list.insert(sorted, hotspot)
	end

	table.sort(sorted, function(a, b)
		if a.bytes ~= b.bytes then return a.bytes > b.bytes end

		if a.count ~= b.count then return a.count > b.count end

		return a.traceback < b.traceback
	end)

	logn(
		string.format(
			"Live Vulkan memory allocations: %d objects, %s total | Freed: %d objects, %s total",
			allocation_count,
			format_bytes(total_bytes),
			freed_count,
			format_bytes(freed_bytes)
		)
	)

	if #sorted == 0 then
		logn("No live Vulkan memory allocations tracked.")
		return
	end

	logn(string.format("Top %d Vulkan memory hotspots:", math.min(limit, #sorted)))

	for i = 1, math.min(limit, #sorted) do
		local hotspot = sorted[i]
		logn(
			string.format(
				"[%d] %s across %d allocations",
				i,
				format_bytes(hotspot.bytes),
				hotspot.count
			)
		)
		logn(indent_traceback(hotspot.traceback))
	end
end)

-- Debug: Show debug info
local show_debug_info = false

-- Debug: Freeze frustum for culling
function events.Draw2D.debug_info(dt)
	if not show_debug_info then return end

	fonts.SetFont(fonts.GetDefaultFont())
	local y = 50
	local x = 10
	render2d.SetTexture(nil)
	-- Camera info
	local cam = render3d.GetCamera()
	local pos = cam:GetPosition()
	local rot = cam:GetRotation()
	render2d.SetColor(1, 1, 1, 1)
	fonts.GetFont():DrawText(string.format("Camera Pos: X=%.1f  Y=%.1f  Z=%.1f", pos.x, pos.y, pos.z), x, y)
	y = y + 20
	fonts.GetFont():DrawText(
		string.format("Camera Rot: X=%.1f  Y=%.1f  Z=%.1f W=%.1f", rot.x, rot.y, rot.z, rot.w),
		x,
		y
	)
	y = y + 20
	-- Separator
	y = y + 10
	-- Frustum culling status
	local frustum_status = Visual.noculling and "DISABLED" or "ENABLED"
	local frustum_color = Visual.noculling and {1.0, 0.2, 0.2} or {0.2, 1.0, 0.2}
	render2d.SetColor(frustum_color[1], frustum_color[2], frustum_color[3], 1)
	fonts.GetFont():DrawText(string.format("Frustum Culling: %s", frustum_status), x, y)
	y = y + 20

	-- Freeze culling status
	if Visual.freeze_culling then
		render2d.SetColor(1, 1, 0, 1)
		fonts.GetFont():DrawText("CULLING FROZEN (Press F to unfreeze)", x, y)
		y = y + 20
		render2d.SetColor(0.8, 0.8, 0.5, 1)
		fonts.GetFont():DrawText("  (Occlusion queries not updating)", x, y)
		y = y + 20
	end

	-- Separator
	y = y + 10
	-- Occlusion culling info
	local stats = Visual.GetOcclusionStats()
	render2d.SetColor(1, 1, 1, 1)
	fonts.GetFont():DrawText(
		string.format("Models: %d total, %d with occlusion", stats.total, stats.with_occlusion),
		x,
		y
	)
	y = y + 20
	-- Frustum culling results
	local visible_after_frustum = stats.total - stats.frustum_culled
	render2d.SetColor(0.7, 0.7, 0.7, 1)
	fonts.GetFont():DrawText(
		string.format("  Frustum culled: %d (%d visible)", stats.frustum_culled, visible_after_frustum),
		x,
		y
	)
	y = y + 20
	local occlusion_status = stats.occlusion_enabled and "ENABLED" or "DISABLED"
	local occlusion_color = stats.occlusion_enabled and {0.2, 1.0, 0.2} or {1.0, 0.2, 0.2}
	render2d.SetColor(occlusion_color[1], occlusion_color[2], occlusion_color[3], 1)
	y = y + 20

	if stats.occlusion_enabled then
		render2d.SetColor(0.7, 0.7, 0.7, 1)
		fonts.GetFont():DrawText(
			string.format("  Conditional rendering: %d visuals", stats.submitted_with_conditional),
			x,
			y
		)
		y = y + 20
		render2d.SetColor(1, 1, 0.5, 1)
		fonts.GetFont():DrawText("  (GPU decides actual visibility)", x, y)
		y = y + 20
	end
end

function events.KeyInput.toggle_debug_info(key, press)
	if not press then return end

	if key == "f10" then
		show_debug_info = not show_debug_info
		print("Debug info: " .. (show_debug_info and "ON" or "OFF"))
	end
end

-- Debug: Draw shadow map as picture-in-picture
local show_shadow_map = false
-- Cascade colors for reference (matching shader)
local cascade_colors = {
	{1.0, 0.2, 0.2, 1.0}, -- Red for cascade 1
	{0.2, 1.0, 0.2, 1.0}, -- Green for cascade 2
	{0.2, 0.2, 1.0, 1.0}, -- Blue for cascade 3
	{1.0, 1.0, 0.2, 1.0}, -- Yellow for cascade 4
}

function events.Draw2D.debug_shadow_map(cmd, dt)
	if not show_shadow_map then return end

	local sun = render3d.GetLights()[1]

	if not sun or not sun:GetCastShadows() then return end

	local shadow_map = sun:GetShadowMap()

	if not shadow_map then return end

	-- Draw all cascade shadow maps
	local cascade_count = shadow_map:GetCascadeCount()
	local cascade_splits = shadow_map:GetCascadeSplits()
	local cascade_draw_calls = Visual.GetShadowDrawCallStats(shadow_map) or {}
	local size = 200
	local margin = 10
	local spacing = 10
	local panel_padding = 8

	for i = 1, cascade_count do
		local depth_texture = shadow_map:GetDepthTexture(i)

		if depth_texture then
			local x = margin + (i - 1) * (size + spacing)
			local y = margin
			local color = cascade_colors[i] or {1, 1, 0, 1}
			local tex_size = depth_texture:GetSize()
			local resolution = string.format("%dx%d", tex_size.x, tex_size.y)
			local split_dist = cascade_splits[i] and string.format("%.1f", cascade_splits[i]) or "?"
			local draw_calls = cascade_draw_calls[i] or 0
			-- Dark backdrop so far-clear depth does not look like a missing cascade.
			render2d.SetTexture(nil)
			render2d.SetColor(0.06, 0.07, 0.09, 0.92)
			gfx.DrawRoundedRect(x - panel_padding, y - panel_padding, size + panel_padding * 2, size + 64, 8)
			-- Draw the raw depth preview tinted with the cascade color for quick association
			-- with the in-scene cascade debug colors.
			render2d.SetTexture(depth_texture)
			render2d.SetColor(color[1], color[2], color[3], 1)
			render2d.DrawRect(x, y, size, size)
			render2d.SetTexture(nil)
			render2d.SetColor(color[1], color[2], color[3], 1)
			gfx.DrawOutlinedRect(x - 1, y - 1, size + 2, size + 2, 2, 0)
			-- Draw label with cascade info (use same color as 3D visualization)
			render2d.SetTexture(nil)
			render2d.SetColor(color[1], color[2], color[3], 1)
			fonts.GetFont():DrawText("Cascade " .. i .. " (z<" .. split_dist .. ")", x, y + size + 5)
			render2d.SetColor(0.85, 0.88, 0.92, 1)
			fonts.GetFont():DrawText("raw depth  " .. resolution, x, y + size + 23)
			fonts.GetFont():DrawText("draw calls  " .. draw_calls, x, y + size + 41)
		end
	end
end

-- Debug: Draw SSR buffer
local show_ssr_buffer = false

function events.Draw2D.debug_ssr_buffer(cmd, dt)
	if not show_ssr_buffer then return end

	if not render3d.ssr_fb then return end

	local tex = render3d.ssr_fb:GetAttachment(1)

	if not tex then return end

	local size = 400
	local margin = 10
	local x = window:GetSize().x - size - margin
	local y = margin
	render2d.SetTexture(tex)
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(x, y, size, size)
	render2d.SetTexture(nil)
	render2d.SetColor(1, 1, 1, 1)
	fonts.GetFont():DrawText("SSR Buffer (Half-Res)", x, y + size + 5)
end

function events.KeyInput.render3d_debug(key, press)
	if not press then return end

	if renderdoc.IsInitialized() then
		if key == "f8" then
			renderdoc.CaptureFrame(render.GetRenderDocDevicePointer(), system.GetWindow())
			print("RenderDoc capture queued")
		end

		if key == "f9" then
			local renderdoc_device = render.GetRenderDocDevicePointer()
			local renderdoc_window = system.GetWindow()

			if renderdoc.IsCapturing() then
				local stopped = renderdoc.StopCapture(renderdoc_device, renderdoc_window)
				print(stopped and "RenderDoc capture stopped" or "RenderDoc capture stop failed")
			else
				renderdoc.StartCapture(renderdoc_device, renderdoc_window)
				print("RenderDoc capture started")
			end
		end

		if key == "f11" then
			local last_capture = renderdoc.GetLastCapture()

			if last_capture and last_capture.filename then
				renderdoc.OpenUI(last_capture.filename)
			else
				renderdoc.OpenUI()
			end
		end

		return
	end

	-- Toggle shadow map debug view
	if key == "f9" then
		show_shadow_map = not show_shadow_map
		-- Also toggle cascade color visualization in the shader
		render3d.SetDebugCascadeColors(show_shadow_map)
		print("Shadow map debug: " .. (show_shadow_map and "ON" or "OFF"))
	end

	-- Toggle SSR buffer debug view
	if key == "f7" then
		show_ssr_buffer = not show_ssr_buffer
		print("SSR buffer debug: " .. (show_ssr_buffer and "ON" or "OFF"))
	end

	-- Toggle frustum culling
	if key == "f8" then
		Model.noculling = not Model.noculling
		print("Frustum culling: " .. (Model.noculling and "DISABLED" or "ENABLED"))
	end

	-- Toggle occlusion culling
	if key == "f6" then
		Model.SetOcclusionCulling(not Model.IsOcclusionCullingEnabled())
		print(
			"Occlusion culling: " .. (
					Model.IsOcclusionCullingEnabled() and
					"ENABLED" or
					"DISABLED"
				)
		)
	end

	-- Toggle freeze frustum
	if key == "f" then render3d.freeze_culling = not render3d.freeze_culling end

	-- Toggle debug modes
	if key == "h" then print("Debug mode: " .. render3d.CycleDebugMode()) end
end
