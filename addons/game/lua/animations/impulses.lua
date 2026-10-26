local animations = import("lua/animations.lua")
local RECOIL_ANGLE = math.rad(6)
local FLINCH_ANGLE = math.rad(10)
local HIT_FLINCH_ANGLE = math.rad(32)
return {
	recoil = {
		Kind = "impulse",
		Trigger = "Shots",
		Decay = 8,
		Aim = function(inst, aim)
			return aim:Copy():RotatePitch(RECOIL_ANGLE * inst.weight)
		end,
	},
	flinch = {
		Kind = "impulse",
		Trigger = "Hits",
		Decay = 4,
		Torso = function(inst)
			return inst.weight * FLINCH_ANGLE
		end,
	},
	hit_flinch = {
		Kind = "impulse",
		Trigger = "Reacts",
		Decay = 4,
		Torso = function(inst)
			return inst.weight * HIT_FLINCH_ANGLE
		end,
	},
	hit_react = {
		Kind = "action",
		Trigger = "Reacts",
		Restart = true,
		Loop = false,
		BlendIn = 0.04,
		BlendOut = 0.2,
		Variants = {
			{Clip = "death_02", Start = 0.3, Duration = 0.2},
			{Clip = "death_04", Start = 0.3, Duration = 0.59},
		},
		Sequence = function(inst, suffix, clips)
			local clip = animations.GetVariant(inst).Clip

			if clips[clip] then return clip end
		end,
	},
}
