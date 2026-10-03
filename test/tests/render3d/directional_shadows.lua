local T = import("test/environment.lua")
-- the render3d modules import each other in a loop that only loads from render3d
import("goluwa/render3d/render3d.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local Color = import("goluwa/structs/color.lua")

T.Test("render3d primary sun color is the sun light's color", function()
	-- weather tints the sun with the atmosphere's transmittance through its color
	local lights = {{Type = "light_point"}, {Type = "light_sun", Color = Color(1, 0.5, 0.25, 1)}}
	local color = directional_shadows.GetPrimarySunColor(lights)
	T(color.x)["=="](1)
	T(color.y)["=="](0.5)
	T(color.z)["=="](0.25)
	color = directional_shadows.GetPrimarySunColor({})
	T(color.x + color.y + color.z)["=="](3)
end)
