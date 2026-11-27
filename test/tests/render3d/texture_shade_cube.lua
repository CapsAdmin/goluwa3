local T = import("test/environment.lua")
local Texture = import("goluwa/render/texture.lua")
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

T.Test3D("Graphics Texture:Shade gives every cube texel its own direction", function()
	local size = 16
	local cube = new_cube(size, "r32g32b32a32_sfloat")
	cube:Shade("vec4 shade(vec2 uv, vec3 dir) { return vec4(dir, 1.0); }")
	local pixels = cube:Download{base_array_layer = 0}:Resolve()
	local worst = 0

	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local px, py = (x + 0.5) / size * 2 - 1, (y + 0.5) / size * 2 - 1
			local want = Vec3(1, -py, -px):GetNormalized()
			local r, g, b = pixels:GetPixelFloat(x, y)
			worst = math.max(worst, (Vec3(r, g, b) - want):GetLength())
		end
	end

	cube:Remove()
	T(worst)["<"](1e-3)
end)
