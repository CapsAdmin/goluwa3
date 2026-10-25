local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")

local function add_wall(polygon3d, created, position, material)
	local ent = Entity.New{Name = "subsurface_test_wall"}
	created[#created + 1] = ent
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetScale(Vec3(4, 6, 0.1))
	ent:AddComponent("visual")
	local p = Entity.New{Name = "subsurface_test_wall_p", Parent = ent}
	created[#created + 1] = p
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(material)
	ent.visual:BuildAABB()
	ent.visual:SetUseOcclusionCulling(false)
end

T.Test3D("Graphics render3d subsurface pixels keep the light of a plain surface where it is even", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/subsurface.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local created = {}
	local ok, err = pcall(function()
		local camera = render3d.GetCamera()
		camera:SetFOV(math.rad(90))
		camera:SetPosition(Vec3(0, 0, 0))
		camera:SetAngles{x = 0, y = 0, z = 0}

		local function material(subsurface)
			return Material.New{
				ColorMultiplier = Color(0.8, 0.4, 0.3, 1),
				RoughnessMultiplier = 1,
				MetallicMultiplier = 0,
				Subsurface = subsurface,
			}
		end

		add_wall(polygon3d, created, Vec3(-4, 0, -6), material(1))
		add_wall(polygon3d, created, Vec3(4, 0, -6), material(0))
		draw()
		draw()
		local diffuse = render3d.pipelines.lighting:GetFramebuffer(1):GetAttachment(2):Download()
		local lit = post_source.GetOpaqueSceneTexture():Download()
		local y = math.floor(lit.height / 2)
		local left = math.floor(lit.width * 0.25)
		local right = math.floor(lit.width * 0.75)
		local _, _, _, left_strength = diffuse:GetPixelFloat(left, y)
		local _, _, _, right_strength = diffuse:GetPixelFloat(right, y)
		T(left_strength)[">"](0.9)
		T(right_strength)["=="](0)
		local left_r, left_g, left_b = lit:GetPixelFloat(left, y)
		local right_r, right_g, right_b = lit:GetPixelFloat(right, y)
		T(left_r > 0)["=="](true)
		T(math.abs(left_r - right_r) < 0.05 * right_r)["=="](true)
		T(math.abs(left_g - right_g) < 0.05 * right_g)["=="](true)
		T(math.abs(left_b - right_b) < 0.05 * right_b)["=="](true)
	end)

	for _, ent in ipairs(created) do
		if ent:IsValid() then ent:Remove() end
	end

	polygon3d:Remove()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)
