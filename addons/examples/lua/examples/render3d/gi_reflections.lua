local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")

local function mat(color, roughness, metallic)
	return shapes.Material{Color = color, Roughness = roughness, Metallic = metallic or 0}
end

local function emissive_mat(color, strength)
	return shapes.Material{
		Color = color,
		Roughness = 0.8,
		Metallic = 0,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, strength),
	}
end

local function box(name, position, size, material)
	shapes.Box{
		Name = name,
		Position = position,
		Size = size,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function sphere(name, position, radius, material)
	shapes.Sphere{
		Name = name,
		Position = position,
		Radius = radius,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local white = mat(Color(0.8, 0.8, 0.8, 1), 0.9)
local grey = mat(Color(0.4, 0.4, 0.4, 1), 0.9)
local red = mat(Color(0.75, 0.08, 0.05, 1), 0.9)
local green = mat(Color(0.08, 0.6, 0.1, 1), 0.9)
local blue = mat(Color(0.1, 0.25, 0.8, 1), 0.7)
local yellow = mat(Color(0.9, 0.75, 0.15, 1), 0.7)
local magenta = mat(Color(0.7, 0.1, 0.6, 1), 0.9)
local orange = mat(Color(0.9, 0.4, 0.05, 1), 0.9)
local cyan = mat(Color(0.05, 0.6, 0.65, 1), 0.9)
box(
	"ground",
	Vec3(80, -1, -30),
	Vec3(300, 2, 160),
	mat(Color(0.9, 0.9, 0.9, 1), 1, 1)
)

do
	local cx, w, h, d, t = -40, 12, 8, 12, 0.5
	box("cornell_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("cornell_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), white)
	box("cornell_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), red)
	box("cornell_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), green)
	box("cornell_roof_back", Vec3(cx, h, -d / 4 - 1), Vec3(w, t, d / 2 - 2), white)
	box("cornell_roof_front", Vec3(cx, h, d / 4 + 1), Vec3(w, t, d / 2 - 2), white)
	box("cornell_box", Vec3(cx - 2.5, 1.5, -2), Vec3(3, 3, 3), white)
	sphere("cornell_sphere", Vec3(cx + 2.5, 1.5, 1.5), 1.5, white)
end

do
	local cx, w, h, d, t = 0, 6, 4, 14, 0.5
	box("tunnel_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("tunnel_roof", Vec3(cx, h, 0), Vec3(w, t, d), white)
	box("tunnel_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("tunnel_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("tunnel_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), white)
	box("tunnel_front_top", Vec3(cx, h - 0.75, d / 2), Vec3(w, 1.5, t), white)
	box("tunnel_front_left", Vec3(cx - 2.25, 1.25, d / 2), Vec3(1.5, 2.5, t), white)
	box("tunnel_front_right", Vec3(cx + 2.25, 1.25, d / 2), Vec3(1.5, 2.5, t), white)
	box(
		"tunnel_lamp",
		Vec3(cx, h - 0.6, -3),
		Vec3(4, 0.3, 0.6),
		emissive_mat(Color(1, 0.55, 0.2, 1), 8)
	)
	sphere("tunnel_sphere", Vec3(cx - 1.5, 1, -3), 1, white)
	box("tunnel_pillar", Vec3(cx + 1.5, 1.25, -1), Vec3(1, 2.5, 1), blue)
end

do
	local cx, w, d = 40, 14, 12
	box(
		"stage_floor",
		Vec3(cx, 0.05, 0),
		Vec3(w, 0.1, d),
		mat(Color(0.9, 0.9, 0.9, 1), 0.05, 1)
	)
	box("stage_back", Vec3(cx, 3, -d / 2), Vec3(w, 6, 0.5), blue)
	box("stage_right", Vec3(cx + w / 2, 3, 0), Vec3(0.5, 6, d), yellow)
	box("stage_left", Vec3(cx - w / 2, 3, 0), Vec3(0.5, 6, d), red)

	for i = 0, 4 do
		sphere(
			"stage_metal_" .. i,
			Vec3(cx - 5 + i * 2.5, 1.2, -2),
			1.2,
			mat(Color(0.95, 0.75, 0.4, 1), i / 4, 1)
		)
	end

	sphere("stage_chrome", Vec3(cx, 2, 3), 2, mat(Color(0.95, 0.95, 0.95, 1), 0.02, 1))
	sphere("stage_dielectric", Vec3(cx - 5, 1, 3), 1, mat(Color(0.9, 0.9, 0.9, 1), 0.15, 0))
end

do
	local cx, w, h, d, t = 80, 8, 6, 8, 0.5
	box("bleed_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("bleed_back", Vec3(cx, h / 2, -d / 2), Vec3(w, h, t), magenta)
	box("bleed_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), orange)
	box("bleed_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), cyan)
	box("bleed_roof_back", Vec3(cx, h, -d / 4 - 1), Vec3(w, t, d / 2 - 2), white)
	box("bleed_roof_front", Vec3(cx, h, d / 4 + 1), Vec3(w, t, d / 2 - 2), white)
	sphere("bleed_sphere", Vec3(cx, 1.5, 0), 1.5, white)
end

do
	local cx, w, h, d, t, pt = 120, 10, 5, 8, 0.5, 0.15
	local half = (w - pt) / 2
	local lit_cx = cx - pt / 2 - half / 2
	local dark_cx = cx + pt / 2 + half / 2
	box("partition_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), grey)
	box("partition_wall", Vec3(cx, h / 2, 0), Vec3(pt, h, d), grey)
	box("partition_lit_back", Vec3(lit_cx, h / 2, -d / 2), Vec3(half, h, t), white)
	box("partition_lit_left", Vec3(lit_cx - half / 2, h / 2, 0), Vec3(t, h, d), white)
	box("partition_lit_front", Vec3(lit_cx, h / 2, d / 2), Vec3(half, h, t), white)
	box(
		"partition_lit_roof_back",
		Vec3(lit_cx, h, -d / 4 - 1),
		Vec3(half, t, d / 2 - 2),
		white
	)
	box(
		"partition_lit_roof_front",
		Vec3(lit_cx, h, d / 4 + 1),
		Vec3(half, t, d / 2 - 2),
		white
	)
	box(
		"partition_lamp",
		Vec3(lit_cx + half / 2 - 0.15, h / 2, 0),
		Vec3(0.1, h - 1, d - 2),
		emissive_mat(Color(1, 0.9, 0.7, 1), 6)
	)
	box("partition_dark_back", Vec3(dark_cx, h / 2, -d / 2), Vec3(half, h, t), grey)
	box("partition_dark_right", Vec3(dark_cx + half / 2, h / 2, 0), Vec3(t, h, d), grey)
	box("partition_dark_front", Vec3(dark_cx, h / 2, d / 2), Vec3(half, h, t), grey)
	box("partition_dark_roof", Vec3(dark_cx, h, 0), Vec3(half, t, d), grey)
end

do
	local cx, w, h, d, t = 160, 8, 5, 22, 0.5
	box("hall_floor", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), white)
	box("hall_roof", Vec3(cx, h, 0), Vec3(w, t, d), white)
	box("hall_left", Vec3(cx - w / 2, h / 2, 0), Vec3(t, h, d), white)
	box("hall_right", Vec3(cx + w / 2, h / 2, 0), Vec3(t, h, d), white)
	box(
		"hall_lamp_wall",
		Vec3(cx, h / 2, -d / 2),
		Vec3(w, h, t),
		emissive_mat(Color(1, 0.35, 0.15, 1), 10)
	)
	box("hall_front_top", Vec3(cx, h - 0.75, d / 2), Vec3(w, 1.5, t), white)
	box("hall_front_left", Vec3(cx - 3, 1.25, d / 2), Vec3(2, 2.5, t), white)
	box("hall_front_right", Vec3(cx + 3, 1.25, d / 2), Vec3(2, 2.5, t), white)

	for i, z in ipairs{-7, -2.5, 2, 6.5} do
		box(
			"hall_pillar_" .. i,
			Vec3(cx + (i % 2 == 0 and 2 or -2), 1.5, z),
			Vec3(1, 3, 1),
			grey
		)
	end
end

do
	local cx, w, d, t, hole, well = 200, 8, 8, 0.5, 2.5, 1.5
	local floor1_h, floor2_h = 4, 4
	local h2 = floor1_h + floor2_h
	box("tower_floor1", Vec3(cx, 0.05, 0), Vec3(w, 0.1, d), grey)
	box("tower_wall1_back", Vec3(cx, floor1_h / 2, -d / 2), Vec3(w, floor1_h, t), grey)
	box("tower_wall1_front", Vec3(cx, floor1_h / 2, d / 2), Vec3(w, floor1_h, t), grey)
	box("tower_wall1_left", Vec3(cx - w / 2, floor1_h / 2, 0), Vec3(t, floor1_h, d), grey)
	box(
		"tower_wall1_right",
		Vec3(cx + w / 2, floor1_h / 2, 0),
		Vec3(t, floor1_h, d),
		grey
	)
	local seg = (d - hole) / 2
	local off = d / 2 - seg / 2
	box("tower_slab_back", Vec3(cx, floor1_h, -off), Vec3(w, t, seg), grey)
	box("tower_slab_front", Vec3(cx, floor1_h, off), Vec3(w, t, seg), grey)
	box("tower_slab_left", Vec3(cx - off, floor1_h, 0), Vec3(seg, t, hole), grey)
	box("tower_slab_right", Vec3(cx + off, floor1_h, 0), Vec3(seg, t, hole), grey)
	box(
		"tower_wall2_back",
		Vec3(cx, floor1_h + floor2_h / 2, -d / 2),
		Vec3(w, floor2_h, t),
		grey
	)
	box(
		"tower_wall2_front",
		Vec3(cx, floor1_h + floor2_h / 2, d / 2),
		Vec3(w, floor2_h, t),
		grey
	)
	box(
		"tower_wall2_left",
		Vec3(cx - w / 2, floor1_h + floor2_h / 2, 0),
		Vec3(t, floor2_h, d),
		grey
	)
	box(
		"tower_wall2_right",
		Vec3(cx + w / 2, floor1_h + floor2_h / 2, 0),
		Vec3(t, floor2_h, d),
		grey
	)
	local seg2 = (d - well) / 2
	local off2 = d / 2 - seg2 / 2
	box("tower_roof_back", Vec3(cx, h2, -off2), Vec3(w, t, seg2), grey)
	box("tower_roof_front", Vec3(cx, h2, off2), Vec3(w, t, seg2), grey)
	box("tower_roof_left", Vec3(cx - off2, h2, 0), Vec3(seg2, t, well), grey)
	box("tower_roof_right", Vec3(cx + off2, h2, 0), Vec3(seg2, t, well), grey)
	sphere("tower_sphere1", Vec3(cx, 1.2, 0), 1, white)
	sphere("tower_sphere2", Vec3(cx, floor1_h + 1.2, 0), 1, white)
end

local function shadowed_light(kind, name, position, rotation, color, lumen, range)
	local ent = Entity.New{Name = name}
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)

	if rotation then ent.transform:SetRotation(rotation) end

	local light = ent:AddComponent(kind)
	light:SetColor(color)
	light:SetLumen(lumen)
	light:SetRange(range)
	light:SetOcclusionMap(false)
	ShadowMap.New{
		mode = "point",
		light = ent,
		size = Vec2() + 512,
		near_plane = 0.05,
		far_plane = range,
	}
	return light
end

local function point_light(name, position, color, lumen, range)
	return shadowed_light("light_point", name, position, nil, color, lumen, range)
end

local function spot_light(name, position, pitch, yaw, color, lumen, range, inner, outer)
	local light = shadowed_light("light_spot", name, position, QuatDeg3(pitch, yaw, 0), color, lumen, range)
	light:SetInnerCone(inner)
	light:SetOuterCone(outer)
	return light
end

local function room(name, cx, cz, w, h, d, material)
	local t, door_w, door_h = 0.4, 1.6, 2.4
	local side = (w - door_w) / 2
	box(name .. "_floor", Vec3(cx, 0.05, cz), Vec3(w, 0.1, d), material)
	box(name .. "_roof", Vec3(cx, h, cz), Vec3(w, t, d), material)
	box(name .. "_back", Vec3(cx, h / 2, cz - d / 2), Vec3(w, h, t), material)
	box(name .. "_left", Vec3(cx - w / 2, h / 2, cz), Vec3(t, h, d), material)
	box(name .. "_right", Vec3(cx + w / 2, h / 2, cz), Vec3(t, h, d), material)
	box(
		name .. "_front_left",
		Vec3(cx - w / 2 + side / 2, h / 2, cz + d / 2),
		Vec3(side, h, t),
		material
	)
	box(
		name .. "_front_right",
		Vec3(cx + w / 2 - side / 2, h / 2, cz + d / 2),
		Vec3(side, h, t),
		material
	)
	box(
		name .. "_front_top",
		Vec3(cx, (h + door_h) / 2, cz + d / 2),
		Vec3(door_w, h - door_h, t),
		material
	)
end

local warm = Color(1, 0.85, 0.65, 1)
local neutral = Color(1, 0.95, 0.9, 1)
local cool = Color(0.75, 0.85, 1, 1)

do
	local cx, cz, w, h, d = -40, -60, 10, 4, 10
	room("lamp_room", cx, cz, w, h, d, white)
	box("lamp_room_table", Vec3(cx - 1.5, 0.45, cz - 1), Vec3(2.5, 0.9, 1.4), orange)
	box("lamp_room_cabinet", Vec3(cx + 3.8, 1.25, cz - 3.5), Vec3(1.2, 2.5, 2), blue)
	box("lamp_room_shelf", Vec3(cx - 4.2, 1, cz + 2), Vec3(0.8, 2, 3), green)
	sphere("lamp_room_ball", Vec3(cx + 1.5, 0.8, cz + 1.5), 0.8, white)
	point_light("lamp_room_light", Vec3(cx, h - 0.5, cz), warm, 1600, 14)
end

do
	local cx, cz, w, h, d = 0, -60, 12, 5, 10
	room("spot_room", cx, cz, w, h, d, grey)
	box("spot_room_rug", Vec3(cx - 3, 0.12, cz), Vec3(3, 0.04, 3), red)
	box("spot_room_panel", Vec3(cx + 3, 2.5, cz - d / 2 + 0.25), Vec3(4, 3, 0.1), green)
	sphere("spot_room_ball", Vec3(cx - 3, 0.6, cz), 0.5, white)
	spot_light("spot_room_down", Vec3(cx - 3, h - 0.4, cz), -90, 0, neutral, 3000, 12, 15, 25)
	spot_light("spot_room_wash", Vec3(cx + 3, h - 0.5, cz + 2), -35, 0, cool, 3000, 14, 20, 35)
end

do
	local cx, cz, w, h, d, t, pt = 40, -60, 12, 4, 8, 0.4, 0.2
	local half = (w - pt) / 2
	local lit_cx = cx - pt / 2 - half / 2
	local dark_cx = cx + pt / 2 + half / 2
	box("neighbours_floor", Vec3(cx, 0.05, cz), Vec3(w, 0.1, d), white)
	box("neighbours_roof", Vec3(cx, h, cz), Vec3(w, t, d), white)
	box("neighbours_back", Vec3(cx, h / 2, cz - d / 2), Vec3(w, h, t), white)
	box("neighbours_wall", Vec3(cx, h / 2, cz), Vec3(pt, h, d), white)
	box("neighbours_left", Vec3(cx - w / 2, h / 2, cz), Vec3(t, h, d), white)
	box("neighbours_right", Vec3(cx + w / 2, h / 2, cz), Vec3(t, h, d), white)
	local side = (half - 1.6) / 2
	box(
		"neighbours_lit_front_left",
		Vec3(lit_cx - 0.8 - side / 2, h / 2, cz + d / 2),
		Vec3(side, h, t),
		white
	)
	box(
		"neighbours_lit_front_right",
		Vec3(lit_cx + 0.8 + side / 2, h / 2, cz + d / 2),
		Vec3(side, h, t),
		white
	)
	box(
		"neighbours_lit_front_top",
		Vec3(lit_cx, (h + 2.4) / 2, cz + d / 2),
		Vec3(1.6, h - 2.4, t),
		white
	)
	box(
		"neighbours_dark_front",
		Vec3(dark_cx, h / 2, cz + d / 2),
		Vec3(half, h, t),
		white
	)
	sphere("neighbours_dark_ball", Vec3(dark_cx, 0.8, cz), 0.8, white)
	point_light("neighbours_lamp", Vec3(cx - pt / 2 - 0.3, 2, cz - 1), warm, 1500, 12)
end

do
	local cx, cz, len, w, h, t = 80, -60, 32, 3, 3, 0.4
	box("corridor_floor", Vec3(cx, 0.05, cz), Vec3(len, 0.1, w), white)
	box("corridor_roof", Vec3(cx, h, cz), Vec3(len, t, w), white)
	box("corridor_back", Vec3(cx, h / 2, cz - w / 2), Vec3(len, h, t), yellow)
	box("corridor_front", Vec3(cx, h / 2, cz + w / 2), Vec3(len, h, t), white)

	for i = 0, 5 do
		local x = cx - 12.5 + i * 5
		point_light("corridor_lamp_" .. i, Vec3(x, h - 0.4, cz), neutral, 800, 8)
		box("corridor_crate_" .. i, Vec3(x + 2.5, 0.5, cz - 0.7), Vec3(0.8, 1, 0.8), grey)
	end
end

do
	local cx, cz, w, h, d = 125, -60, 10, 4, 8
	room("desk_room", cx, cz, w, h, d, white)
	box("desk_room_desk", Vec3(cx - 2, 0.4, cz - 2.8), Vec3(3, 0.8, 1.2), orange)
	spot_light("desk_room_desk_lamp", Vec3(cx - 2, 1.25, cz - 2.8), -90, 0, warm, 450, 6, 30, 50)
	point_light(
		"desk_room_floor_lamp",
		Vec3(cx + w / 2 - 0.5, 0.3, cz - d / 2 + 0.5),
		warm,
		800,
		8
	)
	spot_light("desk_room_washer", Vec3(cx + 2, 3.5, cz + 2), -60, 90, cool, 1500, 8, 25, 40)
	box("desk_room_pillar", Vec3(cx + 1, 1.5, cz), Vec3(0.6, 3, 0.6), magenta)
end

for i, x in ipairs{-40, 0, 40, 80, 120, 160, 200} do
	box("lamp_post_" .. i, Vec3(x, 1.6, -30), Vec3(0.15, 3.2, 0.15), grey)
	point_light("lamp_post_light_" .. i, Vec3(x + 0.4, 3.2, -30), warm, 1500, 16)
end

do
	local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
	local RADIUS, RINGS, SEGMENTS, SPIKES = 14, 64, 128, 70

	local function noise(x, y, z)
		return (
				math.sin(x * 1.7 + y * 0.3 + 1.3) * math.sin(y * 2.3 - z * 0.7 + 0.4) * math.sin(z * 1.9 + x * 0.5 + 2.1) + 0.5 * math.sin(x * 4.1 - z * 3.3 + 0.7) * math.sin(y * 3.7 + x * 2.9) + 0.25 * math.sin(z * 8.3 + y * 7.1 - 1.1) * math.sin(x * 9.7 - y * 5.3)
			)
	end

	local spikes = {}
	local seed = 1

	local function random()
		seed = (seed * 16807) % 2147483647
		return seed / 2147483647
	end

	for i = 1, SPIKES do
		local up = i % 3 ~= 0
		local y = up and 0.35 + random() * 0.6 or -(0.3 + random() * 0.6)
		local a = random() * math.pi * 2
		local r = math.sqrt(1 - y * y)
		spikes[i] = {
			dir = Vec3(math.cos(a) * r, y, math.sin(a) * r),
			width = math.rad(2 + random() * 4),
			length = RADIUS * (0.2 + random() * (up and 0.55 or 0.35)),
		}
	end

	local function build(poly)
		local positions = {}

		for ring = 0, RINGS do
			local theta = ring / RINGS * math.pi

			for seg = 0, SEGMENTS do
				local phi = seg / SEGMENTS * math.pi * 2
				local dir = Vec3(math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi))
				local r = RADIUS * (1 + 0.08 * noise(dir.x * 3, dir.y * 3, dir.z * 3))

				for _, spike in ipairs(spikes) do
					local angle = math.acos(math.clamp(dir:Dot(spike.dir), -1, 1))

					if angle < spike.width then
						local t = 1 - angle / spike.width
						r = math.min(r, RADIUS - spike.length * t * t)
					end
				end

				positions[#positions + 1] = dir * r
			end
		end

		local stride = SEGMENTS + 1
		local indices = {}

		for ring = 0, RINGS - 1 do
			for seg = 0, SEGMENTS - 1 do
				local a = ring * stride + seg + 1
				local b = a + stride
				indices[#indices + 1] = a
				indices[#indices + 1] = a + 1
				indices[#indices + 1] = b
				indices[#indices + 1] = a + 1
				indices[#indices + 1] = b + 1
				indices[#indices + 1] = b
			end
		end

		local normals = {}

		for i = 1, #positions do
			normals[i] = Vec3(0, 0, 0)
		end

		for i = 1, #indices, 3 do
			local ia, ib, ic = indices[i], indices[i + 1], indices[i + 2]
			local pa = positions[ia]
			local n = (positions[ic] - pa):Cross(positions[ib] - pa)
			normals[ia] = normals[ia] + n
			normals[ib] = normals[ib] + n
			normals[ic] = normals[ic] + n
		end

		for i = 1, #positions do
			local n = normals[i]
			normals[i] = n:GetLength() > 0 and n:GetNormalized() or -positions[i]:GetNormalized()
		end

		for i = 1, #indices do
			poly:AddVertex{pos = positions[indices[i]], normal = normals[indices[i]]}
		end

		return poly
	end

	local rock = shapes.Material{
		Color = Color(0.35, 0.55, 0.6, 1),
		Roughness = 0.8,
		Metallic = 0,
		DoubleSided = true,
	}
	local cave_polygon = build(Polygon3D.New())

	for i, x in ipairs{-40, 0, 40} do
		local center = Vec3(x, RADIUS + 6, 100)
		shapes.Polygon{
			Name = "cave_" .. i,
			Position = center,
			Material = rock,
			Polygon = cave_polygon,
			CollisionShape = false,
			Collision = false,
			RigidBody = false,
		}

		if i == 2 then
			local light_ent = Entity.New{Name = "cave_light_2"}
			light_ent:AddComponent("transform")
			light_ent.transform:SetPosition(center)
			local light = light_ent:AddComponent("light_point")
			light:SetColor(warm)
			light:SetLumen(8000)
			light:SetRange(RADIUS * 1.5)
		elseif i == 3 then
			point_light("cave_light_3", center, warm, 8000, RADIUS * 1.5)
		end
	end
end

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 5, 30))
	cam:SetAngles(Deg3(-8, 0, 0))
	local rig = Entity.World:GetKeyed("player_camera_rig")

	if rig and rig:IsValid() then
		rig.transform:SetPosition(cam:GetPosition():Copy())

		if rig.player_input and rig.player_input.SyncFromCamera then
			rig.player_input:SyncFromCamera(cam)
		end
	end
end
