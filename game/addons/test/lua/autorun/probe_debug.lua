-- Reflection Probe Debug Visualization
-- Shows probe cubemap faces and debug information
local event = require("event")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local render3d = require("render3d.render3d")
local window = require("render.window")
local probe_debug = {}
probe_debug.enabled = false
probe_debug.show_faces = true
probe_debug.show_info = true
probe_debug.face_size = 128
probe_debug.position = {x = 10, y = 10}
probe_debug.current_probe_index = 0

-- Toggle with F9 key, cycle with F10
event.AddListener("KeyInput", "probe_debug_toggle", function(key, press)
	if not press then return end

	if key == "f5" then
		probe_debug.enabled = not probe_debug.enabled
		print("[Probe Debug] " .. (probe_debug.enabled and "Enabled" or "Disabled"))
	elseif key == "f10" and probe_debug.enabled then
		local probes = reflection_probe.GetProbes()
		local count = 0

		for k, v in pairs(probes) do
			count = math.max(count, k)
		end

		probe_debug.current_probe_index = (probe_debug.current_probe_index + 1) % (count + 1)
		print("[Probe Debug] Switched to probe " .. probe_debug.current_probe_index)
	end
end)

local function draw_cubemap_faces(cubemap, x, y, size, label)
	if not cubemap then return y end

	local face_names = {"+X", "-X", "+Y", "-Y", "+Z", "-Z"}
	-- Draw label
	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText(label, x, y)
	y = y + 20
	-- Draw 6 faces in a row
	-- We need to sample from the cubemap using direction vectors
	-- Since we can't easily extract individual faces, we'll draw using the cubemap sampler
	-- For now, just draw the cubemap as environment reflection preview
	render2d.SetTexture(cubemap)

	-- Draw a simple preview - this shows the cubemap but not individual faces
	-- Individual face extraction would require a special shader
	for i = 0, 5 do
		local face_x = x + i * (size + 5)
		-- Draw face background
		render2d.SetColor(0.2, 0.2, 0.2, 1)
		render2d.SetTexture()
		render2d.DrawRect(face_x, y, size, size)
		-- Draw face label
		render2d.SetColor(1, 1, 1, 0.8)
		gfx.DrawText(face_names[i + 1], face_x + 2, y + 2)
	end

	-- Draw the cubemap as a cross/T layout preview
	-- This is a common way to visualize cubemaps
	local preview_size = size * 0.8
	local cross_x = x
	local cross_y = y + size + 30
	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText("Cubemap Preview (requires shader for proper display)", cross_x, cross_y)
	return y + size + 50
end

local function draw_debug_info(reflection_probe, x, y)
	local line_height = 18
	local start_y = y
	render2d.SetColor(0, 0, 0, 0.7)
	render2d.SetTexture()
	render2d.DrawRect(x - 5, y - 5, 350, 200)
	render2d.SetColor(1, 1, 0, 1)
	gfx.DrawText("=== Reflection Probe Debug (F9 to toggle) ===", x, y)
	y = y + line_height * 1.5
	render2d.SetColor(1, 1, 1, 1)
	-- Status
	local status = reflection_probe.IsEnabled() and "ENABLED" or "DISABLED"
	local status_color = reflection_probe.IsEnabled() and {0, 1, 0} or {1, 0, 0}
	gfx.DrawText("Status: ", x, y)
	render2d.SetColor(status_color[1], status_color[2], status_color[3], 1)
	gfx.DrawText(status, x + 60, y)
	y = y + line_height
	render2d.SetColor(1, 1, 1, 1)
	-- Cubemap info
	local idx = probe_debug.current_probe_index
	local cubemap = reflection_probe.GetCubemap(idx)
	local source = reflection_probe.GetSourceCubemap(idx)
	gfx.DrawText(string.format("Probe Index: %d", idx), x, y)
	y = y + line_height
	gfx.DrawText(
		string.format("Resolution: %dx%d", reflection_probe.SCENE_SIZE, reflection_probe.SCENE_SIZE),
		x,
		y
	)
	y = y + line_height
	gfx.DrawText(string.format("Total Scene Probes: %d", reflection_probe.SCENE_PROBE_COUNT), x, y)
	y = y + line_height
	-- Probe position
	local pos = reflection_probe.GetProbePosition(idx)

	if pos then
		gfx.DrawText(string.format("Position: %.1f, %.1f, %.1f", pos.x, pos.y, pos.z), x, y)
	else
		gfx.DrawText("Position: N/A", x, y)
	end

	y = y + line_height
	-- Texture status
	gfx.DrawText(string.format("Output Cubemap: %s", cubemap and "OK" or "NULL"), x, y)
	y = y + line_height
	gfx.DrawText(string.format("Source Cubemap: %s", source and "OK" or "NULL"), x, y)
	y = y + line_height
	-- Pipeline status
	gfx.DrawText(
		string.format("Scene Pipeline: %s", reflection_probe.scene_pipeline and "OK" or "NULL"),
		x,
		y
	)
	y = y + line_height
	gfx.DrawText(
		string.format("Sky Pipeline: %s", reflection_probe.sky_pipeline and "OK" or "NULL"),
		x,
		y
	)
	y = y + line_height
	-- Debug mode hint
	local debug_mode = render3d.GetDebugModeName()
	gfx.DrawText(string.format("Render Debug Mode: %s", debug_mode), x, y)
	y = y + line_height
	render2d.SetColor(0.7, 0.7, 0.7, 1)
	gfx.DrawText("(Cycle with debug key, 'probe' mode = 7)", x, y)
	y = y + line_height
	return y + 10
end

-- Draw cubemap preview using a simple unwrap
local function draw_cubemap_preview(cubemap, x, y, face_size)
	if not cubemap then
		render2d.SetColor(1, 0, 0, 1)
		gfx.DrawText("No cubemap available", x, y)
		return y + 20
	end

	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText("Cubemap exists (cannot preview cubemap as 2D directly)", x, y)
	y = y + 20
	-- Draw a placeholder showing the cubemap exists
	render2d.SetColor(0.3, 0.5, 0.3, 1)
	render2d.SetTexture()
	render2d.DrawRect(x, y, face_size * 2, face_size)
	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText("Cubemap OK", x + 10, y + face_size / 2 - 10)
	return y + face_size + 10
end

-- Draw individual face views if available
local function draw_face_previews(reflection_probe, x, y, face_size)
	local face_views = reflection_probe.source_face_views

	if not face_views or not face_views[0] then
		render2d.SetColor(1, 0.5, 0, 1)
		gfx.DrawText("Face views not available", x, y)
		return y + 20
	end

	local face_names = {"+X", "-X", "+Y", "-Y", "+Z", "-Z"}
	render2d.SetColor(1, 1, 1, 1)
	gfx.DrawText("Source Face Views:", x, y)
	y = y + 20

	-- Draw 6 faces in a 3x2 grid
	for i = 0, 5 do
		local col = i % 3
		local row = math.floor(i / 3)
		local face_x = x + col * (face_size + 5)
		local face_y = y + row * (face_size + 20)
		-- Draw face label
		render2d.SetColor(1, 1, 1, 0.8)
		render2d.SetTexture()
		gfx.DrawText(face_names[i + 1], face_x, face_y)
		-- Draw face (the view is an ImageView, we need a Texture to draw it)
		-- For now just draw a placeholder
		render2d.SetColor(0.2, 0.2, 0.4, 1)
		render2d.DrawRect(face_x, face_y + 15, face_size, face_size)
	end

	return y + 2 * (face_size + 20) + 10
end

event.AddListener("Draw2D", "probe_debug_draw", function(dt)
	if not probe_debug.enabled then return end

	-- Try to get the reflection probe module
	local ok, reflection_probe = pcall(require, "render3d.reflection_probe")

	if not ok then
		render2d.SetColor(1, 0, 0, 1)
		gfx.DrawText("Failed to load reflection_probe module: " .. tostring(reflection_probe), 10, 10)
		return
	end

	local x = probe_debug.position.x
	local y = probe_debug.position.y
	-- Draw debug info panel
	y = draw_debug_info(reflection_probe, x, y)

	-- Draw cubemap previews
	if probe_debug.show_faces then
		y = y + 10
		-- Draw face previews
		y = draw_face_previews(reflection_probe, x, y, probe_debug.face_size)
		y = y + 10
		-- Source cubemap status
		render2d.SetColor(1, 1, 1, 1)
		gfx.DrawText("Source Cubemap:", x, y)
		y = y + 20
		y = draw_cubemap_preview(reflection_probe.GetSourceCubemap(idx), x, y, probe_debug.face_size)
		y = y + 10
		-- Output cubemap status
		render2d.SetColor(1, 1, 1, 1)
		gfx.DrawText("Output Cubemap (prefiltered):", x, y)
		y = y + 20
		y = draw_cubemap_preview(reflection_probe.GetCubemap(idx), x, y, probe_debug.face_size)
	end
end)

-- Public API
function probe_debug.Enable()
	probe_debug.enabled = true
end

function probe_debug.Disable()
	probe_debug.enabled = false
end

function probe_debug.Toggle()
	probe_debug.enabled = not probe_debug.enabled
end

function probe_debug.IsEnabled()
	return probe_debug.enabled
end

function probe_debug.SetFaceSize(size)
	probe_debug.face_size = size
end

function probe_debug.SetPosition(x, y)
	probe_debug.position.x = x
	probe_debug.position.y = y
end

-- Auto-load reflection probe when this module is loaded
event.AddListener("Render3DInitialized", "probe_debug_init", function()
	-- Make sure reflection probe is loaded
	local ok, err = pcall(require, "render3d.reflection_probe")

	if not ok then
		print("[Probe Debug] Warning: Could not load reflection_probe: " .. tostring(err))
	else
		print("[Probe Debug] Reflection probe module loaded successfully")
	end
end)
