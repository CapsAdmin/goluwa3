local T = import("test/environment.lua")
local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local skybox_estimate = import("goluwa/render3d/skybox_estimate.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function new_cube(size, format)
	return Texture.New{
		width = size,
		height = size,
		format = format,
		mip_map_levels = "auto",
		image = {
			array_layers = 6,
			flags = {"cube_compatible"},
			usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		view = {view_type = "cube", layer_count = 6},
		sampler = {min_filter = "linear", mag_filter = "linear"},
	}
end

do
	local Constants = ffi.typeof("struct { int lut; }")

	-- the engine's own sky for a sun at azimuth 0, stored as a source 2 skybox (z up) scaled by 1e-4
	local function engine_sky_cube(elevation, visibility)
		atmosphere.SetAerosolVisibility(visibility)
		local lut = atmosphere.GetSkyViewTexture(
			Vec3(0, 0, 0),
			Vec3(0, math.sin(math.rad(elevation)), math.cos(math.rad(elevation)))
		)
		local cube = new_cube(256, "r16g16b16a16_sfloat")
		cube:Shade(
			[[
				vec4 shade(vec2 uv, vec3 c) {
					vec3 e = vec3(-c.y, c.z, -c.x);
					vec3 h = normalize(vec3(e.x, 0.0, e.z) + vec3(1e-6));
					float azimuth = atan(-h.x, h.z);
					float v = sqrt(clamp(asin(clamp(e.y, -1.0, 1.0)) / 3.14159265 + 0.5, 0.0, 1.0));
					return vec4(textureLod(TEXTURE(sky_lut.index), vec2(azimuth / 6.28318531 + 0.5, v), 0.0).rgb * 1e-4, 1.0);
				}
			]],
			{
				textures = {lut},
				custom_declarations = "layout(push_constant) uniform SkyLut { int index; } sky_lut;",
				fragment_push_constants = {
					size = ffi.sizeof(Constants),
					get_data = function(_, _, pipeline)
						return Constants(pipeline:GetTextureIndex(lut))
					end,
				},
			}
		)
		return cube
	end

	T.Test3D("Graphics skybox estimate recovers the sun, aerosol and exposure of an engine sky", function()
		local old_visibility = atmosphere.GetAerosolVisibility()

		for _, case in ipairs{{elevation = 10, visibility = 30000}, {elevation = 40, visibility = 120000}} do
			local cube = engine_sky_cube(case.elevation, case.visibility)
			local result = skybox_estimate.Estimate(cube)
			cube:Remove()
			T(result.fitted_elevation)["=="](case.elevation)
			T(result.aerosol_visibility)["=="](case.visibility)
			T(math.abs(result.intensity / 1e4 - 1))["<"](0.01)
			T(result.cloud_fraction)["<"](0.01)
		end

		atmosphere.SetAerosolVisibility(old_visibility)
	end)
end

T.Test3D("Graphics skybox coverage map puts clouds where the skybox has them", function()
	local cube = new_cube(256, "r16g16b16a16_sfloat")
	-- a smooth sky with a textured patch between azimuth 20 and 110 degrees and elevation 20 and 60 degrees
	cube:Shade([[
		vec4 shade(vec2 uv, vec3 c) {
			vec3 e = vec3(-c.y, c.z, -c.x);
			vec3 sky = vec3(0.3, 0.5, 1.0) * (1.5 - e.y);
			float azimuth = degrees(atan(e.x, e.z));
			float elevation = degrees(asin(clamp(e.y, -1.0, 1.0)));

			if (azimuth > 20.0 && azimuth < 110.0 && elevation > 20.0 && elevation < 60.0) {
				sky *= 1.0 + 0.8 * sin(dot(e, vec3(0.8, 0.3, 0.5)) * 110.0) * sin(dot(e, vec3(-0.4, 0.6, 0.7)) * 97.0);
			}

			return vec4(sky, 1.0);
		}
	]])
	local height = 1500
	local map, size, fraction = skybox_estimate.BuildCoverageMap(cube, Vec3(0, -1, 0), height)
	local pixels = map:Download():Resolve()
	local inside, inside_count, outside, outside_count = 0, 0, 0, 0
	local resolution = pixels:GetWidth()

	for y = 0, resolution - 1 do
		for x = 0, resolution - 1 do
			local dir = Vec3(
				((x + 0.5) / resolution - 0.5) * size,
				height,
				((y + 0.5) / resolution - 0.5) * size
			):GetNormalized()
			local azimuth = math.deg(math.atan2(dir.x, dir.z))
			local elevation = math.deg(math.asin(dir.y))
			local coverage, trust = pixels:GetPixelFloat(x, y)

			if azimuth > 32 and azimuth < 98 and elevation > 32 and elevation < 48 then
				inside = inside + coverage
				inside_count = inside_count + 1
			elseif trust > 0.99 and (azimuth < 8 or azimuth > 122 or elevation > 72) then
				outside = outside + coverage
				outside_count = outside_count + 1
			end
		end
	end

	map:Remove()
	cube:Remove()
	T(inside_count)[">"](100)
	T(outside_count)[">"](100)
	T(inside / inside_count)[">"](0.7)
	T(outside / outside_count)["<"](0.1)
	T(fraction)[">"](0.02)
	T(fraction)["<"](0.3)
end)
