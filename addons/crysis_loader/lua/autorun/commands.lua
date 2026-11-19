local commands = import("goluwa/cli/commands.lua")

commands.Add("water_crysis_waves=boolean[true]", function(on)
	if on then
		import("lua/crysis_loader/water.lua").EnableCrysisWaves()
	else
		import("goluwa/render3d/water.lua").SetWaveBump(nil)
	end
end)
