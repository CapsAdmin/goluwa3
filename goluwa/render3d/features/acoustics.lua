local Vec3 = import("goluwa/structs/vec3.lua")
return {
	name = "acoustics",
	category = "Acoustics",
	block = "none",
	params = {
		{name = "AcousticAbsorption", default = Vec3(0.06, 0.10, 0.16)},
		{name = "AcousticScattering", default = Vec3(0.1, 0.2, 0.3)},
		{name = "AcousticDensity", default = 1500},
		{name = "AcousticSurfaceMass", default = 20},
		{name = "AcousticRainEmission", default = Vec3(0.6, 0.8, 0.9)},
		{name = "AcousticWindEmission", default = Vec3(0, 0, 0)},
	},
}
