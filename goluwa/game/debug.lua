local event = require("event")
local render = require("graphics.render")
local system = require("system")
local jit_profiler = require("helpers.jit_profiler")
local jit_trace_track = require("helpers.jit_trace_track")
local profile_stop, profile_report
local trace_stop, trace_report
local timer = require("timer")
local input = require("input")
local render2d = require("graphics.render2d")
local gfx = require("graphics.gfx")
local render3d = require("graphics.render3d")
-- Debug: Draw shadow map as picture-in-picture
local show_shadow_map = true

event.AddListener("Draw2D", "debug_shadow_map", function(cmd, dt)
	if not show_shadow_map then return end

	local sun = render3d.GetSunLight()

	if not sun or not sun:HasShadows() then return end

	local shadow_map = sun:GetShadowMap()

	if not shadow_map then return end

	local depth_texture = shadow_map:GetDepthTexture()

	if not depth_texture then return end

	-- Draw in bottom-left corner, 256x256 pixels
	local size = 256
	local margin = 10
	-- Draw shadow map depth texture
	render2d.SetTexture(depth_texture)
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(margin, margin, size, size)
	-- Draw label
	render2d.SetTexture(nil)
	render2d.SetColor(1, 1, 0, 1)
	gfx.DrawText("Shadow Map", margin, margin + size + 5)
end)

event.AddListener("KeyInput", "renderdoc", function(key, press)
	if not press then return end

	--if key == "f8" then render.renderdoc.CaptureFrame() end
	if key == "f11" then render.renderdoc.OpenUI() end

	-- Toggle shadow map debug view
	if key == "f9" then
		show_shadow_map = not show_shadow_map
		print("Shadow map debug: " .. (show_shadow_map and "ON" or "OFF"))
	end

	if key == "t" then
		if not trace_stop then
			trace_stop, trace_report = jit_trace_track.Start()
		else
			trace_stop()
			trace_stop = nil
		end
	end

	if key == "p" then
		if not profile_stop then
			profile_stop, profile_report = jit_profiler.Start()
		else
			profile_stop()
			profile_stop = nil
		end
	end

	if key == "c" and input.IsKeyDown("left_control") then system.ShutDown(0) end
end)

timer.Repeat(
	"debug",
	0.5,
	math.huge,
	function()
		if trace_report then
			print(jit_trace_track.ToStringProblematicTraces(trace_report()))
		end

		if profile_report then print(profile_report()) end
	end
)
