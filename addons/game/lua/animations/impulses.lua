local RECOIL_ANGLE = math.rad(6)
local FLINCH_ANGLE = math.rad(10)
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
}
