local SEQUENCES = {
	drive = {"drive_jeep", "sit_rollercoaster", "sit"},
	ride = {"drive_airboat", "drive_jeep", "sit"},
	pilot = {"drive_jeep", "drive_pd", "sit"},
}
return {
	seat = {
		Kind = "state",
		Enter = 0.2,
		Exit = 0.25,
		Locomotion = false,
		Legs = false,
		HideWeapons = true,
		Sequence = function(inst, suffix, clips)
			for _, name in ipairs(SEQUENCES[inst.arg] or SEQUENCES.drive) do
				if clips[name] then return name end
			end
		end,
		Body = function(inst, pose, position, rotation)
			local seat = pose:GetSeatComponent()

			if seat then seat:GetRenderFrame(position, rotation) end
		end,
	},
}
