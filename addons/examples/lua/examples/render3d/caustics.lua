local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local pvars = import("goluwa/cli/pvars.lua")
local caustics_demo = {}
_G.caustics_demo = caustics_demo
weather.SetTimeScale(0)
local SUN = Vec3(0.35, 0.8, -0.45):GetNormalized()
local NIGHT = os.getenv("NIGHT") == "1"
weather.SetSunDirection(NIGHT and Vec3(0.35, -0.5, -0.45):GetNormalized() or SUN)
render3d.SetOceanEnabled(false)
pvars.SetSession("r_pass_caustics", os.getenv("CAUSTICS") ~= "0")

if os.getenv("PATH_TRACE") == "1" then
	pvars.SetSession("r_pass_path_trace", true)
end

local root = Entity.New{Name = "caustics_demo"}

local function matte(value)
	return shapes.Material{Color = Color(value, value, value, 1), Roughness = 0.85, Metallic = 0}
end

local function glass(config)
	config.Color = config.Color or Color(1, 1, 1, 1)
	config.Roughness = config.Roughness or 0
	config.Metallic = 0
	config.Refraction = 1
	return shapes.Material(config)
end

local function box(name, position, size, material)
	return shapes.Box{
		Name = name,
		Parent = root,
		Position = position,
		Size = size,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function sphere(name, position, radius, material)
	return shapes.Sphere{
		Name = name,
		Parent = root,
		Position = position,
		Radius = radius,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function prism(name, position, length, side, angle, material)
	local across = Vec3(-SUN.x, 0, -SUN.z):GetNormalized()
	local along = Vec3(across.z, 0, -across.x)
	local up = Vec3(0, 1, 0)
	local height = side * math.sqrt(3) / 2
	local c, s = math.cos(math.rad(angle)), math.sin(math.rad(angle))
	local corners = {}

	for i, corner in ipairs{
		Vec2(-side / 2, -height / 3),
		Vec2(side / 2, -height / 3),
		Vec2(0, height * 2 / 3),
	} do
		corners[i] = across * (corner.x * c - corner.y * s) + up * (corner.x * s + corner.y * c)
	end

	local function triangle(poly, a, b, c, normal)
		if (b - a):GetCross(c - a):GetDot(normal) < 0 then b, c = c, b end

		for _, p in ipairs{a, c, b} do
			poly:AddVertex{pos = p, uv = Vec2(0, 0), normal = normal}
		end
	end

	return shapes.Polygon{
		Name = name,
		Parent = root,
		Position = position,
		Material = material,
		RigidBody = false,
		Polygon = function(poly)
			local half = along * (length / 2)

			for i = 1, 3 do
				local a, b = corners[i], corners[i % 3 + 1]
				local normal = (b - a):GetCross(along):GetNormalized()

				if normal:GetDot(a + b) < 0 then normal = -normal end

				triangle(poly, a - half, b - half, b + half, normal)
				triangle(poly, a - half, b + half, a + half, normal)
			end

			for _, sign in ipairs{-1, 1} do
				triangle(
					poly,
					corners[1] + half * sign,
					corners[2] + half * sign,
					corners[3] + half * sign,
					along * sign
				)
			end
		end,
	},
	along
end

local tiles = matte(0.8)
local stone = matte(0.55)
box("ground", Vec3(0, -0.5, 0), Vec3(60, 1, 60), matte(0.62))
local POOL_X, POOL_Z, POOL_DEPTH, WALL = 6, 4, 1, 0.2
box("pool_floor", Vec3(0, 0.01, 0), Vec3(POOL_X, 0.02, POOL_Z), tiles)
box(
	"pool_wall_n",
	Vec3(0, 0.6, -POOL_Z / 2 - WALL / 2),
	Vec3(POOL_X + WALL * 2, 1.2, WALL),
	stone
)
box(
	"pool_wall_s",
	Vec3(0, 0.6, POOL_Z / 2 + WALL / 2),
	Vec3(POOL_X + WALL * 2, 1.2, WALL),
	stone
)
box(
	"pool_wall_e",
	Vec3(POOL_X / 2 + WALL / 2, 0.6, 0),
	Vec3(WALL, 1.2, POOL_Z),
	stone
)
box(
	"pool_wall_w",
	Vec3(-POOL_X / 2 - WALL / 2, 0.6, 0),
	Vec3(WALL, 1.2, POOL_Z),
	stone
)
Entity.New{
	Name = "pool_water",
	Parent = root,
	transform = {Position = Vec3(0, POOL_DEPTH, 0)},
	water_volume = {
		Size = Vec3(POOL_X, POOL_DEPTH, POOL_Z),
		Medium = "pool",
		WaveHeight = 0.08,
		WaveLength = 0.8,
		Foam = 0,
	},
}
sphere("pool_ball", Vec3(1.5, 0.3, 0.6), 0.3, matte(0.75))
box("pool_step", Vec3(-1.6, 0.2, -0.8), Vec3(1.2, 0.4, 0.8), stone)
sphere("ball_crown", Vec3(-6, 0.6, 2.5), 0.6, glass{IndexOfRefraction = 1.52})
sphere(
	"ball_flint",
	Vec3(-6, 0.6, -1),
	0.6,
	glass{IndexOfRefraction = 1.62, AbbeNumber = 18}
)
local PRISM = Vec3(6, 1.3, 1)
local _, prism_axis = prism("prism", PRISM, 1.2, 0.5, 52, glass{IndexOfRefraction = 1.62, AbbeNumber = 18})

for _, sign in ipairs{-1, 1} do
	box(
		"prism_post",
		PRISM + prism_axis * (sign * 0.68) - Vec3(0, 0.67, 0),
		Vec3(0.08, 1.26, 0.08),
		stone
	)
end

local mirror = shapes.Polygon{
	Name = "mirror",
	Parent = root,
	Position = Vec3(-7.8, 0.8, 3),
	Polygon = function(poly)
		shapes.BuildPlane(poly, Vec3(0, 0, 0), Vec3(0.92, -0.09, 0.39), 0.6, 0.9)
	end,
	Material = shapes.Material{Color = Color(1, 1, 1, 1), Metallic = 1, Roughness = 0.02, DoubleSided = true},
	Collision = false,
	RigidBody = false,
}

local function lamp(name, position, lumen, color, spot)
	local entity = Entity.New{Name = name, Parent = root}
	entity:AddComponent("transform"):SetPosition(position)
	local light = entity:AddComponent(spot and "light_spot" or "light_point")
	light:SetColor(color)
	light:SetLumen(lumen)
	light:SetSourceRadius(0.03)

	if spot then
		entity.transform:SetRotation(QuatDeg3(spot[3] or -90, 0, 0))
		light:SetInnerCone(spot[1])
		light:SetOuterCone(spot[2])
	end

	return entity
end

local ROOM = Vec3(0, 0, -16)
local ROOM_X, ROOM_Z, ROOM_Y = 9, 9, 4
local INDOOR_X, INDOOR_Z = 4, 3
box(
	"hall_ceiling",
	ROOM + Vec3(0, ROOM_Y + 0.15, 0),
	Vec3(ROOM_X + 0.6, 0.3, ROOM_Z + 0.6),
	tiles
)
box(
	"hall_wall_n",
	ROOM + Vec3(0, ROOM_Y / 2 + 0.15, -ROOM_Z / 2 - 0.15),
	Vec3(ROOM_X + 0.6, ROOM_Y + 0.3, 0.3),
	stone
)
box(
	"hall_wall_s",
	ROOM + Vec3(0, ROOM_Y / 2 + 0.15, ROOM_Z / 2 + 0.15),
	Vec3(ROOM_X + 0.6, ROOM_Y + 0.3, 0.3),
	stone
)
box(
	"hall_wall_e",
	ROOM + Vec3(ROOM_X / 2 + 0.15, ROOM_Y / 2 + 0.15, 0),
	Vec3(0.3, ROOM_Y + 0.3, ROOM_Z),
	stone
)
box(
	"hall_wall_w",
	ROOM + Vec3(-ROOM_X / 2 - 0.15, ROOM_Y / 2 + 0.15, 0),
	Vec3(0.3, ROOM_Y + 0.3, ROOM_Z),
	stone
)
box("hall_pool_floor", ROOM + Vec3(0, 0.01, 0), Vec3(INDOOR_X, 0.02, INDOOR_Z), tiles)
box(
	"hall_pool_wall_n",
	ROOM + Vec3(0, 0.6, -INDOOR_Z / 2 - WALL / 2),
	Vec3(INDOOR_X + WALL * 2, 1.2, WALL),
	stone
)
box(
	"hall_pool_wall_s",
	ROOM + Vec3(0, 0.6, INDOOR_Z / 2 + WALL / 2),
	Vec3(INDOOR_X + WALL * 2, 1.2, WALL),
	stone
)
box(
	"hall_pool_wall_e",
	ROOM + Vec3(INDOOR_X / 2 + WALL / 2, 0.6, 0),
	Vec3(WALL, 1.2, INDOOR_Z),
	stone
)
box(
	"hall_pool_wall_w",
	ROOM + Vec3(-INDOOR_X / 2 - WALL / 2, 0.6, 0),
	Vec3(WALL, 1.2, INDOOR_Z),
	stone
)
Entity.New{
	Name = "hall_pool_water",
	Parent = root,
	transform = {Position = ROOM + Vec3(0, POOL_DEPTH, 0)},
	water_volume = {
		Size = Vec3(INDOOR_X, POOL_DEPTH, INDOOR_Z),
		Medium = "pool",
		WaveHeight = 0.08,
		WaveLength = 0.8,
		Foam = 0,
	},
}
lamp(
	"hall_underwater_lamp",
	ROOM + Vec3(0, 0.15, 0),
	12000,
	Color(0.85, 0.95, 1, 1),
	{25, 40, 90}
)

if NIGHT then
	lamp("pool_lamp", Vec3(0.5, 2.6, 0.3), 30000, Color(1, 0.92, 0.8, 1))
	lamp("ball_spot", Vec3(-6, 2.6, 2.5), 20000, Color(1, 1, 1, 1), {12, 20})
	lamp("prism_lamp", Vec3(6.6, 2.6, 0.4), 15000, Color(1, 1, 1, 1))
end

local cameras = {
	overview = {Vec3(0, 5, 10), Vec3(-28, 0, 0)},
	pool = {Vec3(0, 3.4, 5), Vec3(-42, 0, 0)},
	ball = {Vec3(-6, 2.2, 6), Vec3(-24, 0, 0)},
	prism = {Vec3(6.5, 2.4, 4.2), Vec3(-30, 0, 0)},
	mirror = {Vec3(-5, 1.6, 5.5), Vec3(-12, 30, 0)},
	hall = {ROOM + Vec3(3.6, 1.4, 3.8), Vec3(18, 40, 0)},
	hall_ceiling = {ROOM + Vec3(2.5, 1.5, 2.5), Vec3(55, 40, 0)},
}

function caustics_demo.Goto(name)
	local view = assert(cameras[name], "no camera " .. tostring(name))
	local camera = render3d.GetCamera()
	camera:SetPosition(view[1])
	camera:SetRotation(QuatDeg3(view[2].x, view[2].y, view[2].z))
	return name
end

caustics_demo.cameras = cameras

if os.getenv("CAM") then caustics_demo.Goto(os.getenv("CAM")) end

return caustics_demo
