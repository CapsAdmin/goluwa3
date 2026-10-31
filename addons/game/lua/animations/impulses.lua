local RECOIL_ANGLE = math.rad(6)

return {
	recoil = {
		Kind = "impulse",
		Trigger = "Shots",
		Decay = 8,
		Aim = function(inst, aim)
			return aim:Copy():RotatePitch(RECOIL_ANGLE * inst.weight)
		end,
	},
}
