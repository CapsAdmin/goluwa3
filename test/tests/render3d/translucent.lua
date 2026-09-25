local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")

-- a box from the unit cube (which spans -1..1)
local function add_box(polygon3d, created, position, scale, material)
	local ent = Entity.New{Name = "translucent_test_box"}
	created[#created + 1] = ent
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetScale(scale)
	ent:AddComponent("visual")
	local p = Entity.New{Name = "translucent_test_box_p", Parent = ent}
	created[#created + 1] = p
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(material)
	ent.visual:BuildAABB()
	ent.visual:SetUseOcclusionCulling(false)
end

local function same_pixel(a, b, x, y)
	local ar, ag, ab = a:GetPixelFloat(x, y)
	local br, bg, bb = b:GetPixelFloat(x, y)
	return math.abs(ar - br) + math.abs(ag - bg) + math.abs(ab - bb) < 1e-3
end

T.Test3D("Graphics render3d translucent materials draw forward over the lit scene", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/translucent.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local created = {}
	local ok, err = pcall(function()
		local camera = render3d.GetCamera()
		camera:SetFOV(math.rad(90))
		camera:SetPosition(Vec3(0, 0, 0))
		camera:SetAngles{x = 0, y = 0, z = 0}
		local wall = Material.New{
			ColorMultiplier = Color(0.8, 0.2, 0.2, 1),
			RoughnessMultiplier = 1,
			MetallicMultiplier = 0,
		}
		local pane = Material.New{
			ColorMultiplier = Color(0.2, 0.9, 0.2, 0.5),
			RoughnessMultiplier = 1,
			MetallicMultiplier = 0,
			Translucent = true,
		}
		add_box(polygon3d, created, Vec3(0, 0, -10), Vec3(6, 6, 0.1), wall)
		-- in front of the wall, covering the center of the screen
		add_box(polygon3d, created, Vec3(0, 0, -5), Vec3(0.5, 0.5, 0.05), pane)
		-- behind the wall, where only the depth test keeps it out of view
		add_box(polygon3d, created, Vec3(-3, 0, -14), Vec3(0.5, 0.5, 0.05), pane)
		add_box(polygon3d, created, Vec3(3, 0, -14), Vec3(0.5, 0.5, 0.05), pane)
		draw()
		draw()
		local albedo = render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(1):Download()
		local opaque = post_source.GetOpaqueSceneTexture():Download()
		local final = post_source.GetRawSceneSourceTexture():Download()
		local center = math.floor(opaque.width / 2)
		-- the gbuffer holds the wall behind the pane, not a dithered pane
		local r, g = albedo:GetPixel(center, center)
		T(r > g)["=="](true)
		r, g = albedo:GetPixel(center + 4, center + 1)
		T(r > g)["=="](true)
		-- the pane is blended over the wall
		T(same_pixel(opaque, final, center, center))["=="](false)
		local _, opaque_g = opaque:GetPixelFloat(center, center)
		local _, final_g = final:GetPixelFloat(center, center)
		T(final_g > opaque_g)["=="](true)
		-- and nothing else is touched: not the wall beside it, nor where the
		-- panes behind the wall would be
		T(same_pixel(opaque, final, center - 55, center))["=="](true)
		T(same_pixel(opaque, final, center + 55, center))["=="](true)
		T(same_pixel(opaque, final, 8, 8))["=="](true)
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
