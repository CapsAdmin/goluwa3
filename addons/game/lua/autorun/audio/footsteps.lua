local event = import("goluwa/event.lua")
local sounds = import("lua/sounds.lua")
local sound_profiles = import("lua/sound_profiles.lua")
local LOUD_SPEED = 3
local QUIET = 0.15

event.AddListener("Impact", "footsteps", function(info)
	if not info.Foot then return end

	local voice = info.Entity.npc_sounds

	if voice and voice.Sounds.Foot then
		voice:Play("Foot", info.Position, math.clamp(info.Speed / LOUD_SPEED, QUIET, 1))
		return
	end

	local set = sound_profiles.Get().GetFootstep(info.Surface, info.Speed)
	local index = math.random(#set)

	if index == set.last then index = index % #set + 1 end

	set.last = index
	sounds.Play(
		set[index],
		info.Position,
		set.gain * math.clamp(info.Speed / LOUD_SPEED, QUIET, 1),
		math.randomf(0.95, 1.05) / (
				info.Entity.ai_controller and
				info.Entity.transform:GetScale().y or
				1
			)
	)
end)
