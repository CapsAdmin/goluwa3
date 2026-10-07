local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")

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
	return math.abs(ar - br) + math.abs(ag - bg) + math.abs(ab - bb) < 0.01 * (ar + ag + ab)
end

T.Test3D("Graphics render3d translucent materials draw forward over the lit scene", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/volumetric_fog.lua"),
			import("goluwa/render3d/passes/translucent.lua"),
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
		add_box(polygon3d, created, Vec3(0, 0, -5), Vec3(0.5, 0.5, 0.05), pane)
		add_box(polygon3d, created, Vec3(-3, 0, -14), Vec3(0.5, 0.5, 0.05), pane)
		add_box(polygon3d, created, Vec3(3, 0, -14), Vec3(0.5, 0.5, 0.05), pane)
		draw()
		draw()
		local albedo = gbuffer_layout.GetTexture("albedo"):Download()
		local opaque = post_source.GetOpaqueSceneTexture():Download()
		local final = post_source.GetRawSceneSourceTexture():Download()
		local center = math.floor(opaque.width / 2)
		local r, g = albedo:GetPixel(center, center)
		T(r > g)["=="](true)
		r, g = albedo:GetPixel(center + 4, center + 1)
		T(r > g)["=="](true)
		T(same_pixel(opaque, final, center, center))["=="](false)
		local _, opaque_g = opaque:GetPixelFloat(center, center)
		local _, final_g = final:GetPixelFloat(center, center)
		T(final_g > opaque_g)["=="](true)
		T(same_pixel(opaque, final, center - 55, center))["=="](true)
		T(same_pixel(opaque, final, center + 55, center))["=="](true)
		T(same_pixel(opaque, final, center - 120, center + 60))["=="](true)
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

T.Test3D("Graphics render3d refractive materials transmit and blur what is behind them", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/volumetric_fog.lua"),
			import("goluwa/render3d/passes/translucent.lua"),
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
		local red = Material.New{
			ColorMultiplier = Color(0.8, 0.1, 0.1, 1),
			RoughnessMultiplier = 1,
			MetallicMultiplier = 0,
		}
		local green = Material.New{
			ColorMultiplier = Color(0.1, 0.8, 0.1, 1),
			RoughnessMultiplier = 1,
			MetallicMultiplier = 0,
		}
		local clear = Material.New{
			RoughnessMultiplier = 0.1,
			MetallicMultiplier = 0,
			Refraction = 1,
			RefractionThickness = 0,
		}
		local frosted = Material.New{
			RoughnessMultiplier = 0.6,
			MetallicMultiplier = 0,
			Refraction = 1,
			RefractionThickness = 0,
		}
		add_box(polygon3d, created, Vec3(-3, 0, -10), Vec3(3, 6, 0.1), red)
		add_box(polygon3d, created, Vec3(3, 0, -10), Vec3(3, 6, 0.1), green)
		add_box(polygon3d, created, Vec3(-2, 1.5, -5), Vec3(1, 1, 0.02), clear)
		add_box(polygon3d, created, Vec3(0, -1.5, -5), Vec3(1.5, 1, 0.02), frosted)
		draw()
		draw()
		local albedo = gbuffer_layout.GetTexture("albedo"):Download()
		local opaque = post_source.GetOpaqueSceneTexture():Download()
		local final = post_source.GetRawSceneSourceTexture():Download()
		local center = math.floor(opaque.width / 2)
		local quarter = math.floor(opaque.width / 4)
		local r, g = albedo:GetPixel(center - 5, center + quarter)
		T(r > g)["=="](true)
		local opaque_r, opaque_g = opaque:GetPixelFloat(center - quarter / 2, center - quarter / 2)
		local final_r, final_g = final:GetPixelFloat(center - quarter / 2, center - quarter / 2)
		T(same_pixel(opaque, final, center - quarter / 2, center - quarter / 2))["=="](false)
		T(final_r > opaque_r * 0.7)["=="](true)
		T(final_g < final_r * 0.5)["=="](true)
		opaque_r, opaque_g = opaque:GetPixelFloat(center - 2, center + quarter / 2)
		final_r, final_g = final:GetPixelFloat(center - 2, center + quarter / 2)
		T(final_g > opaque_g * 2)["=="](true)
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

T.Test3D("Graphics render3d translucent surfaces blend in depth order, whatever order they draw in", function(draw)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/volumetric_fog.lua"),
			import("goluwa/render3d/passes/translucent.lua"),
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
		local wall = Material.New{
			ColorMultiplier = Color(0.5, 0.5, 0.5, 1),
			RoughnessMultiplier = 1,
			MetallicMultiplier = 0,
		}
		local red = Material.New{
			ColorMultiplier = Color(0.9, 0.05, 0.05, 0.7),
			RoughnessMultiplier = 1,
			MetallicMultiplier = 0,
			Translucent = true,
		}
		local blue = Material.New{
			ColorMultiplier = Color(0.05, 0.05, 0.9, 0.7),
			RoughnessMultiplier = 1,
			MetallicMultiplier = 0,
			Translucent = true,
		}
		add_box(polygon3d, created, Vec3(0, 0, -10), Vec3(20, 20, 0.1), wall)
		add_box(polygon3d, created, Vec3(14, 0, -6), Vec3(16, 0.3, 0.02), red)
		add_box(polygon3d, created, Vec3(0, 0, -8), Vec3(1, 1, 0.02), blue)
		draw()
		draw()
		local final = post_source.GetRawSceneSourceTexture():Download()
		local center = math.floor(final.width / 2)
		local r, _, b = final:GetPixelFloat(center + 4, center)
		T(r > b * 1.5)["=="](true)
		r, _, b = final:GetPixelFloat(center - 4, center + math.floor(final.width / 24))
		T(b > r * 1.5)["=="](true)
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
