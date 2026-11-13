local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local water = import("goluwa/render3d/water.lua")
local media = import("goluwa/render3d/media.lua")
local MODE = os.getenv("MODE") or "all"
local NIGHT = os.getenv("NIGHT") == "1"
local media_scene = {}
_G.media_scene = media_scene
weather.SetTimeScale(0)

if NIGHT then
	weather.SetSunDirection(Vec3(0.3, -0.35, -0.5):GetNormalized())
else
	weather.SetSunDirection(Vec3(0.45, 0.5, -0.4):GetNormalized())
end

if os.getenv("FOG") then
	weather.SetGroundFogVisibility(tonumber(os.getenv("FOG")))
end

local function box(name, position, size, material, parent)
	return shapes.Box{
		Name = name,
		Parent = parent,
		Position = position,
		Size = size,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function sphere(name, position, radius, material, parent)
	return shapes.Sphere{
		Name = name,
		Parent = parent,
		Position = position,
		Radius = radius,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function lamp(name, position, color, lumen, parent)
	local entity = Entity.New{Name = name, Parent = parent}
	entity:AddComponent("transform"):SetPosition(position)
	local light = entity:AddComponent("light_point")
	light:SetColor(color)
	light:SetLumen(lumen)
	light:SetSourceRadius(0.1)
	return entity
end

local function ice(config)
	config.Color = Color(1, 1, 1, 1)
	config.Roughness = config.Roughness or 0.05
	config.Metallic = 0
	config.SpecularMultiplier = 0.45
	config.Medium = config.Medium or "ice"
	return shapes.Material(config)
end

local root = Entity.New{Name = "media_scene"}
local concrete = shapes.Material{Color = Color(0.55, 0.55, 0.57, 1), Roughness = 0.8, Metallic = 0}
local grey = shapes.Material{Color = Color(0.85, 0.85, 0.85, 1), Roughness = 0.5, Metallic = 0}
local red = shapes.Material{Color = Color(0.8, 0.1, 0.08, 1), Roughness = 0.5, Metallic = 0}
local cameras = {}

local function camera(name, position, angles)
	cameras[name] = {position = position, angles = angles}
end

if MODE == "ocean" then
	render3d.SetOceanEnabled(true)
	render3d.SetOceanLevel(0)
	water.SetOcean{Medium = os.getenv("OCEAN_MEDIUM") or "ocean"}
	local seabed = box("seabed", Vec3(0, -9, 0), Vec3(120, 1, 120), concrete, root)

	for i = 1, 6 do
		local x = (i - 3.5) * 5
		box("pillar_" .. i, Vec3(x, -4, -6 - i * 2), Vec3(1.2, 10, 1.2), grey, root)
		sphere("submerged_" .. i, Vec3(x, -2 - i, -2), 1, i % 2 == 0 and red or grey, root)
	end

	box("platform", Vec3(0, 0.6, 6), Vec3(10, 0.4, 6), concrete, root)
	box("shade", Vec3(0, 2.5, 6), Vec3(6, 0.2, 4), concrete, root)
	lamp("underwater_lamp", Vec3(-6, -3, -2), Color(1, 0.9, 0.7, 1), 120000, root)
	lamp("deck_lamp", Vec3(0, 1.6, 6), Color(1, 0.85, 0.6, 1), 60000, root)
	camera("ocean_above", Vec3(0, 3, 22), Vec3(-10, 0, 0))
	camera("ocean_under", Vec3(0, -3, 8), Vec3(5, 0, 0))
	camera("ocean_shade", Vec3(0, 0.6, 14), Vec3(-3, 0, 0))
else
	render3d.SetOceanEnabled(false)
	box("ground", Vec3(0, -0.5, 0), Vec3(90, 1, 70), concrete, root)
	local ice_zone = Entity.New{Name = "ice", Parent = root}

	local function ice_block(name, x, z, material)
		box(name, Vec3(x, 0.55, z), Vec3(1.2, 1.1, 2), material, ice_zone)
	end

	for i, scale in ipairs{0, 1, 4, 16, 64} do
		local preset = table.shallow_copy(media.presets.ice)
		preset.Scattering = media.presets.ice.Scattering * scale
		media.presets["scene_ice_scattering_" .. i] = preset
		ice_block(
			"scattering_" .. i,
			-16 + i * 1.6,
			-4,
			ice{Medium = "scene_ice_scattering_" .. i, MediumDensity = 1.4}
		)
	end

	for i, density in ipairs{0.3, 0.8, 1.6, 3.2} do
		ice_block("density_" .. i, -16 + i * 1.6, -6.5, ice{MediumDensity = density})
	end

	for i, porosity in ipairs{0, 0.1, 0.3, 0.6, 1} do
		ice_block(
			"porosity_" .. i,
			-16 + i * 1.6,
			-9,
			ice{MediumDensity = 1.4, MediumPorosity = porosity}
		)
	end

	for i, entry in ipairs{
		{"ice", 0.3},
		{"ice", 1.6},
		{"lake", 1},
		{"pool", 1},
		{"swamp", 1},
	} do
		sphere(
			"glass_medium_" .. i,
			Vec3(-16 + i * 1.6, 0.6, -12),
			0.6,
			shapes.Material{
				Color = Color(1, 1, 1, 1),
				Roughness = 0.02,
				Metallic = 0,
				Refraction = 1,
				Medium = entry[1],
				MediumDensity = entry[2],
			},
			ice_zone
		)
	end

	sphere(
		"glass_plain",
		Vec3(-16 + 6 * 1.6, 0.6, -12),
		0.6,
		shapes.Material{
			Color = Color(0.3, 0.65, 0.35, 1),
			Roughness = 0.02,
			Metallic = 0,
			Refraction = 1,
			IndexOfRefraction = 1.52,
		},
		ice_zone
	)
	local hollow = Entity.New{Name = "hollow", Parent = root}
	local wall = 0.2
	local ice_wall = ice{MediumDensity = 3.2, MediumThickness = wall}

	local function cube_faces(poly, half, inward)
		local axes = {Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)}

		for axis = 1, 3 do
			local u = axes[axis % 3 + 1]
			local v = axes[(axis + 1) % 3 + 1]

			for _, sign in ipairs{-1, 1} do
				local outward = axes[axis] * sign
				local normal = inward and -outward or outward
				local center = outward * half
				local corners = {
					center - u * half - v * half,
					center + u * half - v * half,
					center + u * half + v * half,
					center - u * half + v * half,
				}
				local uvs = {Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)}

				for _, triangle in ipairs{{1, 2, 3}, {1, 3, 4}} do
					local a, b, c = triangle[1], triangle[2], triangle[3]

					if (corners[b] - corners[a]):GetCross(corners[c] - corners[a]):GetDot(normal) < 0 then
						b, c = c, b
					end

					for _, k in ipairs{a, c, b} do
						poly:AddVertex{pos = corners[k], uv = uvs[k], normal = normal}
					end
				end
			end
		end
	end

	local function hollow_box(name, x)
		local entity = Entity.New{Name = name, Parent = hollow}
		shapes.Polygon{
			Name = "shell",
			Parent = entity,
			Position = Vec3(x, 1.5, -6),
			Polygon = function(poly)
				cube_faces(poly, 1.5, false)
				cube_faces(poly, 1.5 - wall, true)
			end,
			Material = ice_wall,
			RigidBody = false,
		}
		return entity
	end

	local lit = hollow_box("hollow_lit_inside", 0)
	lamp("red", Vec3(-0.45, 1.1, -6), Color(1, 0.1, 0.05, 1), 20000, lit)
	lamp("green", Vec3(0.45, 1.1, -6), Color(0.1, 1, 0.1, 1), 20000, lit)
	hollow_box("hollow_lit_outside", 5)
	local tanks = Entity.New{Name = "tanks", Parent = root}
	local TANK_SIZE, TANK_DEPTH = 3.2, 1.2
	local murky = media.Define(Vec3(0.9, 0.25, 0.6), Vec3(0.35, 0.45, 0.2))
	print("defined medium:", murky)

	for i, medium_name in ipairs{"lake", "pool", "swamp", "glacial", murky} do
		local x = (i - 3) * 4.6
		local z = 8
		local tank = Entity.New{Name = "tank_" .. i, Parent = tanks}
		local height = TANK_DEPTH + 0.3

		for _, wall_def in ipairs{
			{Vec3(0, height / 2, TANK_SIZE / 2 + 0.05), Vec3(TANK_SIZE + 0.2, height, 0.1)},
			{Vec3(0, height / 2, -TANK_SIZE / 2 - 0.05), Vec3(TANK_SIZE + 0.2, height, 0.1)},
			{Vec3(TANK_SIZE / 2 + 0.05, height / 2, 0), Vec3(0.1, height, TANK_SIZE)},
			{Vec3(-TANK_SIZE / 2 - 0.05, height / 2, 0), Vec3(0.1, height, TANK_SIZE)},
		} do
			box("wall", wall_def[1] + Vec3(x, 0, z), wall_def[2], concrete, tank)
		end

		Entity.New{
			Name = "water",
			Parent = tank,
			transform = {Position = Vec3(x, TANK_DEPTH, z)},
			water_volume = {
				Size = Vec3(TANK_SIZE, TANK_DEPTH, TANK_SIZE),
				Medium = medium_name,
				WaveHeight = 0.03,
				WaveLength = 0.6,
				Foam = 0,
			},
		}
		sphere("submerged_a", Vec3(x - 0.9, 0.3, z), 0.3, grey, tank)
		sphere("submerged_b", Vec3(x + 0.9, 0.6, z), 0.3, red, tank)
		box("submerged_block", Vec3(x, 0.25, z + 0.9), Vec3(0.5, 0.5, 0.5), grey, tank)
		lamp("underwater", Vec3(x, 0.45, z - 0.9), Color(1, 0.95, 0.85, 1), 2500, tank)

		if i == 2 then
			box("plate", Vec3(x - 0.8, 2.3, z), Vec3(1.6, 0.1, 3.2), concrete, tank)
			lamp("above", Vec3(x, 3.4, z), Color(1, 1, 1, 1), 15000, tank)
		end
	end

	local fogs = Entity.New{Name = "fog_volumes", Parent = root}

	for i, medium_name in ipairs{"fog", "steam", "smoke", "dust"} do
		local x = -14 + (i - 1) * 4.5
		local z = 18
		local zone = Entity.New{Name = "fog_" .. medium_name, Parent = fogs}
		Entity.New{
			Name = "fog",
			Parent = zone,
			transform = {Position = Vec3(x, 1.8, z)},
			fog_volume = {Size = Vec3(3.6, 3.6, 3.6), Medium = medium_name, Density = 0.35, EdgeSoftness = 0.6},
		}
		sphere("inside", Vec3(x, 0.5, z), 0.5, grey, zone)
		lamp("lamp", Vec3(x + 1.2, 1.4, z), Color(1, 0.95, 0.85, 1), 5000, zone)
	end

	local shaded = Entity.New{Name = "fog_shaded", Parent = fogs}
	Entity.New{
		Name = "fog",
		Parent = shaded,
		transform = {Position = Vec3(6, 2, 18)},
		fog_volume = {Size = Vec3(7, 4, 4), Medium = "smoke", Density = 0.25, EdgeSoftness = 0.8},
	}
	box("plate", Vec3(6, 3.6, 18), Vec3(3, 0.15, 4), concrete, shaded)
	lamp("above", Vec3(6, 6, 18), Color(1, 1, 1, 1), 40000, shaded)
	Entity.New{
		Name = "mist",
		Parent = fogs,
		transform = {Position = Vec3(0, 1.5, 8)},
		fog_volume = {Size = Vec3(28, 3, 8), Medium = "steam", Density = 0.12, HeightFalloff = 0.8, EdgeSoftness = 1.5},
	}
	camera("fog", Vec3(-4, 2.6, 28), Vec3(-8, 0, 0))

	local deep = Entity.New{Name = "deep_pool", Parent = tanks}
	Entity.New{
		Name = "water",
		Parent = deep,
		transform = {Position = Vec3(18, 3, 8)},
		water_volume = {Size = Vec3(7, 3, 7), Medium = "lake", WaveHeight = 0.25, WaveLength = 2.4},
	}
	box("floor", Vec3(18, 0.05, 8), Vec3(7, 0.1, 7), concrete, deep)
	sphere("sunk", Vec3(18, 1, 8), 0.8, red, deep)
	local inside = Entity.New{Name = "inside", Parent = root}
	local INSIDE_Z = -26
	local clear = media.Define(Vec3(0.05, 0.01, 0.003), Vec3(0.0005, 0.0005, 0.0005))
	local milk = media.Define(Vec3(0.01, 0.012, 0.02), Vec3(1.4, 1.4, 1.4))
	local amber = media.Define(Vec3(0.02, 0.18, 0.9), Vec3(0.05, 0.05, 0.05))

	local function inside_body(name, x, shape, material, radius_or_size)
		if shape == "sphere" then
			sphere(name, Vec3(x, radius_or_size, INSIDE_Z), radius_or_size, material, inside)
		else
			box(name, Vec3(x, radius_or_size.y / 2, INSIDE_Z), radius_or_size, material, inside)
		end

		box(name .. "_pillar", Vec3(x, 1.2, INSIDE_Z - 1.6), Vec3(0.7, 2.4, 0.7), red, inside)
		sphere(name .. "_marker", Vec3(x + 1.5, 0.7, INSIDE_Z + 0.8), 0.7, grey, inside)
	end

	inside_body("inside_ice", -26, "sphere", ice{MediumDensity = 1.4}, 3.5)
	inside_body("inside_glass", -16, "sphere", shapes.Material{Color = Color(0.45, 0.9, 0.6, 1), Roughness = 0, Metallic = 0, Refraction = 1, IndexOfRefraction = 1.52}, 3.5)
	inside_body("inside_clear", -6, "sphere", ice{Medium = clear, MediumDensity = 1, Roughness = 0.02}, 3.5)
	inside_body("inside_milk", 4, "sphere", ice{Medium = milk, MediumDensity = 1, Roughness = 0.05}, 3.5)
	inside_body("inside_amber", 14, "sphere", ice{Medium = amber, MediumDensity = 1, Roughness = 0.03}, 3.5)
	inside_body("inside_waves", 25, "box", ice{Medium = clear, MediumDensity = 1, Roughness = 0.02, MediumWaveHeight = 0.25, MediumWaveLength = 3, MediumCaustics = 1}, Vec3(8, 5, 8))
	inside_body("inside_flat", 36, "box", ice{Medium = clear, MediumDensity = 1, Roughness = 0.02}, Vec3(8, 5, 8))
	lamp("inside_lamp", Vec3(-6, 1.2, INSIDE_Z + 1), Color(1, 0.7, 0.4, 1), 60000, inside)
	camera("inside_row", Vec3(5, 4, INSIDE_Z + 22), Vec3(-8, 0, 0))
	camera("inside_ice", Vec3(-26.8, 2.2, INSIDE_Z + 1.2), Vec3(5, 20, 0))
	camera("inside_ice_sky", Vec3(-26, 1.6, INSIDE_Z), Vec3(55, 0, 0))
	camera("inside_glass", Vec3(-16.8, 2.2, INSIDE_Z + 1.2), Vec3(5, 20, 0))
	camera("inside_clear", Vec3(-4.2, 1.8, INSIDE_Z + 1.5), Vec3(2, -30, 0))
	camera("inside_milk", Vec3(4, 1.8, INSIDE_Z), Vec3(5, 0, 0))
	camera("inside_amber", Vec3(14, 1.8, INSIDE_Z + 1), Vec3(30, 0, 0))
	camera("inside_waves", Vec3(25, 1.5, INSIDE_Z + 2), Vec3(40, 0, 0))
	camera("inside_waves_side", Vec3(25, 1.5, INSIDE_Z + 3), Vec3(8, 0, 0))
	camera("inside_flat", Vec3(36, 1.5, INSIDE_Z + 2), Vec3(40, 0, 0))
	camera("overview", Vec3(0, 7, 26), Vec3(-18, 0, 0))
	camera("ice", Vec3(-12, 2.8, 2), Vec3(-14, 0, 0))
	camera("glass", Vec3(-12, 1.6, -5), Vec3(-6, 0, 0))
	camera("hollow", Vec3(2.5, 2.2, 2), Vec3(-10, 0, 0))
	camera("tanks", Vec3(0, 3.2, 16), Vec3(-22, 0, 0))
	camera("deep", Vec3(18, 4, 15), Vec3(-24, 0, 0))
end

function media_scene.Goto(name)
	local view = assert(cameras[name], "no camera " .. tostring(name))
	local camera_object = render3d.GetCamera()
	camera_object:SetPosition(view.position)
	camera_object:SetRotation(QuatDeg3(view.angles.x, view.angles.y, view.angles.z))
	return name
end

function media_scene.Fog(visibility)
	weather.SetGroundFogVisibility(visibility)
end

media_scene.cameras = cameras

do
	local names = {}

	for name in pairs(cameras) do
		names[#names + 1] = name
	end

	table.sort(names)
	print("media_scene cameras:", table.concat(names, ", "))
end

if os.getenv("CAM") then media_scene.Goto(os.getenv("CAM")) end
