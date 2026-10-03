local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local View = import("goluwa/render3d/view.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local root = Entity.New{Name = "gi_outdoor"}
local night = os.getenv("GI_NIGHT") ~= nil

local function mat(color, roughness)
	return shapes.Material{Color = color, Roughness = roughness or 0.9, Metallic = 0}
end

local function box(name, position, size, material, rotation)
	return shapes.Box{
		Name = name,
		Parent = root,
		Position = position,
		Size = size,
		Rotation = rotation,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function point_light(name, position, color, lumen)
	local ent = Entity.New{Name = name, Parent = root}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	local light = ent:AddComponent("light_point")
	light:SetColor(color)
	light:SetLumen(lumen)
	light:SetRange(3000)
	return light
end

local ground_mat = mat(Color(0.42, 0.38, 0.30, 1))
local rock_mat = mat(Color(0.5, 0.47, 0.44, 1), 0.95)
local grey = mat(Color(0.6, 0.6, 0.6, 1))
local white = mat(Color(0.85, 0.85, 0.85, 1))
local red = mat(Color(0.75, 0.08, 0.06, 1))
local green = mat(Color(0.08, 0.6, 0.12, 1))
local palette = {
	mat(Color(0.9, 0.12, 0.1, 1)),
	mat(Color(0.12, 0.8, 0.2, 1)),
	mat(Color(0.12, 0.25, 0.95, 1)),
	mat(Color(0.95, 0.8, 0.1, 1)),
	mat(Color(0.85, 0.15, 0.85, 1)),
	mat(Color(0.1, 0.85, 0.85, 1)),
}
box("ground", Vec3(0, -0.5, 0), Vec3(4000, 1, 4000), ground_mat)

for _, hill in ipairs{
	{x = 180, z = -120, r = 220, h = 45},
	{x = -260, z = 160, r = 300, h = 70},
	{x = 60, z = 330, r = 260, h = 55},
	{x = 700, z = -300, r = 900, h = 260},
	{x = -900, z = -600, r = 1100, h = 320},
} do
	shapes.Sphere{
		Name = "hill",
		Parent = root,
		Position = Vec3(hill.x, hill.h - hill.r, hill.z),
		Radius = hill.r,
		Material = rock_mat,
		Collision = false,
		RigidBody = false,
	}
end

box("cliff", Vec3(120, 30, -170), Vec3(160, 60, 14), rock_mat, QuatDeg3(0, 20, 0))
box("shelf", Vec3(100, 14, -150), Vec3(60, 2, 22), rock_mat, QuatDeg3(0, 20, 0))

do
	local cx, cz, y, half, hole = 40, -40, 15, 35, 7
	local side = half - hole
	box("canopy_north", Vec3(cx, y, cz - hole - side / 2), Vec3(half * 2, 1, side), grey)
	box("canopy_south", Vec3(cx, y, cz + hole + side / 2), Vec3(half * 2, 1, side), grey)
	box("canopy_west", Vec3(cx - hole - side / 2, y, cz), Vec3(side, 1, hole * 2), grey)
	box("canopy_east", Vec3(cx + hole + side / 2, y, cz), Vec3(side, 1, hole * 2), grey)

	for _, corner in ipairs{{-1, -1}, {1, -1}, {-1, 1}, {1, 1}} do
		box(
			"canopy_pillar",
			Vec3(cx + corner[1] * (half - 2), y / 2, cz + corner[2] * (half - 2)),
			Vec3(2, y, 2),
			grey
		)
	end

	box("canopy_block_a", Vec3(cx - 18, 1.5, cz + 10), Vec3(4, 3, 4), palette[1])
	box("canopy_block_b", Vec3(cx + 20, 1.5, cz - 14), Vec3(4, 3, 4), palette[3])
	box("canopy_block_c", Vec3(cx + 4, 1.5, cz + 22), Vec3(4, 3, 4), palette[2])
	shapes.Sphere{
		Name = "canopy_sphere",
		Parent = root,
		Position = Vec3(cx, 2, cz + 4),
		Radius = 2,
		Material = white,
		Collision = false,
		RigidBody = false,
	}
end

do
	local cx, cz, t, h = -45, -35, 0.5, 6
	box("room_back", Vec3(cx, h / 2, cz - 6 - t / 2), Vec3(12 + t * 2, h, t), white)
	box("room_left", Vec3(cx - 6 - t / 2, h / 2, cz), Vec3(t, h, 12), red)
	box("room_right", Vec3(cx + 6 + t / 2, h / 2, cz), Vec3(t, h, 12), green)
	box("room_front_left", Vec3(cx - 4, h / 2, cz + 6 + t / 2), Vec3(4, h, t), white)
	box("room_front_right", Vec3(cx + 4, h / 2, cz + 6 + t / 2), Vec3(4, h, t), white)
	box("room_front_top", Vec3(cx, 5.25, cz + 6 + t / 2), Vec3(4, 1.5, t), white)
	box("room_roof_a", Vec3(cx, h + t / 2, cz - 3.75), Vec3(12 + t * 2, t, 4.5), white)
	box("room_roof_b", Vec3(cx, h + t / 2, cz + 3.75), Vec3(12 + t * 2, t, 4.5), white)
	box("room_roof_c", Vec3(cx - 3.75, h + t / 2, cz), Vec3(4.5, t, 3), white)
	box("room_roof_d", Vec3(cx + 3.75, h + t / 2, cz), Vec3(4.5, t, 3), white)
	box("room_cube", Vec3(cx - 1, 1, cz - 2), Vec3(2, 2, 2), palette[4])
end

do
	local z, width, height, length, t = 50, 8, 6, 120, 0.5
	box(
		"corridor_wall_north",
		Vec3(0, height / 2, z - width / 2 - t / 2),
		Vec3(length, height, t),
		grey
	)
	box(
		"corridor_wall_south",
		Vec3(0, height / 2, z + width / 2 + t / 2),
		Vec3(length, height, t),
		grey
	)

	for i = 0, 3 do
		box(
			"corridor_roof",
			Vec3(-length / 2 + 12 + i * 30, height + t / 2, z),
			Vec3(24, t, width + t * 2),
			grey
		)
	end
end

do
	local SPACING = 1.35
	local seed = 20240611

	local function random()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end

	local function field(name, center, counts, cell)
		local sizes = {Vec3(1.05, 1.05, 1.05) * cell, Vec3(1.4, 0.7, 1) * cell}
		local step = cell * SPACING

		for i = 0, counts.x - 1 do
			for j = 0, counts.y - 1 do
				for k = 0, counts.z - 1 do
					box(
						name,
						center + Vec3(
								(i - (counts.x - 1) / 2) * step + (random() - 0.5) * cell * 0.3,
								(j - (counts.y - 1) / 2) * step + (random() - 0.5) * cell * 0.3,
								(k - (counts.z - 1) / 2) * step + (random() - 0.5) * cell * 0.3
							),
						sizes[random() < 0.5 and 1 or 2],
						white,
						QuatDeg3(random() * 360, random() * 360, random() * 360)
					)
				end
			end
		end
	end

	field("box_field_near", Vec3(0, 12, 0), Vec3(10, 6, 10), 3)
	field("box_field_mid", Vec3(-120, 25, 120), Vec3(12, 5, 12), 8)
	field("box_field_far", Vec3(350, 60, 250), Vec3(10, 4, 10), 24)
end

do
	local lights = {
		{"lamp_room", Vec3(-45, 4.5, -35), Color(1, 0.8, 0.55, 1), 30000},
		{"lamp_canopy", Vec3(40, 10, -40), Color(0.6, 0.8, 1, 1), 60000},
		{"lamp_corridor", Vec3(-30, 4.5, 50), Color(1, 0.5, 0.3, 1), 30000},
		{"lamp_near", Vec3(12, 3, 20), Color(1, 0.95, 0.85, 1), 20000},
		{"lamp_mid", Vec3(90, 6, 70), Color(0.5, 1, 0.6, 1), 120000},
		{"lamp_far", Vec3(-220, 20, -90), Color(1, 0.4, 0.8, 1), 500000},
		{"lamp_distant", Vec3(400, 30, 250), Color(0.4, 0.5, 1, 1), 2000000},
	}

	for _, info in ipairs(lights) do
		point_light(info[1], info[2], info[3], info[4])
		box(
			info[1] .. "_post",
			Vec3(info[2].x, info[2].y / 2 - 0.4, info[2].z),
			Vec3(0.4, info[2].y - 0.8, 0.4),
			grey
		)
	end
end

weather.SetSunRotation(night and QuatDeg3(70, 35, 0) or QuatDeg3(-38, 35, 0))

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 6, 110))
	cam:SetAngles(Deg3(-8, 0, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.transform:SetPosition(cam:GetPosition():Copy())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end

local tour_speed = tonumber(os.getenv("GI_TOUR") or "")

if tour_speed then
	local waypoints = {
		Vec3(0, 6, 110),
		Vec3(-45, 4, -10),
		Vec3(-45, 3, -35),
		Vec3(40, 5, -15),
		Vec3(40, 3, -40),
		Vec3(-70, 4, 50),
		Vec3(70, 4, 50),
		Vec3(0, 34, 20),
		Vec3(0, 34, -20),
		Vec3(-120, 75, 120),
		Vec3(350, 175, 250),
		Vec3(480, 90, -100),
	}
	local segments = {}
	local total = 0

	local function facing(direction)
		local best, best_dot = 0, -2

		for degrees = 0, 359 do
			local forward = QuatDeg3(0, degrees, 0):GetBackward() * -1
			local dot = forward.x * direction.x + forward.z * direction.z

			if dot > best_dot then best, best_dot = degrees, dot end
		end

		return best
	end

	for i, from in ipairs(waypoints) do
		local to = waypoints[i % #waypoints + 1]
		local delta = to - from
		local length = delta:GetLength()
		segments[i] = {
			from = from,
			delta = delta,
			length = length,
			start = total,
			yaw = facing(delta:GetNormalized()),
		}
		total = total + length
	end

	local view = View.New{Priority = 100, Position = waypoints[1]:Copy()}:Activate()
	local travelled = 0

	event.AddListener("Update", "gi_outdoor_tour", function()
		travelled = (travelled + tour_speed * system.GetFrameTime()) % total

		for _, segment in ipairs(segments) do
			if travelled < segment.start + segment.length then
				view:SetPosition(segment.from + segment.delta * ((travelled - segment.start) / segment.length))
				view:SetRotation(QuatDeg3(-6, segment.yaw, 0))

				break
			end
		end
	end)
end
