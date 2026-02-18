do
	return
end -- this whole test is pending
local T = require("test.environment")
local ffi = require("ffi")
local render = require("render.render")
local render3d = require("render3d.render3d")
local lightprobes = require("render3d.lightprobes")
local Polygon3D = require("render3d.polygon_3d")
local Material = require("render3d.material")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Matrix44 = require("structs.matrix44")
local Texture = require("render.texture")
local transform = require("ecs.components.3d.transform")
local light = require("ecs.components.3d.light")
local fs = require("fs")
local width = 512
local height = 512
local Quat = require("structs.quat")

T.Test3D("Graphics Polygon3D environment map reflection colors", function(draw)
	local function sphere(lp, ly, config)
		local M = config.metallic or 1
		local R = config.roughness or 1
		local color = config.color or Color(1, 1, 1, 1)
		local env_tex = Texture.New(
			{
				width = 1024,
				height = 512,
				format = "r8g8b8a8_unorm",
				mip_map_levels = "auto",
			}
		)
		env_tex:Shade([[
			float theta = uv.y * 3.14159265359;
			float phi = uv.x * 6.28318530718;
			vec3 dir = vec3(
				sin(theta) * sin(phi),
				cos(theta),
				sin(theta) * cos(phi)
			);
			vec3 a = abs(dir);
			if (a.x >= a.y && a.x >= a.z) {
				return dir.x > 0.0 ? vec4(1, 1, 0, 1) : vec4(0, 0, 1, 1); -- +X: Yellow (Right), -X: Blue (Left)
			} else if (a.y >= a.z) {
				return dir.y > 0.0 ? vec4(0, 1, 0, 1) : vec4(1, 0, 1, 1); -- +Y: Green (Up), -Y: Pink (Down)
			} else {
				return dir.z > 0.0 ? vec4(1, 0, 0, 1) : vec4(0, 1, 1, 1); -- +Z: Red (Back), -Z: Teal (Front)
			}
		]])
		lightprobes.SetStarsTexture(env_tex)
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, -10))
		cam:SetRotation(Quat(0, 0, 0, 1))
		cam:SetFOV(math.rad(45))
		cam:SetOrthoMode(false)
		Entity.New(
			{
				transform = {
					Rotation = Quat(0, 0, 0, 1):Normalize(),
				},
				light = {
					LightType = "sun",
					Color = Color(1, 1, 1),
					Intensity = 0,
				},
			}
		)
		local mat = Material.New()
		mat:SetColorMultiplier(color)
		mat:SetMetallicRoughnessTexture(
			Texture.New(
				{
					width = 1,
					height = 1,
					format = "r8g8b8a8_unorm",
					buffer = ffi.new(
						"uint8_t[4]",
						{
							255,
							255 * R,
							255 * M,
							255,
						}
					),
				}
			)
		)
		local r = 10
		render3d.GetCamera():SetFOV(0.001 * r)
		render3d.GetCamera():SetPosition(Vec3(0, 0, 2000 / r))
		local poly = Polygon3D.New()
		poly:CreateSphere()
		poly:BuildNormals()
		poly:AddSubMesh(#poly.Vertices)
		poly:Upload()
		local draw_listener = event.AddListener("Draw3DGeometry", "test_draw", function(cmd)
			local sun = render3d.GetLights()[1]
			sun:SetRotation(Quat():SetAngles(Deg3(lp, ly, 0)))
			render3d.SetMaterial(mat)
			render3d.UploadGBufferConstants(cmd)
			poly:Draw(cmd)
		end)
		draw()
		render3d.SetWorldMatrix(Matrix44())
		event.RemoveListener("Draw3DGeometry", "test_draw")
	end

	T.Test3D("Graphics Polygon3D environment map reflection colors", function()
		sphere(90, 0, {metallic = 0.5, roughness = 0.1, color = Color(1, 1, 1, 1)})
		local tolerance = 0.6
		-- Center: Blue (Left -X)
		T.AssertScreenPixel({pos = {256, 256}, color = {0, 0, 1, 1}, tolerance = tolerance})
		-- Top: Green (Up +Y)
		T.AssertScreenPixel({pos = {256, 128}, color = {0, 1, 0, 1}, tolerance = tolerance})
		-- Bottom: Pink (Down -Y)
		T.AssertScreenPixel({pos = {256, 384}, color = {1, 0, 1, 1}, tolerance = tolerance})
		-- Left: Red (Back +Z)
		T.AssertScreenPixel({pos = {128, 256}, color = {1, 0, 0, 1}, tolerance = tolerance})
		-- Right: Teal (Front -Z)
		T.AssertScreenPixel({pos = {384, 256}, color = {0, 1, 1, 1}, tolerance = tolerance})
		-- Rim: Yellow (Right +X)
		T.AssertScreenPixel({pos = {256, 10}, color = {1, 1, 0, 1}, tolerance = tolerance})
	end)
end)
