local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fs = import("goluwa/fs.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Texture = import("goluwa/render/texture.lua")
local width = 512
local height = 512
local initialized = false
local path = "/home/caps/projects/RTXDI-Assets/environment/adams_place_bridge_4k.exr"

T.Pending("Decode EXR Texture", function()
	if not fs.is_file(path) then
		return T.Unavailable("EXR file not found at " .. path)
	end

	local tex = Texture.New{
		path = path,
	}
	render2d.SetTexture(tex)
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(0, 0, 512, 512)
	return function()
		T.AssertScreenPixel{
			pos = {50, 50},
			color = {
				function(r, g, b, a)
					T(r)["~="](0) -- "Red channel should not be zero"
					T(g)["~="](0) -- "Green channel should not be zero"
					T(b)["~="](0) -- "Blue channel should not be zero"
					T(a)["=="](1) -- "Alpha channel should be 1.0"
					return true
				end,
			},
		}
	end
end)
