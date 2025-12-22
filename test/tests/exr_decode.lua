local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping render2d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local png_encode = require("file_formats.png.encode")
local render = require("render.render")
local render2d = require("render2d.render2d")
local fs = require("fs")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Texture = require("render.texture")
local width = 512
local height = 512
local initialized = false

-- Helper function to draw with render2d
local function draw2d(cb)
	render.Initialize({headless = true, width = width, height = height})
	render2d.render2dialize()
	render.BeginFrame()
	render2d.BindPipeline()
	cb()
	render.EndFrame()
end

T.Pending("Decode EXR Texture", function()
	draw2d(function()
		local path = "/home/caps/projects/RTXDI-Assets/environment/adams_place_bridge_4k.exr"
		local tex = Texture.New({
			path = path,
		})
		render2d.SetTexture(tex)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(0, 0, 512, 512)
	end)

	render.Screenshot("test")

	T.ScreenPixel(50, 50, function(r, g, b, a)
		T(r)["~="](0) -- "Red channel should not be zero"
		T(g)["~="](0) -- "Green channel should not be zero"
		T(b)["~="](0) -- "Blue channel should not be zero"
		T(a)["=="](1) -- "Alpha channel should be 1.0"
		return true
	end)
end)
