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

T.Test3D("surface overlay params are named per kind and a config overrides the default", function()
	local sphere = shapes.Sphere{
		Position = Vec3(0, 0, 0),
		Radius = 1,
		Material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0.5, Metallic = 0},
		Collision = false,
		RigidBody = false,
	}
	local params = surface_overlays.GetParams("radiant")
	local plain = surface_overlays.Add(sphere.visual, "radiant")
	local custom = surface_overlays.Add(sphere.visual, "radiant", {RayCount = 3})
	T(math.abs(plain.layer.params[0] - params[1].Default))["<"](1e-6)
	T(math.abs(plain.layer.params[1] - params[2].Default))["<"](1e-6)
	T(math.abs(custom.layer.params[0] - params[1].Default))["<"](1e-6)
	T(custom.layer.params[1])["=="](3)
	T(custom.layer.params[2])["=="](0)
	T(#surface_overlays.GetParams("charred"))["=="](0)
	surface_overlays.Clear(sphere.visual)
	sphere:Remove()
end)

T.Test3D("a surface overlay fade can be held, read and resumed", function()
	local sphere = shapes.Sphere{
		Position = Vec3(0, 0, 0),
		Radius = 1,
		Material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0.5, Metallic = 0},
		Collision = false,
		RigidBody = false,
	}
	local now = 100
	local get_time = surface_overlays.GetTime

	function surface_overlays.GetTime()
		return now
	end

	local handle = surface_overlays.Add(sphere.visual, "crystallize", {FadeIn = 2, FadeOut = 1})
	now = 101
	T(math.abs(handle:GetFade() - 0.5))["<"](1e-6)
	handle:SetFade(0.25)
	now = 110
	T(handle:GetFade())["=="](0.25)
	handle:SetFade()
	T(math.abs(handle:GetFade() - 0.25))["<"](1e-6)
	now = 111
	T(math.abs(handle:GetFade() - 0.75))["<"](1e-6)
	handle:SetFade(0.5)
	handle:Remove()
	T(math.abs(handle:GetFade() - 0.5))["<"](1e-6)
	now = 111.5
	T(math.abs(handle:GetFade() - 0.375))["<"](1e-6)
	surface_overlays.GetTime = get_time
	surface_overlays.Clear(sphere.visual)
	sphere:Remove()
end)

T.Test("overlay kinds are checked when registered", function()
	local source = surface_overlays.Files.Source.crystallize

	local function broken(change)
		local data = table.copy(source)
		change(data)
		return select(2, pcall(surface_overlays.Register, "overlay_check_kind", data))
	end

	T(broken(function(data)
		data.Params = {{Name = "A", Default = 0}, {Name = "B", Default = 0}, {Name = "C", Default = 0}, {Name = "D", Default = 0}, {Name = "E", Default = 0}}
	end):find("more than 4", 1, true) ~= nil)["=="](true)
	T(broken(function(data)
		data.Params = {{Name = "RayCount", Default = 1}, {Name = "RayCount", Default = 1}}
	end):find("twice", 1, true) ~= nil)["=="](true)
	T(broken(function(data)
		data.Params = {{Name = "Fade", Default = 1}}
	end):find("reserved", 1, true) ~= nil)["=="](true)
	T(broken(function(data)
		data.Params = {{Name = "lower", Default = 1}}
	end):find("PascalCase", 1, true) ~= nil)["=="](true)
	T(broken(function(data)
		data.Params = {{Name = "Strength"}}
	end):find("Default", 1, true) ~= nil)["=="](true)
	T(broken(function(data)
		data.Source = nil
	end):find("Source", 1, true) ~= nil)["=="](true)
	T(#surface_overlays.GetKindNames())[">="](18)
end)

T.Test3D("an overlay edit is checked in the preview shader and a bad one is rolled back", function()
	local original = surface_overlays.Files.Source.crystallize.Source
	local broken = table.copy(surface_overlays.Files.Source.crystallize)
	broken.Source = broken.Source .. "\nbroken_call(1);\n"
	local ok, err = pcall(surface_overlays.UpdateKind, "crystallize", broken)
	T(ok)["=="](false)
	T(err:find("crystallize line", 1, true) ~= nil)["=="](true)
	T(surface_overlays.GetStatus("crystallize"))["=="](err)
	T(surface_overlays.Files.Source.crystallize.Source)["=="](original)
	T(surface_overlays.GetSignature("crystallize"):find("broken_call", 1, true))["=="](nil)
	surface_overlays.UpdateKind("crystallize", table.copy(surface_overlays.Files.Source.crystallize))
	T(surface_overlays.GetStatus("crystallize"))["=="](nil)
	T(surface_overlays.IsRebuilding())["=="](false)
end)

T.Test3D("the overlay preview draws each shape and follows the layer's fade", function()
	local preview = import("goluwa/render3d/surface_overlay_preview.lua")
	local sphere = shapes.Sphere{
		Position = Vec3(0, 0, 0),
		Radius = 1,
		Material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0.5, Metallic = 0},
		Collision = false,
		RigidBody = false,
	}
	local width, height = 160, 120

	local function shade(shape, fade)
		local handle = surface_overlays.Add(sphere.visual, "status_fire", {})
		handle:SetFade(fade)
		local texture = preview.Render(width, height, shape, "status_fire", handle.layer, 3)
		local r, g, b = texture:GetPixel(width / 2, height / 2)
		local corner = {texture:GetPixel(1, 1)}
		surface_overlays.Clear(sphere.visual)
		return r + g + b, corner[1] + corner[2] + corner[3], texture
	end

	for _, shape in ipairs{"sphere", "box"} do
		local off, background, texture = shade(shape, 0)
		local on = shade(shape, 1)
		T(texture:GetWidth())["=="](width)
		T(texture:GetHeight())["=="](height)
		T(off)[">"](background)
		T(math.abs(on - off))[">"](0.05)
	end

	T(preview.GetShapeStatus("sphere"))["=="](nil)
	T(preview.Check("status_fire"))["=="](nil)
	sphere:Remove()
end)
