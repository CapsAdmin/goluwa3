local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weather = import("goluwa/render3d/weather.lua")
local scene = {}
scene.spacing = 16
scene.rooms = {}
local wall = shapes.Material{Roughness = 0.9, Metallic = 0, ColorMultiplier = Color(0.8, 0.8, 0.8, 1)}
local floor = shapes.Material{Roughness = 0.9, Metallic = 0, ColorMultiplier = Color(0.75, 0.75, 0.75, 1)}
local prop = shapes.Material{Roughness = 0.7, Metallic = 0, ColorMultiplier = Color(0.9, 0.9, 0.9, 1)}

local function glass(r, g, b)
	return shapes.Material{
		Refraction = 1,
		Roughness = 0.02,
		Metallic = 0,
		ColorMultiplier = Color(r, g, b, 1),
	}
end

local red, green, blue = glass(1, 0.08, 0.08), glass(0.08, 1, 0.08), glass(0.1, 0.25, 1)

local chrome = shapes.Material{Roughness = 0.03, Metallic = 1, ColorMultiplier = Color(0.95, 0.95, 0.95, 1)}

local function ball(cx, cy, cz, radius)
	return shapes.Sphere{
		Position = Vec3(cx, cy, cz),
		Radius = radius,
		Material = chrome,
		Collision = false,
		RigidBody = false,
	}
end

local function box(cx, cy, cz, sx, sy, sz, material)
	return shapes.Box{
		Position = Vec3(cx, cy, cz),
		Size = Vec3(sx, sy, sz),
		Material = material or wall,
		Collision = false,
		RigidBody = false,
	}
end

-- every room is 10 x 10 x 4 (x, z, y) with the -z side open so it can be looked into like a diorama
local W, D, H, T = 10, 10, 4, 0.2

local function shell(ox, options)
	box(ox, -T / 2, 0, W + 2, T, D + 2, options.floor or floor)
	box(ox - W / 2 - T / 2, H / 2, 0, T, H, D, options.side_wall or wall)
	box(ox + W / 2 + T / 2, H / 2, 0, T, H, D, options.side_wall or wall)
	box(ox, H / 2, D / 2 + T / 2, W, H, T, options.back_wall or wall)
end

-- 1: three panes in the ceiling, red green blue
do
	local ox = 0
	shell(ox, {})
	local y = H + T / 2
	local pane = 2
	local cz0, cz1 = -pane / 2, pane / 2
	box(ox, y, (-D / 2 + cz0) / 2, W, T, cz0 + D / 2)
	box(ox, y, (D / 2 + cz1) / 2, W, T, D / 2 - cz1)
	local xs = {-3, 0, 3}
	local materials = {red, green, blue}
	local edges = {-W / 2}

	for i, x in ipairs(xs) do
		box(ox + x, y, 0, pane, 0.05, pane, materials[i])
		edges[#edges + 1] = x - pane / 2
		edges[#edges + 1] = x + pane / 2
	end

	edges[#edges + 1] = W / 2

	for i = 1, #edges, 2 do
		local x0, x1 = edges[i], edges[i + 1]
		box(ox + (x0 + x1) / 2, y, 0, x1 - x0, T, pane)
	end

	box(ox, 0.5, 1.5, 0.8, 1, 0.8, prop)
	ball(ox - 2, 0.7, -2, 0.7)
	scene.rooms[1] = {name = "panes", ox = ox, ev = tonumber(os.getenv("SUN_EV"))}
end

-- 2: closed room, a big blue pane splits it, a point light and a pillar on one side
do
	local ox = scene.spacing
	shell(ox, {})
	box(ox, H + T / 2, 0, W + 2 * T, T, D + 2 * T)
	box(ox, H / 2, -D / 2 - T / 2, W, H, T)
	box(ox, H / 2, 0, 0.05, H - 0.4, 7, blue)
	box(ox - 2.2, 1, -0.5, 0.8, 2, 0.8, prop)
	box(ox + 3, 0.6, 1.5, 1.2, 1.2, 1.2, prop)
	box(ox + 3, 0.3, -2, 0.6, 0.6, 0.6, prop)
	local lamp = Entity.New{Name = "glass_rooms_lamp"}
	lamp:AddComponent("transform"):SetPosition(Vec3(ox - 3.8, 3, -0.5))
	local light = lamp:AddComponent("light_point")
	light:SetLumen(tonumber(os.getenv("LAMP_LUMEN") or "600000"))
	light:SetRange(14)
	scene.rooms[2] = {name = "pane_and_lamp", ox = ox, lamp = lamp, inside = true, ev = tonumber(os.getenv("LAMP_EV") or "11")}
end

-- 3: blue glass walls and ceiling, opaque floor
do
	local ox = scene.spacing * 2
	local g = blue
	box(ox, -T / 2, 0, W + 2, T, D + 2, floor)
	box(ox - W / 2 - 0.025, H / 2, 0, 0.05, H, D, g)
	box(ox + W / 2 + 0.025, H / 2, 0, 0.05, H, D, g)
	box(ox, H / 2, D / 2 + 0.025, W, H, 0.05, g)
	box(ox, H + 0.025, 0, W, 0.05, D, g)
	box(ox - 2, 1, 0, 0.8, 2, 0.8, prop)
	box(ox + 2, 0.6, 2, 1.2, 1.2, 1.2, prop)
	ball(ox, 0.9, -2, 0.9)

	-- the same white carpet three ways, the glass should tint the light on all of them
	local stripes = Texture.New{width = 64, height = 64, format = "r8g8b8a8_unorm"}
	stripes:Shade("return vec4(1.0, 1.0, 1.0, step(0.5, fract(uv.x * 6.0)));")
	local white = Color(0.9, 0.9, 0.9, 1)
	local carpets = {
		{"opaque", shapes.Material{Roughness = 0.9, Metallic = 0, ColorMultiplier = white}},
		{
			"translucent",
			shapes.Material{
				Roughness = 0.9,
				Metallic = 0,
				Translucent = true,
				ColorMultiplier = Color(0.9, 0.9, 0.9, 0.6),
			},
		},
		{
			"alpha_tested",
			shapes.Material{
				Roughness = 0.9,
				Metallic = 0,
				AlphaTest = true,
				AlbedoTexture = stripes,
				ColorMultiplier = white,
			},
		},
	}

	for i, carpet in ipairs(carpets) do
		box(ox + (i - 2) * 3, 0.01, -5.2, 2.4, 0.02, 2.4, carpet[2])
	end

	scene.rooms[3] = {name = "glass_box", ox = ox, ev = tonumber(os.getenv("SUN_EV"))}
end


-- 4, 5, 6: a ceiling of glass panes held by opaque strips, the strips and the panes
--   4 separate entities, one box each
--   5 one visual, two primitives (the strips, the panes), the panes are boxes
--   6 like 5 but the panes are single quads
do
	local teal = glass(0.05, 0.6, 0.55)
	local strip = tonumber(os.getenv("STRIP") or "0.4")
	local pane = (W - 4 * strip) / 3
	local pane_t = tonumber(os.getenv("PANE_T") or "0.05")
	local overlap = tonumber(os.getenv("OVERLAP") or "0")
	local pitch = pane + strip
	local y = H + T / 2
	local strips, panes = {}, {}

	for i = 0, 3 do
		local c = -W / 2 + strip / 2 + i * pitch
		strips[#strips + 1] = {c, 0, strip, D}

		for j = 0, 2 do
			local z0 = -D / 2 + strip + j * pitch + pane / 2
			-- cross strips between the long ones
			if i < 3 then
				if j == 0 then strips[#strips + 1] = {c + strip / 2 + pane / 2, -D / 2 + strip / 2, pane, strip} end

				panes[#panes + 1] = {c + strip / 2 + pane / 2, z0, pane, pane}
				strips[#strips + 1] = {c + strip / 2 + pane / 2, z0 + pane / 2 + strip / 2, pane, strip}
			end
		end
	end

	-- the cross strips of the last row are the room's edge, the first row's are covered by the long ends
	local function add_box(poly, cx, cy, cz, sx, sy, sz)
		local half = Vec3(sx / 2, sy / 2, sz / 2)
		local center = Vec3(cx, cy, cz)
		shapes.BuildPlane(poly, center + Vec3(0, 0, half.z), Vec3(0, 0, 1), half.x, half.y)
		shapes.BuildPlane(poly, center - Vec3(0, 0, half.z), Vec3(0, 0, -1), half.x, half.y)
		shapes.BuildPlane(poly, center + Vec3(half.x, 0, 0), Vec3(1, 0, 0), half.z, half.y)
		shapes.BuildPlane(poly, center - Vec3(half.x, 0, 0), Vec3(-1, 0, 0), half.z, half.y)
		shapes.BuildPlane(poly, center + Vec3(0, half.y, 0), Vec3(0, 1, 0), half.x, half.z)
		shapes.BuildPlane(poly, center - Vec3(0, half.y, 0), Vec3(0, -1, 0), half.x, half.z)
	end

	local function mixed(ox, quads)
		local ceiling = Entity.New{Name = "glass_rooms_ceiling"}
		ceiling:AddComponent("transform")
		ceiling:AddComponent("visual")
		local opaque_poly, glass_poly = Polygon3D.New(), Polygon3D.New()

		for _, s in ipairs(strips) do
			add_box(opaque_poly, ox + s[1], y, s[2], s[3], T, s[4])
		end

		for _, p in ipairs(panes) do
			if quads then
				shapes.BuildPlane(glass_poly, Vec3(ox + p[1], y + (tonumber(os.getenv("GLASS_DY")) or 0), p[2]), Vec3(0, os.getenv("QUAD_UP") and 1 or -1, 0), p[3] / 2 + overlap, p[4] / 2 + overlap)
			else
				add_box(glass_poly, ox + p[1], y, p[2], p[3], pane_t, p[4])
			end
		end

		for _, entry in ipairs{{opaque_poly, wall, "strips"}, {glass_poly, teal, "panes"}} do
			entry[1]:BuildBoundingBox()
			entry[1]:Upload()
			ceiling.visual:CreatePrimitiveEntity(entry[1], entry[2], "glass_rooms_" .. entry[3])
		end

		ceiling.visual:BuildAABB()
	end

	for variant = 1, 3 do
		local ox = scene.spacing * (2 + variant)
		shell(ox, {})
		box(ox, 0.5, 1.5, 0.8, 1, 0.8, prop)

		if variant == 1 then
			for _, s in ipairs(strips) do
				box(ox + s[1], y, s[2], s[3], T, s[4])
			end

			for _, p in ipairs(panes) do
				box(ox + p[1], y, p[2], p[3], pane_t, p[4], teal)
			end
		else
			mixed(ox, variant == 3)
		end

		scene.rooms[#scene.rooms + 1] = {
			name = ({"grid_separate", "grid_mixed", "grid_quads"})[variant],
			ox = ox,
			ev = tonumber(os.getenv("SUN_EV")),
			closeup = true,
		}
	end
end


-- 7: smooth translucent and refractive panes in front of a black wall, objects on the camera side reflect in them
do
	local ox = scene.spacing * 6
	local black = shapes.Material{Roughness = 0.9, Metallic = 0, ColorMultiplier = Color(0.02, 0.02, 0.02, 1)}
	shell(ox, {back_wall = black})
	box(ox + 2, 1.25, 2, 4, 2.5, 0.05, shapes.Material{
		Roughness = 0.02,
		Metallic = 0,
		Translucent = true,
		ColorMultiplier = Color(0.05, 0.05, 0.05, 0.4),
	})
	box(ox - 2, 1.25, 2, 4, 2.5, 0.05, shapes.Material{
		Refraction = 1,
		Roughness = 0.02,
		Metallic = 0,
		ColorMultiplier = Color(0.9, 0.95, 1, 1),
	})
	box(ox - 1, 0.75, -3, 1.5, 1.5, 1.5, shapes.Material{Roughness = 0.6, Metallic = 0, ColorMultiplier = Color(1, 0.1, 0.1, 1)})
	shapes.Sphere{
		Position = Vec3(ox + 4, 0.7, -3),
		Radius = 0.7,
		Material = shapes.Material{Roughness = 0.6, Metallic = 0, ColorMultiplier = Color(0.1, 1, 0.1, 1)},
		Collision = false,
		RigidBody = false,
	}
	scene.rooms[#scene.rooms + 1] = {
		name = "reflect",
		ox = ox,
		ev = tonumber(os.getenv("SUN_EV")),
		view = {Position = Vec3(ox - 4.5, 1.4, -4.5), Rotation = QuatDeg3(-3, tonumber(os.getenv("REFL_YAW") or "217.6"), 0), FOV = math.rad(tonumber(os.getenv("REFL_FOV") or "70"))},
	}
end


-- 8: opaque props on a glossy dark tile floor, for the halo and sheen the reflections put around them
do
	local ox = scene.spacing * 7
	local tile = shapes.Material{
		Roughness = tonumber(os.getenv("TILE_ROUGHNESS") or "0.1"),
		Metallic = 0,
		ColorMultiplier = Color(0.08, 0.09, 0.11, 1),
	}
	local dark_wall = shapes.Material{Roughness = 0.9, Metallic = 0, ColorMultiplier = Color(0.12, 0.12, 0.13, 1)}
	shell(ox, {floor = tile, side_wall = dark_wall, back_wall = dark_wall})
	local brick = shapes.Material{Roughness = 0.8, Metallic = 0, ColorMultiplier = Color(0.45, 0.2, 0.12, 1)}
	local wood = shapes.Material{Roughness = 0.7, Metallic = 0, ColorMultiplier = Color(0.7, 0.7, 0.72, 1)}
	box(ox - 3.5, 0.3, 1, 1.4, 0.6, 3, brick)
	box(ox + 3, 0.22, 0, 0.5, 0.05, 1.8, wood)
	box(ox + 3, 0.1, -0.8, 0.45, 0.2, 0.05, wood)
	box(ox + 3, 0.1, 0.8, 0.45, 0.2, 0.05, wood)
	box(ox, 1.5, 3, 0.7, 3, 0.7, brick)

	if not os.getenv("OPEN_ROOM") then
		box(ox, H + T / 2, 0, W + 2 * T, T, D + 2 * T, dark_wall)
		box(ox, H / 2, -D / 2 - T / 2, W, H, T, dark_wall)
		local lamp = Entity.New{Name = "glass_rooms_floor_lamp"}
		lamp:AddComponent("transform"):SetPosition(Vec3(ox, 3.2, 0))
		local light = lamp:AddComponent("light_point")
		light:SetLumen(tonumber(os.getenv("FLOOR_LAMP") or "20000"))
		light:SetRange(14)
	end

	scene.rooms[#scene.rooms + 1] = {
		name = "reflection_floor",
		ox = ox,
		ev = tonumber(os.getenv("FLOOR_EV")),
		view = {Position = Vec3(ox, 1.3, -4.3), Rotation = QuatDeg3(-6, 180, 0), FOV = math.rad(90)},
	}
end

box(scene.spacing, -2, 0, 100, 3.6, 40, floor)
scene.sun = Vec3(unpack(loadstring("return {" .. (os.getenv("SUN") or "0.25,0.85,0.3") .. "}")())):GetNormalized()
weather.SetSunDirection(scene.sun)
return scene
