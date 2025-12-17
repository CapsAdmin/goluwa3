local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping render2d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")
local render = require("graphics.render")
local render2d = require("graphics.render2d")
local fs = require("fs")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local steam = require("steam")
local Material = require("graphics.material")
local vfs = require("vfs")
local Color = require("structs.color")
local width = 512
local height = 512
local initialized = false

-- Helper function to initialize render2d
local function init_render2d()
	render.Initialize({headless = true, width = width, height = height})
	render2d.Initialize()
end

-- Helper function to draw with render2d
local function draw2d(cb)
	render2d.Initialize()
	render.BeginFrame()
	render2d.BindPipeline()
	cb()
	render.EndFrame()
end

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
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	local r_, g_, b_, a_ = get_pixel(image_data, x, y)
	local r_norm, g_norm, b_norm, a_norm = r_ / 255, g_ / 255, b_ / 255, a_ / 255
	-- Check with tolerance
	T(math.abs(r_norm - r))["<="](tolerance)
	T(math.abs(g_norm - g))["<="](tolerance)
	T(math.abs(b_norm - b))["<="](tolerance)
	T(math.abs(a_norm - a))["<="](tolerance)
end

-- Helper function to save screenshot
local function save_screenshot(name)
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	local png = png_encode(width, height, "rgba")
	local pixel_table = {}

	for i = 0, image_data.size - 1 do
		pixel_table[i + 1] = image_data.pixels[i]
	end

	png:write(pixel_table)
	local png_data = png:getData()
	local screenshot_dir = "./logs/screenshots"
	fs.create_directory_recursive(screenshot_dir)
	local screenshot_path = screenshot_dir .. "/" .. name .. ".png"
	local file = assert(io.open(screenshot_path, "wb"))
	file:write(png_data)
	file:close()
	print("Screenshot saved to: " .. screenshot_path)
end

T.Test("VMT render", function()
	init_render2d()
	local games = steam.GetSourceGames()
	steam.MountSourceGame("gmod")
	local mat = Material.FromVMT("materials/models/hevsuit/hevsuit_sheet.vmt")

	draw2d(function()
		render2d.SetColor(1, 0, 0, 1)
		render2d.SetTexture(mat:GetAlbedoTexture())
		render2d.DrawRect(0, 0, 50, 50)
	end)

	save_screenshot("vmt_render_test")
end)
