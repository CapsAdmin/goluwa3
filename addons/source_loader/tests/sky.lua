local T = import("test/environment.lua")
local ffi = require("ffi")
local steam = import("goluwa/steam/steam.lua")
local Texture = import("goluwa/render/texture.lua")
local sky = import("lua/source_loader/sky.lua")
local EDGE_SAMPLES = 64
local Constants = ffi.typeof("struct { int cube; }")

T.Test3D("source 1 skybox faces join without seams above the horizon", function()
	local info = steam.FindSourceGame(220)

	if not info then return T.Unavailable("half-life 2 is not installed") end

	steam.MountSourceGame(info)
	local cube

	sky.Load("sky_day01_01", function(result)
		cube = result
	end)

	T.WaitUntilReal(function()
		return cube ~= nil
	end, 20, "the skybox to assemble")

	-- each column is a point on one of the eight cube edges at or above the horizon (z up), the two rows the cube
	-- sampled just inside the two faces that meet there
	local target = Texture.New{
		width = EDGE_SAMPLES * 8,
		height = 2,
		format = "r32g32b32a32_sfloat",
		mip_map_levels = 1,
	}
	target:Shade(
		(
			[[
			vec4 shade(vec2 uv, vec3 _cube_dir) {
				int column = int(uv.x * %d.0);
				int edge = column / %d;
				float t = (float(column %% %d) + 0.5) / %d.0;
				float e = 0.02;
				vec3 a;
				vec3 b;

				if (edge < 4) {
					vec2 corner = vec2(edge %% 2 == 0 ? 1.0 : -1.0, edge / 2 == 0 ? 1.0 : -1.0);
					float z = t * 0.9;
					a = vec3(corner.x, corner.y * (1.0 - e), z);
					b = vec3(corner.x * (1.0 - e), corner.y, z);
				} else {
					float side = (edge %% 2 == 0) ? 1.0 : -1.0;
					float s = t * 1.8 - 0.9;
					a = edge < 6 ? vec3(side, s, 1.0 - e) : vec3(s, side, 1.0 - e);
					b = edge < 6 ? vec3(side * (1.0 - e), s, 1.0) : vec3(s, side * (1.0 - e), 1.0);
				}

				vec3 dir = normalize(uv.y < 0.5 ? a : b);
				return vec4(textureLod(CUBEMAP(edge_samples.cube), dir, 0.0).rgb, 1.0);
			}
		]]
		):format(EDGE_SAMPLES * 8, EDGE_SAMPLES, EDGE_SAMPLES, EDGE_SAMPLES),
		{
			textures = {cube},
			custom_declarations = "layout(push_constant) uniform EdgeSamples { int cube; } edge_samples;",
			fragment_push_constants = {
				size = ffi.sizeof(Constants),
				get_data = function(_, _, pipeline)
					return Constants(pipeline:GetCubeMapTextureIndex(cube))
				end,
			},
		}
	)
	local pixels = target:Download():Resolve()
	local difference, brightness = 0, 0

	for x = 0, EDGE_SAMPLES * 8 - 1 do
		local r1, g1, b1 = pixels:GetPixelFloat(x, 0)
		local r2, g2, b2 = pixels:GetPixelFloat(x, 1)
		difference = difference + math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2)
		brightness = brightness + r1 + g1 + b1
	end

	target:Remove()
	cube:Remove()
	T(difference / brightness)["<"](0.05)
end)

T.Test("source 1 skyboxes are listed once, without their hdr variants", function()
	local info = steam.FindSourceGame(220)

	if not info then return T.Unavailable("half-life 2 is not installed") end

	steam.MountSourceGame(info)
	local names = sky.Find()
	T(table.has_value(names, "sky_day01_01") ~= false)["=="](true)
	T(table.has_value(names, "sky_day01_01_hdr"))["=="](false)
end)
