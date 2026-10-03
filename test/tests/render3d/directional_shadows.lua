local T = import("test/environment.lua")
import("goluwa/render3d/render3d.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local Color = import("goluwa/structs/color.lua")

T.Test("render3d primary sun color is the sun light's color", function()
	local lights = {{Type = "light_point"}, {Type = "light_sun", Color = Color(1, 0.5, 0.25, 1)}}
	local color = directional_shadows.GetPrimarySunColor(lights)
	T(color.x)["=="](1)
	T(color.y)["=="](0.5)
	T(color.z)["=="](0.25)
	color = directional_shadows.GetPrimarySunColor({})
	T(color.x + color.y + color.z)["=="](3)
end)
