local T = import("test/environment.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local tiles = import("goluwa/terrain/tiles.lua")

local function create_source()
	return ShaderSource.New{
		HeightGLSL = [[
			float terrain_height(vec2 world) {
				return 5.0 + world.x * 0.5 + world.y * 0.25;
			}
		]],
		SplatGLSL = [[
			vec4 terrain_splat(vec2 world, float h, vec3 n) {
				return vec4(1.0, 0.0, 0.0, 0.0);
			}
		]],
		MinHeight = 0,
		MaxHeight = 100,
	}
end

T.Test3D("Terrain shader source reads back heights matching its GLSL", function()
	local source = create_source()
	local request = {
		min_x = 16,
		min_z = -8,
		size = 32,
		samples = 9,
		detail_size = 16,
		splat_size = 8,
	}
	local chunk

	source:RequestChunk(request, function(result)
		chunk = result
	end)

	T(chunk == nil)["=="](true)
	source:Finish()
	T(chunk ~= nil)["=="](true)
	T(chunk.normal_texture ~= nil)["=="](true)
	T(chunk.splat_texture ~= nil)["=="](true)

	for z = 0, 8 do
		for x = 0, 8 do
			local world_x = 16 + x * 4
			local world_z = -8 + z * 4
			local expected = 5 + world_x * 0.5 + world_z * 0.25
			T(math.abs(chunk.heights[z * 9 + x] - expected))["<"](0.001)
		end
	end

	T(math.abs(chunk.min_height - (5 + 16 * 0.5 - 8 * 0.25)))["<"](0.001)
	T(math.abs(chunk.max_height - (5 + 48 * 0.5 + 24 * 0.25)))["<"](0.001)
	local polygon = tiles.BuildPolygon(chunk, 3, 1)
	T(polygon.mesh ~= nil)["=="](true)
	T(math.abs(polygon.AABB.max_x - 32))["<"](0.001)
	T(math.abs(polygon.AABB.max_z - 32))["<"](0.001)
	T(math.abs(polygon.AABB.max_y - chunk.max_height))["<"](0.001)
	T(math.abs(polygon.AABB.min_y - (chunk.min_height - 3)))["<"](0.001)
	local r, g, b = chunk.normal_texture:Download():GetPixel(8, 8)
	T(math.abs(r - 72))["<="](2)
	T(math.abs(g - 100))["<="](2)
	T(math.abs(b - 239))["<="](2)
	source:ReleaseChunk(chunk)
end)

T.Test3D("Terrain shader source derives the splat and color from the baked height field", function()
	local source = ShaderSource.New{
		HeightGLSL = [[
			float terrain_height(vec2 world) {
				return 10.0 + world.x * 0.5;
			}
		]],
		SplatGLSL = [[
			vec4 terrain_splat(vec2 world, float h, vec3 n) {
				return vec4(h / 100.0, n.y, 0.0, 1.0);
			}
		]],
		ColorGLSL = [[
			vec3 terrain_color(vec2 world, float h, vec3 n) {
				return vec3(h / 100.0, 0.0, 0.0);
			}
		]],
		MinHeight = 0,
		MaxHeight = 100,
	}
	local request = {
		min_x = 0,
		min_z = 0,
		size = 32,
		samples = 9,
		detail_size = 32,
		splat_size = 16,
		color_size = 8,
	}
	local chunk

	source:RequestChunk(request, function(result)
		chunk = result
	end)

	source:Finish()
	local r, g = chunk.splat_texture:Download():GetPixel(4, 4)
	T(math.abs(r - (10 + 9 * 0.5) * 2.55))["<="](1.5)
	local expected_ny = 1 / math.sqrt(1 + 0.25)
	T(math.abs(g - expected_ny * 255))["<="](1.5)
	r = chunk.color_texture:Download():GetPixel(4, 4)
	T(math.abs(r - (10 + 18 * 0.5) * 2.55))["<="](1.5)
	source:ReleaseChunk(chunk)
end)
