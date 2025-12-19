local Light = require("components.light")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local render3d = require("graphics.render3d")
local Texture = require("graphics.texture")
local sun = Light.CreateDirectional(
	{
		direction = Quat(-0.4, 0.5, 0.3, 0.7), --:SetAngles(Deg3(50, -30, 0)):GetForward(),
		color = {1.0, 0.98, 0.95},
		intensity = 3.0,
		name = "Sun",
		cast_shadows = true,
		shadow_config = {
			ortho_size = 5,
			near_plane = 1,
			far_plane = 500,
		},
	}
)
render3d.SetSunLight(sun)
render3d.SetEnvironmentTexture(Texture.New({
	path = "/home/caps/projects/hdr.png",
	mip_map_levels = "auto",
}))
