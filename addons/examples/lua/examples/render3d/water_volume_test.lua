local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local water = import("goluwa/render3d/water.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
weather.SetTimeScale(0)
weather.SetSunDirection(Vec3(0.3, 0.6, -0.5):GetNormalized())
render3d.SetOceanEnabled(false)
local W, L, D = 40, 40, tonumber(os.getenv("DEPTH") or "12")

local function mat(r, g, b, rough)
	return shapes.Material{Color = Color(r, g, b, 1), Roughness = rough or 0.8, Metallic = 0}
end

local stone = mat(0.55, 0.52, 0.48)
local sand = mat(0.76, 0.66, 0.48, 0.95)

local function box(name, pos, size, m)
	return shapes.Box{
		Name = name,
		Position = pos,
		Size = size,
		Material = m,
		Collision = false,
		RigidBody = false,
	}
end

box("ground", Vec3(0, -D - 1, 0), Vec3(200, 2, 200), sand)
box("wall_n", Vec3(0, -D / 2 + 1, L / 2 + 0.5), Vec3(W + 2, D + 2, 1), stone)
box("wall_s", Vec3(0, -D / 2 + 1, -L / 2 - 0.5), Vec3(W + 2, D + 2, 1), stone)
box("wall_e", Vec3(W / 2 + 0.5, -D / 2 + 1, 0), Vec3(1, D + 2, L), stone)
box("wall_w", Vec3(-W / 2 - 0.5, -D / 2 + 1, 0), Vec3(1, D + 2, L), stone)
box("floor_hi", Vec3(0, -D, 0), Vec3(W, 0.2, L), sand)
local colors = {{0.9, 0.1, 0.1}, {0.1, 0.8, 0.2}, {0.15, 0.2, 0.9}, {0.9, 0.8, 0.1}}

for i = 1, 4 do
	local c = colors[i]
	box(
		"pillar" .. i,
		Vec3(-12 + i * 6, -D / 2, 8),
		Vec3(1.5, D - 1, 1.5),
		mat(c[1], c[2], c[3], 0.4)
	)
end

shapes.Sphere{
	Name = "ball",
	Position = Vec3(0, -D + 2, -6),
	Radius = 2,
	Material = mat(0.9, 0.9, 0.95, 0.2),
	Collision = false,
	RigidBody = false,
}
box("float_box", Vec3(8, 1, -5), Vec3(3, 2, 3), mat(0.8, 0.4, 0.1, 0.5))
Entity.New{
	Name = "tank_water",
	transform = {Position = Vec3(0, 0, 0)},
	water_volume = {
		Size = Vec3(W, D, L),
		Absorption = water.presets.lake.Absorption:Copy(),
		ParticleScattering = water.presets.lake.ParticleScattering:Copy() * tonumber(os.getenv("SCAT") or "1"),
		WaveHeight = 0.08,
		WaveLength = 2,
		AbbeNumber = tonumber(os.getenv("ABBE") or "55.8"),
	},
}
