local T = import("test/environment.lua")
local fs = import("goluwa/filesystem/fs.lua")
local lut_bake = import("goluwa/render3d/lut_bake.lua")
local lut = import("goluwa/codecs/lut.lua")

local function linear_to_srgb(c)
	c = math.max(0, math.min(1, c))
	return c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055
end

local function logc_inverse(y)
	if y > 5.367655 * 0.010591 + 0.092809 then
		return (10 ^ ((y - 0.385537) / 0.247190) - 0.052272) / 5.555556
	end

	return (y - 0.092809) / 5.367655
end

local function slog3_inverse(y)
	if y >= 171.2102946929 / 1023 then return 10 ^ ((y * 1023 - 420) / 261.5) * 0.19 - 0.01 end

	return (y * 1023 - 95) * 0.01125 / (171.2102946929 - 95)
end

T.Test3D("Graphics render3d lut bake writes the display transform over the encoded scene and caches it", function(draw)
	draw()
	local paths = {}
	local size = 9

	for _, case in ipairs{
		{encoding = "logc", inverse = logc_inverse, glsl = "vec3 bake_transform(vec3 x) { return x; }", scale = 1},
		{
			encoding = "slog3",
			inverse = slog3_inverse,
			glsl = "vec3 bake_transform(vec3 x) { return x * 0.5; }",
			scale = 0.5,
		},
	} do
		local config = {name = "test " .. case.encoding, glsl = case.glsl, encoding = case.encoding, size = size}
		local path, cached = lut_bake.Bake(config)
		paths[#paths + 1] = path
		T(cached)["=="](false)
		T(path:find(lut_bake.CacheDirectory, 1, true))["=="](1)
		local decoded = lut.DecodeCube(assert(fs.read_file(path)))
		T(decoded.size)["=="](size)

		for i = 0, size - 1 do
			local grey = i / (size - 1)
			local o = (i + i * size + i * size * size) * 3
			local expected = linear_to_srgb(case.inverse(grey) * case.scale)

			for channel = 0, 2 do
				T(decoded.data[o + channel], case.encoding .. " grey " .. i)["~"](expected, 2e-3)
			end
		end

		local again, was_cached = lut_bake.Bake(config)
		T(again)["=="](path)
		T(was_cached)["=="](true)
		T(lut_bake.GetPath({name = config.name, glsl = config.glsl .. " ", encoding = config.encoding, size = size}))["~="](path)
		T(lut_bake.GetPath({name = config.name, glsl = config.glsl, encoding = config.encoding, size = size + 1}))["~="](path)
	end

	T(pcall(lut_bake.Bake, {name = "x", glsl = "", encoding = "agx", size = 9}))["=="](false)
	T(pcall(lut_bake.Bake, {name = "x", glsl = "", encoding = "logc", size = 1}))["=="](false)

	for _, path in ipairs(paths) do
		os.remove(path)
	end
end)
