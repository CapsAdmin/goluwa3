local bootstrap = assert(loadfile("game/addons/game/lua/examples/love2d/_bootstrap.lua"))()
local love = bootstrap("love2d_uv_mesh_probe")
local image
local quad
local mesh

local function draw_panel_outline(x, y, w, h)
	love.graphics.setColor(240, 244, 250, 255)
	love.graphics.rectangle("line", x - 2, y - 2, w + 4, h + 4)
	love.graphics.setColor(70, 78, 96, 255)
	love.graphics.rectangle("line", x - 10, y - 10, w + 20, h + 20)
end

local function draw_corner_markers(x, y)
	love.graphics.setColor(255, 255, 0, 255)
	love.graphics.rectangle("fill", x - 12, y - 12, 8, 8)
	love.graphics.setColor(255, 0, 0, 255)
	love.graphics.rectangle("fill", x + 196, y - 12, 8, 8)
	love.graphics.setColor(0, 255, 0, 255)
	love.graphics.rectangle("fill", x - 12, y + 196, 8, 8)
	love.graphics.setColor(0, 128, 255, 255)
	love.graphics.rectangle("fill", x + 196, y + 196, 8, 8)
end

local function make_test_image()
	local data = love.image.newImageData(64, 64)

	for y = 0, 63 do
		for x = 0, 63 do
			local r = x < 32 and 255 or 40
			local g = y < 32 and 255 or 60
			local b = x >= 32 and y >= 32 and 255 or 40
			data:setPixel(x, y, r, g, b, 255)
		end
	end

	for x = 0, 63 do
		data:setPixel(x, 31, 255, 255, 255, 255)
		data:setPixel(31, x, 255, 255, 255, 255)
	end

	image = love.graphics.newImage(data)
	quad = love.graphics.newQuad(0, 0, 32, 32, 64, 64)
	mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 255, 255, 255, 255},
			{192, 0, 1, 0, 255, 255, 255, 255},
			{192, 192, 1, 1, 255, 255, 255, 255},
			{0, 192, 0, 1, 255, 255, 255, 255},
		},
		image,
		"fan"
	)
end

function love.load()
	make_test_image()
	image:setFilter("nearest", "nearest", 1)
end

function love.draw()
	local panel_y = 104
	local panel_size = 192
	love.graphics.clear(14, 16, 22, 255)
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.print("texture / quad / mesh UV probe", 28, 18)
	love.graphics.print(
		"Top-left should be yellow, top-right red, bottom-left green, bottom-right blue in every panel.",
		28,
		40
	)
	love.graphics.print("full texture", 28, 78)
	draw_panel_outline(28, panel_y, panel_size, panel_size)
	draw_corner_markers(28, panel_y)
	love.graphics.draw(image, 28, panel_y, 0, 3, 3)
	love.graphics.print("quad top-left", 276, 78)
	draw_panel_outline(276, panel_y, panel_size, panel_size)
	draw_corner_markers(276, panel_y)
	love.graphics.draw(image, quad, 276, panel_y, 0, 6, 6)
	love.graphics.print("mesh full texture", 520, 78)
	draw_panel_outline(520, panel_y, panel_size, panel_size)
	draw_corner_markers(520, panel_y)
	love.graphics.draw(mesh, 520, panel_y)
	love.graphics.setColor(210, 220, 235, 255)
	love.graphics.print("If only the mesh is flipped, inspect Mesh:setVertex UV handling.", 28, 330)
	love.graphics.print(
		"If the quad differs from the full texture, inspect Quad refresh and render2d.SetUV usage.",
		28,
		350
	)
	love.graphics.print(
		"If all panels are washed out, inspect canvas/target format selection and gamma handling.",
		28,
		370
	)
end
