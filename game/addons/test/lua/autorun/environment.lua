local Light = require("components.light")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Quat = require("structs.quat")
local render3d = require("render3d.render3d")
local skybox = require("render3d.skybox")
local Texture = require("render.texture")
local sun = Light.CreateDirectional(
	{
		rotation = Quat(-0.2, 0.8, 0.4, 0.4), --:SetAngles(Deg3(50, -30, 0)),
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
sun:SetIsSun(true)
sun:SetRotation(Quat(0.4, -0.1, -0.1, -0.9):Normalize())
render3d.SetLights({sun})
skybox.SetTexture(Texture.New({
	path = "/home/caps/projects/hdr.png",
	mip_map_levels = "auto",
}))

do
	local ecs = require("ecs")
	local ffi = require("ffi")
	local Polygon3D = require("render3d.polygon_3d")
	local Material = require("render3d.material")

	local function debug_ent(pos, rot, cb)
		local sphere = ecs.CreateEntity("debug_ent", ecs.GetWorld())
		sphere:AddComponent("transform", {
			position = pos,
			rotation = rot,
		})
		local poly = Polygon3D.New()
		cb(poly)
		poly:AddSubMesh(#poly.Vertices)
		poly:Upload()
		local M = 1
		local R = 0.2
		poly.material = Material.New(
			{
				ColorMultiplier = Color(1.0, 1.0, 1.0, 1.0),
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

	debug_ent(Vec3(0, 5, 0), nil, function(poly)
		poly:CreateSphere()
	end)

	debug_ent(Vec3(3, 1, 3), nil, function(poly)
		poly:CreateCube(1)
	-- Don't call BuildNormals - CreateCube already sets correct normals
	end)
end
