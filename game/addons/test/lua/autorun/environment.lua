local Light = require("components.light")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local render3d = require("graphics.render3d")
local Texture = require("graphics.texture")
local sun = Light.CreateDirectional(
	{
		direction = Vec3(0, 0, 0), --:SetAngles(Deg3(50, -30, 0)):GetForward(),
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
render3d.SetLightDirection(Quat(-0.4, 0.5, 0.3, 0.7):GetForward():Unpack())
render3d.SetEnvironmentTexture(Texture.New({
	path = "/home/caps/projects/hdr.png",
	mip_map_levels = "auto",
}))

do
	local ecs = require("ecs")
	local ffi = require("ffi")
	local Polygon3D = require("graphics.polygon_3d")
	local Material = require("graphics.material")
	local sphere = ecs.CreateEntity("sphere", ecs.GetWorld())
	sphere:AddComponent("transform", {
		position = Vec3(0, 5, 0),
	})
	local poly = Polygon3D.New()
	poly:CreateSphere()
	poly:AddSubMesh(#poly.Vertices)
	poly:Upload()
	local M = 1
	local R = 0.2
	poly.material = Material.New(
		{
			base_color_factor = {1.0, 1.0, 1.0, 1.0},
			metallic_roughness_texture = Texture.New(
				{
					width = 1,
					height = 1,
					format = "r8g8b8a8_unorm",
					buffer = ffi.new("uint8_t[4]", {0, 255 * R, 255 * M}), -- roughness=1.0, metallic=0.0
				}
			),
		}
	)
	sphere:AddComponent("model", {
		mesh = poly,
	})
end
