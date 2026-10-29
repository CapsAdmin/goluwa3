local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")

T.Test3D("surface overlays shade the gbuffer of one visual and expire", function(draw)
	local sphere = shapes.Sphere{
		Position = Vec3(0, 0, 0),
		Radius = 1,
		Material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0.5, Metallic = 0},
		Collision = false,
		RigidBody = false,
	}
	local other = shapes.Sphere{
		Position = Vec3(4, 0, 0),
		Radius = 1,
		Material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0.5, Metallic = 0},
		Collision = false,
		RigidBody = false,
	}
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(2, 6, 0))
	cam:SetRotation(Quat():SetAngles(Deg3(-90, 0, 0)))
	cam:SetFOV(math.rad(50))
	cam:SetNearZ(0.1)
	cam:SetFarZ(100)
	local size = render3d.GetRenderSize()

	local function albedo(x)
		for _ = 1, 4 do
			draw()
		end

		local r, g, b = gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x * x), math.floor(size.y / 2))
		return r + g + b
	end

	local get_time = surface_overlays.GetTime
	local now = 100

	function surface_overlays.GetTime()
		return now
	end

	local left_before, right_before = albedo(0.2), albedo(0.8)
	local handle = surface_overlays.Add(sphere.visual, "void_rift", {FadeIn = 0.01, Duration = 0})
	now = now + 1
	T(albedo(0.2))["<"](left_before * 0.5)
	T(albedo(0.8))["~"](right_before, 3)
	T(surface_overlays.GetActiveCount())["=="](1)
	handle:Remove(0.5)
	now = now + 1
	T(albedo(0.2))["~"](left_before, 3)
	T(surface_overlays.GetActiveCount())["=="](0)
	surface_overlays.GetTime = get_time
	sphere:Remove()
	other:Remove()
end)

T.Test3D("surface overlays shade translucent meshes", function(draw)
	local post_source = import("goluwa/render3d/post_source.lua")
	local Material = import("goluwa/render3d/material.lua")
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
	local wall = shapes.Box{
		Position = Vec3(0, 0, -10),
		Size = Vec3(12, 12, 0.2),
		Material = shapes.Material{Color = Color(0.9, 0.9, 0.9, 1), Roughness = 1},
		Collision = false,
		RigidBody = false,
	}
	local pane = shapes.Box{
		Position = Vec3(0, 0, -5),
		Size = Vec3(2, 2, 0.1),
		Material = Material.New{
			ColorMultiplier = Color(0.2, 0.9, 0.2, 0.4),
			RoughnessMultiplier = 1,
			MetallicMultiplier = 0,
			Translucent = true,
		},
		Collision = false,
		RigidBody = false,
	}
	local ok, err = pcall(function()
		local camera = render3d.GetCamera()
		camera:SetFOV(math.rad(60))
		camera:SetPosition(Vec3(0, 0, 0))
		camera:SetAngles{x = 0, y = 0, z = 0}
		local get_time = surface_overlays.GetTime
		local now = 100

		function surface_overlays.GetTime()
			return now
		end

		local function brightness()
			for _ = 1, 4 do
				draw()
			end

			local final = post_source.GetRawSceneSourceTexture():Download()
			local r, g, b = final:GetPixelFloat(math.floor(final.width / 2), math.floor(final.height / 2))
			return r + g + b
		end

		local before = brightness()
		surface_overlays.Add(pane.visual, "void_rift", {FadeIn = 0.01})
		now = now + 1
		T(brightness())["<"](before * 0.9)
		surface_overlays.GetTime = get_time
	end)
	pane:Remove()
	wall:Remove()
	surface_overlays.ClearAll()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end
end)

T.Test3D("a surface overlay layer can take its noise position from the uv", function()
	local sphere = shapes.Sphere{
		Position = Vec3(0, 0, 0),
		Radius = 1,
		Material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0.5, Metallic = 0},
		Collision = false,
		RigidBody = false,
	}
	local plain = surface_overlays.Add(sphere.visual, "crystallize")
	local stretched = surface_overlays.Add(sphere.visual, "crystallize", {UVScale = {0.8, 3}})
	T(plain.layer.uv_space)["=="](0)
	T(stretched.layer.uv_space)["=="](1)
	T(math.abs(stretched.layer.uv_scale[0] - 0.8))["<"](1e-6)
	T(math.abs(stretched.layer.uv_scale[1] - 3))["<"](1e-6)
	surface_overlays.Clear(sphere.visual)
	sphere:Remove()
end)
