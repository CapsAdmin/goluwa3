if not CLIENT or not AUDIO then return end

local audio = import("goluwa/audio.lua")
local event = import("goluwa/event.lua")
local spatial = import("goluwa/audio/spatial.lua")
local players = import("lua/players.lua")
local ear_distance = audio.ear_distance
local notch_frequency = spatial.PINNA_NOTCH.frequency
local overhead_frequency = spatial.PINNA_OVERHEAD.frequency
local front_frequency = spatial.PINNA_FRONT.frequency

event.AddListener("Update", "listener_scale", function()
	local player = players.GetLocal()
	local scale = player and player.character_movement.Scale or 1
	audio.ear_distance = ear_distance * scale
	spatial.PINNA_NOTCH.frequency = notch_frequency / scale
	spatial.PINNA_OVERHEAD.frequency = overhead_frequency / scale
	spatial.PINNA_FRONT.frequency = front_frequency / scale
end)
