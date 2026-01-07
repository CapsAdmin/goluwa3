-- Atmosphere / Sky rendering GLSL code
-- Extracted from skybox.lua for reuse in reflection probes and main rendering
local atmosphere = {}
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
	return require("render3d.atmospheres.temple") .. require("render3d.atmospheres.night_sky")
end

function atmosphere.GetGLSLMainCode(dir_var, sun_dir_var, cam_pos_var, stars_texture_index_var)
	return [[
		{
			vec3 dir = normalize(]] .. dir_var .. [[);
			vec3 sunDir = normalize(]] .. sun_dir_var .. [[);
			
			vec3 col = get_atmosphere(dir, sunDir, ]] .. cam_pos_var .. [[);
			
			// Compute sky brightness for blending with space texture
			// Use sun elevation to determine day/night
			float sunElevation = sunDir.y;
			
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
				float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
				float v = asin(dir.y) / PI + 0.5;
				spaceColor = texture(TEXTURE(]] .. stars_texture_index_var .. [[), vec2(u, -v)).rgb;
				spaceColor = pow(spaceColor, vec3(10.0));
				spaceColor *= 0.5;
			} else {
				spaceColor = get_stars(dir, sunDir);
			}
			
			// Blend: show stars when sky is dark, hide them during day
			sky_color_output = mix(spaceColor, col, blendFactor);
		}
	]]
end

return atmosphere
