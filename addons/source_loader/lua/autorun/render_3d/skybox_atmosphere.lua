local commands = import("goluwa/cli/commands.lua")
local weather = import("goluwa/render3d/weather.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local skybox_estimate = import("goluwa/render3d/skybox_estimate.lua")
local sky = import("lua/source_loader/sky.lua")
local CLOUD_HEIGHT = 1500
local CLOUD_THICKNESS = 1200

-- fits the air to the loaded source map's skybox for its sun and lays out engine clouds like the skybox's; feel above 0
-- also takes the skybox's colour without its texture into the sky and haze (see atmosphere.SetSkyboxFeel)
commands.Add("skybox_atmosphere=number[0]", function(feel)
	sky.LoadCurrent(function(cube)
		if feel > 0 then
			atmosphere.SetSkyboxTexture(cube)
			atmosphere.SetSkyboxBlend(0)
		end

		atmosphere.SetSkyboxFeel(feel)
		local sun = weather.GetSunDirection()
		local result = skybox_estimate.Estimate(cube, sun)
		weather.SetAerosolVisibility(result.aerosol_visibility)
		local coverage = skybox_estimate.ApplyClouds(cube, result, CLOUD_HEIGHT, CLOUD_THICKNESS)
		logf(
			"skybox_atmosphere: aerosol visibility %.0f km, cloud coverage %.0f%%\n",
			result.aerosol_visibility / 1000,
			coverage * 100
		)
	end)
end)
