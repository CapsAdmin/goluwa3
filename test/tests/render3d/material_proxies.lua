local T = import("test/environment.lua")
local material_proxies = import("goluwa/render3d/material_proxies.lua")
local vmt = [[
"UnlitGeneric"
{
	"$basetexture" "some/texture"
	"$basetexturetransform" "center .5 .5 scale 2 2 rotate 0 translate 0 0"
	"$scrollvar" 0.5
	"$offset" "[0.25 0]"
	"$color" "{255 128 0}"
	"Proxies"
	{
		// comment
		"TextureScroll"
		{
			"texturescrollvar" "$basetexturetransform"
			"texturescrollrate" "$scrollvar"
			"texturescrollangle" 90
		}
		"LinearRamp"
		{
			"rate" 2
			"initialvalue" 1
			"resultvar" "$ramp"
		}
		"Sine"
		{
			"sineperiod" 4
			"sinemin" 0
			"sinemax" 2
			"resultvar" "$color[1]"
		}
		"Add"
		{
			"srcvar1" "$ramp"
			"srcvar2" "$ramp"
			"resultvar" "$doubled"
		}
		"TextureTransform"
		{
			"translatevar" "$offset"
			"resultvar" "$texture2transform"
		}
		"AnimatedTexture"
		{
			"animatedtexturevar" "$basetexture"
			"animatedtextureframenumvar" "$frame"
			"animatedtextureframerate" 10
		}
	}
}
]]

T.Test("material proxies compile to lua that updates variables in order", function()
	local fn, variables = material_proxies.Compile(vmt)
	T(fn)["~="](nil)
	T(variables.color[1])["=="](1)
	variables.frame_count_basetexture = 4
	fn(variables, 1.5)
	T(variables.ramp)["=="](4)
	T(variables.doubled)["=="](8)
	T(math.abs(variables.color[2] - (math.sin(2 * math.pi * 1.5 / 4) + 1)) < 1e-9)["=="](true)
	T(variables.frame)["=="](3)
	local scroll = variables.basetexturetransform
	T(math.abs(scroll[3]) < 1e-6)["=="](true)
	T(math.abs(scroll[6] - 0.75) < 1e-6)["=="](true)
	T(variables.texture2transform[3])["=="](0.25)
end)

T.Test("material proxies are nil without a proxies block", function()
	T(material_proxies.Compile([["UnlitGeneric" { "$basetexture" "x" }]]))["=="](nil)
end)
