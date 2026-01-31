local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping render2d comprehensive tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local render = require("render.render")
local render2d = require("render2d.render2d")
local fs = require("fs")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local test2d = require("test.test2d")
local Texture = require("render.texture")
local width = 512
local height = 512
local initialized = false
local path = "/home/caps/projects/RTXDI-Assets/environment/adams_place_bridge_4k.exr"

T.Test("Decode EXR Texture", function()
	if not fs.is_file(path) then
		return T.Unavailable("EXR file not found at " .. path)
	end

	do return end -- pending anyway!

	test2d.draw(function()
		local tex = Texture.New({
			path = path,
		})
		render2d.SetTexture(tex)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(0, 0, 512, 512)
	end)

	T.ScreenPixel(50, 50, function(r, g, b, a)
		T(r)["~="](0) -- "Red channel should not be zero"
		T(g)["~="](0) -- "Green channel should not be zero"
		T(b)["~="](0) -- "Blue channel should not be zero"
		T(a)["=="](1) -- "Alpha channel should be 1.0"
		return true
	end)
end)
