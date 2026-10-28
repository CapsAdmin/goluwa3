local Vec3 = import("goluwa/structs/vec3.lua")
return {
	name = "acoustics",
	category = "Acoustics",
	block = "none",
	params = {
		{name = "AcousticAbsorption", default = Vec3(0.06, 0.10, 0.16)},
	},
}
