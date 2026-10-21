-- glw: --3d
local frame_benchmark = import("goluwa/render3d/frame_benchmark.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weather = import("goluwa/render3d/weather.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ORIGIN = Vec3(0, 400, 0)
local SPACING = 120
local cells = {}
local lights = {}
local shared = ""

local function material(config)
	return shapes.Material(config)
end

local function quad(name, center, yaw, width, height, mat)
	local ent = shapes.Polygon{
		Name = name,
		Position = center,
		Rotation = QuatDeg3(0, yaw, 0),
		Polygon = function(poly)
			local w, h = width / 2, height / 2
			local p = {Vec3(-w, -h, 0), Vec3(w, -h, 0), Vec3(w, h, 0), Vec3(-w, h, 0)}
			local uv = {Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)}

			for _, tri in ipairs{{1, 3, 2}, {1, 4, 3}} do
				for _, k in ipairs(tri) do
					poly:AddVertex{pos = p[k], uv = uv[k], normal = Vec3(0, 0, 1)}
				end
			end
		end,
		Material = mat,
		RigidBody = false,
		Collision = false,
	}
	test_scene.GetRoot():AddChild(ent)
	return ent
end

local grid = material{
	Color = [[
		vec2 line = step(0.94, fract(uv * 24.0));
		return vec4(vec3(mix(0.7, 0.08, max(line.x, line.y))), 1.0);
	]],
	Roughness = 0.6,
	Metallic = 0,
}
local ramp = "return vec4(mix(0.03, 1.0, uv.x));"

local function cell(name, add, config)
	local index = #cells + 1
	local center = ORIGIN + Vec3(index * SPACING, 0, 0)
	add(center)
	cells[#cells + 1] = table.merge({name = name, center = center}, config or {})
end

local function sphere(center, radius, mat)
	test_scene.GetRoot():AddChild(
		shapes.Sphere{
			Position = center,
			Radius = radius,
			Material = mat,
			Collision = false,
			RigidBody = false,
		}
	)
end

local function build()
	test_scene.Reset{sun = {elevation = 40, azimuth = 30}, clouds = {}}

	cell("matte plane", function(c)
		quad(
			"matte",
			c,
			0,
			60,
			40,
			material{Color = Color(0.5, 0.45, 0.4, 1), Roughness = ramp, Metallic = 0}
		)
	end)

	cell("glossy dielectric ramp", function(c)
		quad(
			"glossy",
			c,
			0,
			60,
			40,
			material{Color = Color(0.7, 0.2, 0.15, 1), Roughness = ramp, Metallic = 0}
		)
	end)

	cell("metal ramp under the sky", function(c)
		quad(
			"metal",
			c,
			0,
			60,
			40,
			material{Color = Color(1, 0.78, 0.34, 1), Roughness = ramp, Metallic = 1}
		)
	end)

	cell("layers: clearcoat, sheen, secondary specular", function(c)
		quad(
			"layers",
			c,
			0,
			60,
			40,
			material{
				Color = Color(0.1, 0.2, 0.6, 1),
				Roughness = 0.5,
				Metallic = 0,
				Clearcoat = 1,
				ClearcoatRoughness = 0.1,
				Sheen = 1,
				SheenRoughness = 0.4,
				SecondarySpecular = 1,
				SecondarySpecularRoughness = 0.3,
			}
		)
	end)

	local function corridor(roughness)
		return function(c)
			quad(
				"mirror",
				c,
				0,
				60,
				40,
				material{Color = Color(0.95, 0.95, 0.95, 1), Roughness = roughness, Metallic = 1}
			)
			quad("behind", c + Vec3(0, 0, 14), 180, 60, 40, grid)
		end
	end

	cell("smooth metal reflecting geometry", corridor(0.02), {offset = Vec3(0, 0, 7)})
	cell("rough metal reflecting geometry", corridor(0.3), {offset = Vec3(0, 0, 7)})

	cell(
		"glass panes in front of a wall",
		function(c)
			quad("wall", c, 0, 60, 40, grid)

			for i = 1, 3 do
				quad(
					"pane" .. i,
					c + Vec3(0, 0, i * 1.2),
					0,
					60,
					40,
					material{
						Color = Color(1, 1, 1, 1),
						Roughness = i == 1 and 0.02 or i == 2 and 0.15 or 0.4,
						Metallic = 0,
						Refraction = 1,
						IndexOfRefraction = 1.5,
						RefractionThickness = 0.02,
					}
				)
			end
		end,
		{offset = Vec3(0, 0, 6)}
	)

	cell(
		"glass spheres",
		function(c)
			quad("wall", c, 0, 60, 40, grid)

			for x = -7, 7 do
				for y = -3, 3 do
					sphere(
						c + Vec3(x * 1.1, y * 1.1, 3),
						0.5,
						material{
							Color = Color(1, 1, 1, 1),
							Roughness = (x + 7) / 14 * 0.5,
							Metallic = 0,
							Refraction = 1,
							IndexOfRefraction = 1.2 + (y + 3) / 6 * 0.8,
						}
					)
				end
			end
		end,
		{offset = Vec3(0, 0, 8)}
	)

	cell(
		"transmission sheets around a light",
		function(c)
			for x = -8, 8 do
				for y = -4, 4 do
					quad(
						"sheet",
						c + Vec3(x * 1.2, y * 1.2, 3),
						25,
						1.1,
						1.1,
						material{
							Color = Color(0.45, 0.6, 0.2, 1),
							Roughness = 1,
							Metallic = 0,
							DoubleSided = true,
							DiffuseTransmission = 0.6,
							TransmissionScattering = 0.4,
						}
					)
				end
			end

			local lamp = Entity.New{Name = "bench_lamp"}
			lamp:AddComponent("transform"):SetPosition(c + Vec3(0, 0, 1))
			lamp:AddComponent("light_point"):SetLumen(4000)
			test_scene.GetRoot():AddChild(lamp)
		end,
		{offset = Vec3(0, 0, 10)}
	)

	cell("empty sky", function() end, {pitch = 25, offset = Vec3(0, 0, 0)})

	cell("sky with clouds", function() end, {pitch = 25, clouds = "cumulus"})

	cell(
		"horizon with the ground fog",
		function(c)
			quad("ground", c + Vec3(0, -2, 0), 0, 1, 1, grid)
		end,
		{pitch = 2, fog = true}
	)
end

local selected = {}

for part in (os.getenv("PBR_PHASES") or ""):gmatch("[^,]+") do
	selected[#selected + 1] = part
end

local phases = {}

local function build_phases()
	for _, c in ipairs(cells) do
		local use = #selected == 0

		for _, part in ipairs(selected) do
			if c.name:find(part, 1, true) then use = true end
		end

		if use then
			phases[#phases + 1] = {
				name = c.name,
				enter = function()
					weather.SetGroundFogVisibility(c.fog and 6000 or math.huge)

					if c.clouds then
						import("goluwa/render3d/climate.lua").SetPreset(c.clouds, 0)
					else
						weather.SetCloudLayers({})
					end
				end,
				view = function()
					return c.center + (c.offset or Vec3(0, 0, 6)), c.pitch and -c.pitch or 0, 0
				end,
			}
		end
	end
end

local config
config = {
	name = "pbr stress",
	fov = 70,
	measure = test_scene.GetNumber("PBR_MEASURE", 5),
	warmup = 3,
	lead_in = 3,
	load = function()
		build()
		build_phases()

		for i, phase in ipairs(phases) do
			config.phases[i] = phase
		end
	end,
	view = function()
		return phases[1].view()
	end,
	phases = {},
}

if os.getenv("PBR_SHOTS") then
	local Shot = import("goluwa/render3d/shot.lua")
	local system = import("goluwa/system.lua")
	config.load()
	local properties = {}

	for i, phase in ipairs(phases) do
		local position, pitch, yaw = phase.view()
		properties[i] = {
			Position = position,
			Rotation = QuatDeg3(pitch, yaw, 0),
			FOV = math.rad(70),
			ExposureLock = 15,
			LocalExposure = 0,
		}
	end

	test_scene.WhenReady(function()
		phases[1].enter()

		Shot.Sequence(
			properties,
			function(texture, info, i)
				texture:SaveWithoutAlpha(string.format("tmp/ab/%s_%02d.png", os.getenv("PBR_SHOTS"), i))

				if phases[i + 1] then phases[i + 1].enter() end
			end,
			{settle = 3, converge = 0.3, max_settle = 8},
			function()
				system.ShutDown(0)
			end
		)
	end)
else
	frame_benchmark.Run(config)
end
