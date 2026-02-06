-- Atmosphere / Sky rendering GLSL code
-- Extracted from skybox.lua for reuse in reflection probes and main rendering
local atmosphere = {}
local Vec3 = require("structs.vec3")
-- Configuration
atmosphere.USE_TEMPLE = false
atmosphere.stars_texture = nil

function atmosphere.SetStarsTexture(texture)
	atmosphere.stars_texture = texture
end

function atmosphere.GetStarsTexture()
	return atmosphere.stars_texture
end

function atmosphere.GetGLSLCode()
	return require("render3d.atmospheres.nishita") .. require("render3d.atmospheres.night_sky")
end

function atmosphere.GetGLSLMainCode(dir_var, sun_dir_var, cam_pos_var, stars_texture_index_var)
	return [[
		{
			vec3 atmos_dir = normalize(]] .. dir_var .. [[);
			vec3 atmos_sunDir = normalize(]] .. sun_dir_var .. [[);
			
			vec3 col = get_atmosphere(atmos_dir, atmos_sunDir, ]] .. cam_pos_var .. [[);
			
			// Compute sky brightness for blending with space texture
			// Use sun elevation to determine day/night
			float sunElevation = atmos_sunDir.y;
			
			// Sky brightness based on sun elevation
			// At sunset (elevation ~0), start transitioning
			// Below horizon, night time
			float dayFactor = smoothstep(-0.2, 0.1, sunElevation);
			
			// Also consider the actual sky luminance for the blend
			float skyLuminance = dot(col, vec3(0.2126, 0.7152, 0.0722));
			float skyBrightness = clamp(skyLuminance * 0.5, 0.0, 1.0);
			
			// Combine day factor and sky brightness
			float blendFactor = max(dayFactor, skyBrightness);
			
			// Sample space/stars texture
			vec3 spaceColor = vec3(0.0);
			if (]] .. stars_texture_index_var .. [[ != -1) {
				float u = atan(atmos_dir.z, atmos_dir.x) / (2.0 * PI) + 0.5;
				float v = asin(atmos_dir.y) / PI + 0.5;
				spaceColor = texture(TEXTURE(]] .. stars_texture_index_var .. [[), vec2(u, -v)).rgb;
				spaceColor = pow(spaceColor, vec3(10.0));
				spaceColor *= 0.5;
			} else {
				spaceColor = get_stars(atmos_dir, atmos_sunDir);
			}
			
			// Blend: show stars when sky is dark, hide them during day
			sky_color_output = mix(spaceColor, col, blendFactor);
		}
	]]
end

local EARTH_RADIUS = 6371000.0
local ATMOSPHERE_RADIUS = 6471000.0
local HR = 7994.0
local HM = 1200.0
local BETA_R = Vec3(5.5e-6, 13.0e-6, 22.4e-6)
local BETA_M = Vec3(21e-6, 21e-6, 21e-6)
local SUN_INTENSITY = 50.0

local function raySphereIntersect(rayOrigin, rayDir, radius)
	local a = rayDir:Dot(rayDir)
	local b = 2.0 * rayDir:Dot(rayOrigin)
	local c = rayOrigin:Dot(rayOrigin) - radius * radius
	local d = b * b - 4.0 * a * c

	if d < 0.0 then return -1, -1 end

	d = math.sqrt(d)
	local t0 = (-b - d) / (2.0 * a)
	local t1 = (-b + d) / (2.0 * a)
	return t0, t1
end

function atmosphere.GetSunColor(sunDir, camPos)
	camPos = camPos or Vec3(0, 0, 0)
	local rayOrigin = Vec3(0, EARTH_RADIUS + 1.75 + camPos.y, 0)
	-- Intersect with atmosphere
	local tmin, tmax = raySphereIntersect(rayOrigin, sunDir, ATMOSPHERE_RADIUS)

	if tmax <= 0 then return Vec3(0, 0, 0) end

	tmin = math.max(tmin, 0)
	-- Check for earth occlusion
	local etmin, etmax = raySphereIntersect(rayOrigin, sunDir, EARTH_RADIUS)

	if etmin > 0 then return Vec3(0, 0, 0) end

	-- Integrate optical depth
	local numSamples = 16
	local segmentLength = (tmax - tmin) / numSamples
	local opticalDepthR = 0
	local opticalDepthM = 0

	for i = 0, numSamples - 1 do
		local samplePos = rayOrigin + sunDir * (tmin + segmentLength * (i + 0.5))
		local height = samplePos:GetLength() - EARTH_RADIUS
		opticalDepthR = opticalDepthR + math.exp(-height / HR) * segmentLength
		opticalDepthM = opticalDepthM + math.exp(-height / HM) * segmentLength
	end

	local tau = BETA_R * opticalDepthR + BETA_M * opticalDepthM
	local attenuation = Vec3(math.exp(-tau.x), math.exp(-tau.y), math.exp(-tau.z))
	-- Base sun color (slightly warm white)
	local baseSunColor = Vec3(1.0, 0.98, 0.95) * (SUN_INTENSITY * 10.0)
	return attenuation * baseSunColor
end

function atmosphere.GetAmbientColor(sunDir)
	local sunHeight = sunDir.y
	-- Day sky ambient (blue)
	local dayAmbient = Vec3(0.4, 0.6, 0.9) * 0.3
	-- Sunset/sunrise ambient (warm orange-red)
	local sunsetAmbient = Vec3(0.8, 0.4, 0.2) * 0.15
	-- Night ambient (very dark blue)
	local nightAmbient = Vec3(0.05, 0.08, 0.15) * 0.05

	-- Blend between day, sunset, and night based on sun height
	if sunHeight > 0.0 then
		-- Day to sunset transition
		local t = sunHeight ^ 0.5
		return sunsetAmbient:GetLerped(t, dayAmbient)
	else
		-- Sunset to night transition
		local t = math.min(math.max(sunHeight + 0.2, 0.0), 1.0) / 0.2
		return nightAmbient:GetLerped(t, sunsetAmbient)
	end
end

return atmosphere
