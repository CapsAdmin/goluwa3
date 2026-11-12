if not CLIENT or not AUDIO then return end

local audio = import("goluwa/audio.lua")
local event = import("goluwa/event.lua")
local spatial = import("goluwa/audio/spatial.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ear_distance = audio.ear_distance
local notch = {frequency = spatial.PINNA_NOTCH.frequency, depth = spatial.PINNA_NOTCH.depth}
local overhead = {
	frequency = spatial.PINNA_OVERHEAD.frequency,
	gain = spatial.PINNA_OVERHEAD.gain,
}
local front = {frequency = spatial.PINNA_FRONT.frequency, gain = spatial.PINNA_FRONT.gain}
local AUDIBLE_FADE_START = 0.3
local AUDIBLE_FADE_END = 0.42

event.AddListener("Update", "listener_scale", function()
	if not audio.initialized then return end

	local scale = render3d.GetMainCamera():GetScale()
	local sample_rate = audio.state.sample_rate
	local fade_start = sample_rate * AUDIBLE_FADE_START
	local fade_end = sample_rate * AUDIBLE_FADE_END
	local pinna_notch, pinna_overhead, pinna_front = spatial.PINNA_NOTCH, spatial.PINNA_OVERHEAD, spatial.PINNA_FRONT
	audio.ear_distance = ear_distance * scale
	-- an ear small enough to put its cues above what the mixer can represent has no cues, so they fade out instead of running a filter past Nyquist
	pinna_notch.frequency = math.min(notch.frequency / scale, fade_end)
	pinna_notch.depth = notch.depth * (
			1 - math.smoothstep(fade_start, fade_end, notch.frequency / scale)
		)
	pinna_overhead.frequency = math.min(overhead.frequency / scale, fade_end)
	pinna_overhead.gain = overhead.gain * (
			1 - math.smoothstep(fade_start, fade_end, overhead.frequency / scale)
		)
	pinna_front.frequency = math.min(front.frequency / scale, fade_end)
	pinna_front.gain = front.gain * (1 - math.smoothstep(fade_start, fade_end, front.frequency / scale))
end)
