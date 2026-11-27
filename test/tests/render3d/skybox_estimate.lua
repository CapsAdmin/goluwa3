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
