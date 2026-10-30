return {
	held = {
		Kind = "state",
		Enter = 0.15,
		Exit = 0.2,
		Stun = true,
		Locomotion = false,
		Legs = false,
		HideWeapons = true,
		Body = function(inst, pose, position, rotation)
			local latch = pose.Owner.character_movement.latch

			if latch then latch:GetRenderFrame(position, rotation) end
		end,
	},
}
