local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local mirage = {}
mirage.SOLAR_LUMINOUS_EFFICACY = 93
mirage.STILL_CONVECTION = 5.7
mirage.WIND_CONVECTION = 3.8
mirage.GROUND_CONDUCTANCE = 8
mirage.EMISSIVITY = 0.95
mirage.STEFAN_BOLTZMANN = 5.670374419e-8
mirage.AIR_REFRACTIVITY = 77.6e-6 * 1013.25
mirage.AIR_HEAT_CAPACITY = 1.2 * 1005
mirage.GRAVITY = 9.81
mirage.FREE_CONVECTION_CT2 = 2.68
mirage.TEMPERATURE_FLUCTUATION = 0.15
mirage.APERTURE = 0.003
mirage.SURFACE_LAYER = 0.01
mirage.EDDY_SIZE = 0.5
mirage.PATCH_SIZE = 1.5
mirage.MIN_HEAT = 0.5
pvars.StartGroup("Lighting", "Mirage", {store = false})
local enabled = pvars.Setup2{
	key = "r_mirage",
	default = true,
	friendly = "heat mirage",
	help = "sunlit surfaces heat the air above them by a surface energy balance (absorbed sun against convection, radiation and conduction, cooled by wind and wetness). the hot air bends grazing view rays back up below the critical angle, so far road shows the sky and the bottoms of distant things, and the turbulence above it makes what is seen through it shimmer",
}
pvars.EndGroup()
mirage.block = {
	{"mirage_sun_direction", "vec3"},
	{"mirage_sun_irradiance", "float"},
	{"mirage_wind", "vec3"},
	{"mirage_air_temperature", "float"},
	{"mirage_heat_loss", "float"},
	{"mirage_convection", "float"},
	{"mirage_dryness", "float"},
	{"mirage_time", "float"},
}

function mirage.GetSunIrradiance()
	local lights = render3d.GetLights()

	if not directional_shadows.GetPrimarySun(lights) then return 0 end

	return directional_shadows.GetPrimarySunIlluminance(lights) * directional_shadows.GetPrimarySunColor(lights):GetLuminance() / mirage.SOLAR_LUMINOUS_EFFICACY
end

function mirage.GetAirTemperature()
	return atmosphere.GetTemperature() + 273.15
end

function mirage.GetConvection()
	return mirage.STILL_CONVECTION + mirage.WIND_CONVECTION * atmosphere.GetWind():GetLength()
end

function mirage.GetHeatLoss()
	local air = mirage.GetAirTemperature()
	return mirage.GetConvection() + 4 * mirage.EMISSIVITY * mirage.STEFAN_BOLTZMANN * air * air * air + mirage.GROUND_CONDUCTANCE
end

function mirage.GetMaxHeat()
	return mirage.GetSunIrradiance() * (
			1 - surface_weather.GetWetness()
		) / mirage.GetHeatLoss()
end

function mirage.IsActive()
	return enabled:Get() and
		atmosphere.IsEnabled() and
		mirage.GetMaxHeat() >= mirage.MIN_HEAT
end

function mirage.WriteBlock(self, block)
	directional_shadows.GetPrimarySunDirection(render3d.GetLights()):CopyToFloatPointer(block.mirage_sun_direction)
	block.mirage_sun_irradiance = mirage.GetSunIrradiance()
	atmosphere.GetWind():CopyToFloatPointer(block.mirage_wind)
	block.mirage_air_temperature = mirage.GetAirTemperature()
	block.mirage_heat_loss = mirage.GetHeatLoss()
	block.mirage_convection = mirage.GetConvection()
	block.mirage_dryness = 1 - surface_weather.GetWetness()
	block.mirage_time = system.GetElapsedTime() % 1000
	return block
end

function mirage.GetGLSL(block_name)
	local function constant(value)
		return string.format("%.9g", value)
	end

	return [[
		float mirage_critical_angle(float heat) {
			float air = ]] .. block_name .. [[.mirage_air_temperature;
			return sqrt(2.0 * ]] .. constant(mirage.AIR_REFRACTIVITY) .. [[ * (1.0 / air - 1.0 / (air + heat)));
		}

		float mirage_noise(vec3 p) {
			return (value_noise3(mod(p, 4096.0)) - 0.5) / 0.185;
		}

		vec3 mirage_drift(float rise) {
			return (]] .. block_name .. [[.mirage_wind + vec3(0.0, rise, 0.0)) * ]] .. block_name .. [[.mirage_time * ]] .. block_name .. [[.view_scale;
		}

		float mirage_heat_flux(float heat) {
			return ]] .. block_name .. [[.mirage_convection * heat / ]] .. constant(mirage.AIR_HEAT_CAPACITY) .. [[;
		}

		float mirage_convective_velocity(float heat) {
			return pow(]] .. constant(mirage.GRAVITY) .. [[ / ]] .. block_name .. [[.mirage_air_temperature * mirage_heat_flux(heat), 1.0 / 3.0);
		}

		float mirage_cn2(float heat) {
			float air = ]] .. block_name .. [[.mirage_air_temperature;
			float gradient = ]] .. constant(mirage.AIR_REFRACTIVITY) .. [[ / (air * air);
			return gradient * gradient * ]] .. constant(mirage.FREE_CONVECTION_CT2) .. [[ * pow(mirage_heat_flux(heat), 4.0 / 3.0) * pow(]] .. constant(mirage.GRAVITY) .. [[ / air, -2.0 / 3.0);
		}

		float mirage_path_cn2(float heat, float camera_height, float target_height, float distance) {
			float low = max(min(camera_height, target_height), ]] .. constant(mirage.SURFACE_LAYER) .. [[);
			float high = max(max(camera_height, target_height), ]] .. constant(mirage.SURFACE_LAYER) .. [[);

			if (high - low < 1e-3 * high) return mirage_cn2(heat) * distance * pow(high, -4.0 / 3.0);

			return mirage_cn2(heat) * distance / (high - low) * 3.0 * (pow(low, -1.0 / 3.0) - pow(high, -1.0 / 3.0));
		}

		float mirage_arrival_angle(float path_cn2) {
			return sqrt(2.91 * pow(]] .. constant(mirage.APERTURE) .. [[, -1.0 / 3.0) * path_cn2);
		}
	]]
end

return mirage
