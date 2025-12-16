local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")
local render = require("graphics.render")
local render2d = require("graphics.render2d")
local event = require("event")
local fs = require("fs")

local function save(width, height)
	-- Use the new helper function to copy image to CPU
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	-- Verify we have some non-zero pixel data
	local has_data = false

	for i = 0, image_data.size - 1 do
		if image_data.pixels[i] ~= 0 then
			has_data = true

			break
		end
	end

	T(has_data)["=="](true)
	-- Encode as PNG
	local png = png_encode(width, height, "rgba")
	local pixel_table = {}

	for i = 0, image_data.size - 1 do
		pixel_table[i + 1] = image_data.pixels[i]
	end

	png:write(pixel_table)
	local png_data = png:getData()
	T(#png_data)[">"](0)
	-- Save PNG file
	local screenshot_dir = "./logs/screenshots"
	fs.create_directory_recursive(screenshot_dir)
	local screenshot_path = screenshot_dir .. "/render2d_example.png"
	local file = assert(io.open(screenshot_path, "wb"))
	file:write(png_data)
	file:close()
	print("Render2D screenshot saved to: " .. screenshot_path)
	-- Verify file was created
	local verify_file = io.open(screenshot_path, "rb")
	T(verify_file)["~="](nil)

	if verify_file then
		local file_size = verify_file:seek("end")
		verify_file:close()
		T(file_size)[">"](0)
		print("Render2D screenshot file size: " .. file_size .. " bytes")
	end
end

local initialized = false

local function draw2d(cb)
	local width = 512
	local height = 512

	if not initialized then
		render.Initialize({headless = true, width = width, height = height})
		render2d.Initialize()
		initialized = true
	end

	event.AddListener("Draw2D", "test", cb)
	event.Call("Update", 0)
	event.RemoveListener("Draw2D", "test")
	save(width, height)
end

T.Test("Graphics render2d drawing example", function()
	draw2d(function()
		-- Example 1: Draw a red rectangle
		render2d.SetColor(1, 0, 0, 1)
		render2d.DrawRect(50, 50, 100, 100)
		-- Example 2: Draw a green rectangle with rotation
		render2d.SetColor(0, 1, 0, 1)
		render2d.DrawRect(200, 50, 80, 80, math.rad(45))
		-- Example 3: Draw a blue triangle
		render2d.SetColor(0, 0, 1, 1)
		render2d.DrawTriangle(400, 100, 60, 60)
		-- Example 4: Draw semi-transparent yellow rectangle
		render2d.SetColor(1, 1, 0, 0.5)
		render2d.DrawRect(100, 200, 150, 80)

		-- Example 5: Draw multiple colored rectangles in a grid
		for i = 0, 3 do
			for j = 0, 3 do
				local hue = (i * 4 + j) / 16
				local r = math.abs(hue * 6 - 3) - 1
				local g = 2 - math.abs(hue * 6 - 2)
				local b = 2 - math.abs(hue * 6 - 4)
				r = math.max(0, math.min(1, r))
				g = math.max(0, math.min(1, g))
				b = math.max(0, math.min(1, b))
				render2d.SetColor(r, g, b, 1)
				render2d.DrawRect(50 + i * 50, 320 + j * 30, 40, 25)
			end
		end

		-- Example 6: Draw with blend modes
		render2d.SetBlendMode("additive")
		render2d.SetColor(1, 0, 0, 0.5)
		render2d.DrawRect(300, 250, 100, 100)
		render2d.SetColor(0, 1, 0, 0.5)
		render2d.DrawRect(350, 250, 100, 100)
		render2d.SetColor(0, 0, 1, 0.5)
		render2d.DrawRect(325, 300, 100, 100)
		render2d.SetBlendMode("alpha")
		-- Example 7: Using matrix transformations
		render2d.PushMatrix()
		render2d.Translate(400, 400)
		render2d.Rotate(math.rad(30))
		render2d.Scale(2, 1)
		render2d.SetColor(1, 0.5, 0, 1)
		render2d.DrawRect(0, 0, 40, 40)
		render2d.PopMatrix()
	end)
end)
