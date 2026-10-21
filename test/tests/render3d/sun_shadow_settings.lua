local T = import("test/environment.lua")
local attest = import("goluwa/attest.lua")
local weather = import("goluwa/render3d/weather.lua")

T.Test("render3d sun shadow settings are changed by category and handed out as copies", function()
	weather.ResetSunShadow()
	weather.SetSunShadow("cascades", {count = 3, zoom = {2, 1, 1, 1}})
	weather.SetSunShadow("inset", {distance = 24})
	local cascades = weather.GetSunShadow("cascades")
	T(cascades.count)["=="](3)
	T(cascades.zoom[1])["=="](2)
	T(cascades.size)["=="](8192)
	T(weather.GetSunShadow("inset").distance)["=="](24)
	cascades.count = 1
	cascades.zoom[1] = 9
	T(weather.GetSunShadow("cascades").count)["=="](3)
	T(weather.GetSunShadow("cascades").zoom[1])["=="](2)
	weather.ResetSunShadow()
	T(weather.GetSunShadow("cascades").count)["=="](1)
	T(weather.GetSunShadow("inset").distance)["=="](30)
end)

T.Test("render3d sun shadow settings reject names that do not exist", function()
	attest.fails(
		function()
			weather.SetSunShadow("cascades", {sizee = 1})
		end,
		"no sun shadow setting cascades.sizee"
	)
end)
