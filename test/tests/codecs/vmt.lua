local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fs = import("goluwa/fs.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local steam = import("goluwa/steam.lua")
local Material = import("goluwa/render3d/material.lua")
local vfs = import("goluwa/vfs.lua")
local Color = import("goluwa/structs/color.lua")

-- Helper function to get pixel color
local function get_pixel(image_data, x, y)
	local width = image_data.width
	local height = image_data.height
	local bytes_per_pixel = image_data.bytes_per_pixel

	if x < 0 or x >= width or y < 0 or y >= height then return 0, 0, 0, 0 end

	local offset = (y * width + x) * bytes_per_pixel
	local r = image_data.pixels[offset + 0]
	local g = image_data.pixels[offset + 1]
	local b = image_data.pixels[offset + 2]
	local a = image_data.pixels[offset + 3]
	return r, g, b, a
end

-- Helper function to test pixel color
local function test_pixel(x, y, r, g, b, a, tolerance)
	tolerance = tolerance or 0.01
	local image_data = render.target:GetTexture():Download()
	local r_, g_, b_, a_ = get_pixel(image_data, x, y)
	local r_norm, g_norm, b_norm, a_norm = r_ / 255, g_ / 255, b_ / 255, a_ / 255
	-- Check with tolerance
	T(math.abs(r_norm - r))["<="](tolerance)
	T(math.abs(g_norm - g))["<="](tolerance)
	T(math.abs(b_norm - b))["<="](tolerance)
	T(math.abs(a_norm - a))["<="](tolerance)
end

T.Test2D("VMT render", function()
	local games = steam.GetSourceGames()
	steam.MountSourceGame("gmod")
	local mat = Material.FromVMT("materials/models/hevsuit/hevsuit_sheet.vmt")
	render2d.SetColor(1, 0, 0, 1)
	render2d.SetTexture(mat:GetAlbedoTexture())
	render2d.DrawRect(0, 0, 50, 50)
end)
