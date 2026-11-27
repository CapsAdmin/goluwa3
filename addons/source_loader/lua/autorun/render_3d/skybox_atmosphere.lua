local commands = import("goluwa/cli/commands.lua")
local weather = import("goluwa/render3d/weather.lua")
local skybox_estimate = import("goluwa/render3d/skybox_estimate.lua")
local sky = import("lua/source_loader/sky.lua")
local CLOUD_HEIGHT = 1500
local CLOUD_THICKNESS = 1200

-- fits the air to the loaded source map's skybox for its sun and lays out engine clouds like the skybox's
commands.Add("skybox_atmosphere", function()
	sky.LoadCurrent(function(cube)
		local sun = weather.GetSunDirection()
		local result = skybox_estimate.Estimate(cube, sun)
		weather.SetAerosolVisibility(result.aerosol_visibility)
		local coverage = skybox_estimate.ApplyClouds(cube, sun, CLOUD_HEIGHT, CLOUD_THICKNESS)
		logf(
			"skybox_atmosphere: aerosol visibility %.0f km, cloud coverage %.0f%%\n",
			result.aerosol_visibility / 1000,
			coverage * 100
		)
	end)
end)
