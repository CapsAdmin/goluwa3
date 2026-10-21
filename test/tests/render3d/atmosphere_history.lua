local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")

local function clear_cache()
	for key, tex in pairs(atmosphere.sky_view_textures) do
		tex:Remove()
		atmosphere.sky_view_textures[key] = nil
	end

	atmosphere.sky_view_texture_order = {}
end

local function sun_at(elevation_degrees)
	local e = math.rad(elevation_degrees)
	return Vec3(math.cos(e) * 0.6, math.sin(e), math.cos(e) * 0.8)
end

local function mean(tex)
	local img = tex:Download()
	local sum = {0, 0, 0, 0}
	local count = 0

	for y = 0, img.height - 1, 8 do
		for x = 0, img.width - 1, 8 do
			local r, g, b, a = img:GetPixelFloat(x, y)
			sum[1], sum[2], sum[3], sum[4] = sum[1] + r, sum[2] + g, sum[3] + b, sum[4] + a
			count = count + 1
		end
	end

	return sum[1] / count, sum[2] / count, sum[3] / count, sum[4] / count
end

T.Test3D("sky view lut is a function of its key and not of who baked it", function()
	local sun = sun_at(40)
	local near_sun = sun_at(40.001)
	local a = Vec3(0, 1.8, 0)
	local b = Vec3(300, 30, -200)
	clear_cache()
	local first = {mean(atmosphere.GetSkyViewTexture(a, sun))}
	clear_cache()
	local second = {mean(atmosphere.GetSkyViewTexture(b, near_sun))}

	for i = 1, 4 do
		T(math.abs(first[i] - second[i]) / math.max(first[i], 1e-6))["<"](1e-5)
	end

	clear_cache()
end)

T.Test3D("sky view lut follows the camera height", function()
	local sun = sun_at(40)
	clear_cache()
	local low = {mean(atmosphere.GetSkyViewTexture(Vec3(0, 1.8, 0), sun))}
	local high = {mean(atmosphere.GetSkyViewTexture(Vec3(0, 1500, 0), sun))}
	T(math.abs(low[4] - high[4]) / low[4])[">"](0.01)
	clear_cache()
end)

T.Test("wind version changes with the wind vector and only then", function()
	local before = atmosphere.GetWindVersion()
	atmosphere.SetWind(Vec3(1, 0, 2))
	local first = atmosphere.GetWindVersion()
	T(first)["~="](before)
	atmosphere.SetWind(Vec3(1, 0, 2))
	T(atmosphere.GetWindVersion())["=="](first)
	local wind = Vec3(3, 0, 4)
	atmosphere.SetWind(wind)
	local second = atmosphere.GetWindVersion()
	T(second)["~="](first)
	wind.x = 5
	atmosphere.SetWind(wind)
	T(atmosphere.GetWindVersion())["~="](second)
end)
