local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local STEP_HEIGHTS = {0.1, 0.2, 0.3, 0.34, 0.4, 0.5}
local STEP_COUNT = 6
local STEP_DEPTH = 0.6
local LANE_WIDTH = 8
local LANE_SPACING = 24
local ROW_SPACING = 30
local LABEL_DISTANCE = 30
local RAMP_ANGLES = {10, 20, 30, 40, 45, 50}
local RAMP_RISE = 2.5
local LEDGE_HEIGHTS = {0.02, 0.05, 0.1, 0.18, 0.3, 0.4}
local DROP_HEIGHTS = {0.1, 0.2, 0.34, 0.5, 1, 2}

if _G.gym then
	for _, ent in ipairs(_G.gym.entities) do
		if ent:IsValid() then ent:Remove() end
	end
end

local gym = {entities = {}, stations = {}, movers = {}}
_G.gym = gym

local function track(ent)
	list.insert(gym.entities, ent)
	return ent
end

local function station(name, position, title, lines)
	gym.stations[#gym.stations + 1] = {
		name = name,
		position = position,
		title = title,
		lines = lines,
	}
end

local function rand(i)
	return (math.sin(i * 12.9898) * 43758.5453) % 1
end

local function scaled_cube(size)
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 1)

	for _, vertex in ipairs(poly.Vertices) do
		vertex.pos.x = vertex.pos.x * size.x / 2
		vertex.pos.y = vertex.pos.y * size.y / 2
		vertex.pos.z = vertex.pos.z * size.z / 2
	end

	return poly
end

local floor_material = shapes.Material{Color = Color(0.45, 0.47, 0.5, 1), Roughness = 0.9}
local step_material = shapes.Material{Color = Color(0.8, 0.55, 0.35, 1), Roughness = 0.7}
local convex_material = shapes.Material{Color = Color(0.35, 0.6, 0.8, 1), Roughness = 0.7}
local mesh_material = shapes.Material{Color = Color(0.55, 0.75, 0.45, 1), Roughness = 0.7}
local ramp_material = shapes.Material{Color = Color(0.85, 0.8, 0.45, 1), Roughness = 0.8}
local hazard_material = shapes.Material{Color = Color(0.85, 0.35, 0.3, 1), Roughness = 0.7}
local prop_material = shapes.Material{Color = Color(0.7, 0.5, 0.3, 1), Roughness = 0.6}
local mover_material = shapes.Material{Color = Color(0.4, 0.85, 0.9, 1), Roughness = 0.4}

local function box(name, position, size, material, rotation, friction)
	return track(
		shapes.Box{
			Name = name,
			Position = position,
			Rotation = rotation,
			Size = size,
			Material = material or step_material,
			RigidBody = {MotionType = "static", WorldGeometry = true, Friction = friction or 0.8},
		}
	)
end

local row_count = 9
track(
	shapes.Box{
		Name = "gym_floor",
		Position = Vec3(
			LANE_SPACING * (#STEP_HEIGHTS - 1) / 2,
			-0.5,
			ROW_SPACING * (row_count - 1) / 2 - 8
		),
		Size = Vec3(LANE_SPACING * #STEP_HEIGHTS + 20, 1, ROW_SPACING * row_count + 20),
		Material = floor_material,
		RigidBody = {MotionType = "static", WorldGeometry = true, Friction = 0.8},
	}
)

local function lane_x(lane)
	return (lane - 1) * LANE_SPACING
end

local function row_z(row)
	return (row - 1) * ROW_SPACING
end

for row, kind in ipairs{"box", "convex", "mesh"} do
	local z0 = row_z(row)
	local title = (
		{box = "Box stairs up", convex = "Convex stairs up", mesh = "Mesh stairs up"}
	)[kind]

	for lane, height in ipairs(STEP_HEIGHTS) do
		local x = lane_x(lane)
		station(
			kind .. "_stairs_" .. lane,
			Vec3(x, 0, z0 + 1),
			title,
			{
				string.format("rise %.2f m, %d steps, depth %.1f m", height, STEP_COUNT, STEP_DEPTH),
			}
		)

		for i = 1, STEP_COUNT do
			local size = Vec3(LANE_WIDTH, height * i, STEP_DEPTH)
			local position = Vec3(x, size.y / 2, z0 - (i - 0.5) * STEP_DEPTH)

			if kind == "box" then
				box("box_step", position, size)
			elseif kind == "convex" then
				local poly = scaled_cube(size)
				local hull = convex_hull.BuildFromTriangles(poly)
				track(
					shapes.Polygon{
						Name = "convex_step",
						Position = position,
						Material = convex_material,
						Polygon = poly,
						CollisionShape = ConvexShape.New(hull),
						RigidBody = {MotionType = "static", WorldGeometry = true, ConvexHull = hull, Friction = 0.8},
					}
				)
			else
				track(
					shapes.Polygon{
						Name = "mesh_step",
						Position = position,
						Material = mesh_material,
						Polygon = scaled_cube(size),
						RigidBody = {MotionType = "static", WorldGeometry = true, Friction = 0.8},
					}
				)
			end
		end
	end
end

do
	local z0 = row_z(4)

	for lane, height in ipairs(STEP_HEIGHTS) do
		local x = lane_x(lane)
		local top = height * STEP_COUNT
		box("descent_platform", Vec3(x, top / 2, z0 + 3), Vec3(LANE_WIDTH, top, 6))
		station(
			"descent_" .. lane,
			Vec3(x, top, z0 + 3),
			"Box stairs down",
			{
				string.format("drop %.2f m per step, %d steps, walk and run -z", height, STEP_COUNT),
			}
		)

		for i = 1, STEP_COUNT - 1 do
			local size = Vec3(LANE_WIDTH, height * (STEP_COUNT - i), STEP_DEPTH)
			box("descent_step", Vec3(x, size.y / 2, z0 - (i - 0.5) * STEP_DEPTH), size)
		end
	end
end

do
	local z0 = row_z(5)

	for lane, angle in ipairs(RAMP_ANGLES) do
		local x = lane_x(lane)
		local rad = math.rad(angle)
		local length = RAMP_RISE / math.sin(rad)
		local thickness = 0.5
		local direction = Vec3(0, math.sin(rad), -math.cos(rad))
		local normal = Vec3(0, math.cos(rad), math.sin(rad))
		local rotation = Quat(math.sin(rad / 2), 0, 0, math.cos(rad / 2))
		box(
			"ramp",
			Vec3(x, 0, z0) + direction * (length / 2) - normal * (thickness / 2),
			Vec3(LANE_WIDTH, thickness, length),
			ramp_material,
			rotation,
			0.8
		)
		box(
			"ramp_landing",
			Vec3(x, RAMP_RISE / 2, z0 - length * math.cos(rad) - 3),
			Vec3(LANE_WIDTH, RAMP_RISE, 6),
			ramp_material
		)
		station(
			"ramp_" .. lane,
			Vec3(x, 0, z0 + 2),
			"Ramp " .. angle .. " deg",
			{
				angle > 45 and
				"steeper than MinGroundNormalY, not walkable" or
				"walkable",
				"stand still on it, walk up and down",
			}
		)
	end
end

do
	local z0 = row_z(6)

	for lane, height in ipairs(LEDGE_HEIGHTS) do
		local x = lane_x(lane)
		box("ledge_wide", Vec3(x, height / 2, z0 - 2), Vec3(LANE_WIDTH, height, 4))
		box(
			"ledge_lip",
			Vec3(x, height / 2, z0 - 8),
			Vec3(LANE_WIDTH, height, 0.05),
			hazard_material
		)
		box(
			"ledge_curb",
			Vec3(x, height / 2, z0 - 12),
			Vec3(LANE_WIDTH, height, 0.4),
			step_material
		)
		station(
			"ledge_" .. lane,
			Vec3(x, 0, z0 + 3),
			string.format("Ledges %.2f m", height),
			{"wide slab, 5 cm lip, 40 cm curb", "run into them at walking and sprint speed"}
		)
	end
end

do
	local z0 = row_z(7)

	for lane, height in ipairs(DROP_HEIGHTS) do
		local x = lane_x(lane)
		box("drop_platform", Vec3(x, height / 2, z0 - 3), Vec3(LANE_WIDTH, height, 8))
		station(
			"drop_" .. lane,
			Vec3(x, height, z0),
			string.format("Drop %.2f m", height),
			{"walk off the edge toward -z", "grounded should hold up to StepHeight"}
		)
	end
end

do
	local z0 = row_z(8)
	local x = lane_x(1)
	local cells = 40
	local size = 20
	local poly = Polygon3D.New()

	local function height_at(px, pz)
		return 0.5 * math.sin(px * 1.1) * math.cos(pz * 0.9) + 0.3 * math.sin(pz * 0.45 + px * 0.2)
	end

	local function vertex(px, pz)
		local e = 0.01
		local normal = Vec3(
			height_at(px - e, pz) - height_at(px + e, pz),
			2 * e,
			height_at(px, pz - e) - height_at(px, pz + e)
		):GetNormalized()
		poly:AddVertex{
			pos = Vec3(px, height_at(px, pz), pz),
			uv = Vec2(px / 4, pz / 4),
			normal = normal,
		}
	end

	for i = 0, cells - 1 do
		for j = 0, cells - 1 do
			local x0 = -size / 2 + i * size / cells
			local z_a = -size / 2 + j * size / cells
			local d = size / cells
			vertex(x0, z_a)
			vertex(x0 + d, z_a)
			vertex(x0, z_a + d)
			vertex(x0 + d, z_a)
			vertex(x0 + d, z_a + d)
			vertex(x0, z_a + d)
		end
	end

	track(
		shapes.Polygon{
			Name = "mesh_terrain",
			Position = Vec3(x, 0.6, z0 - size / 2),
			Material = mesh_material,
			Polygon = poly,
			RigidBody = {MotionType = "static", WorldGeometry = true, Friction = 0.8},
		}
	)
	station(
		"mesh_terrain",
		Vec3(x, 1.5, z0 + 2),
		"Mesh terrain",
		{
			"smooth triangle mesh bumps, like displacements",
			"stand still, walk, sprint across",
		}
	)
	local rubble_x = lane_x(2)

	for i = 1, 140 do
		local width = 0.1 + rand(i * 3) * 0.35
		local height = 0.02 + rand(i * 5) * 0.14
		local depth = 0.1 + rand(i * 7) * 0.35
		box(
			"rubble",
			Vec3(
				rubble_x + (rand(i * 11) - 0.5) * 16,
				height / 2 - 0.01,
				z0 - 2 - rand(i * 13) * 16
			),
			Vec3(width, height, depth),
			hazard_material,
			Quat(0, math.sin(rand(i * 17) * math.pi), 0, math.cos(rand(i * 17) * math.pi))
		)
	end

	station(
		"rubble",
		Vec3(rubble_x, 0, z0 + 2),
		"Rubble field",
		{
			"140 small blocks under 16 cm",
			"the detail scale a character should glide over",
		}
	)
	local gap_x = lane_x(3)
	local gap_z = z0 - 1

	for i = 0, 5 do
		local gap = i * 0.5
		box("gap_platform", Vec3(gap_x, 0.25, gap_z - 1.5), Vec3(4, 0.5, 3), step_material)
		gap_z = gap_z - 3 - gap
	end

	station(
		"gaps",
		Vec3(gap_x, 0.5, z0),
		"Gap jumps",
		{"platforms 3 m long, gaps grow by 0.5 m", "0, 0.5, 1.0 ... 2.5 m"}
	)
	local tunnel_x = lane_x(4)

	for i, ceiling in ipairs{0.9, 1.1, 1.5} do
		local tx = tunnel_x + (i - 2) * 6
		box(
			"tunnel_wall",
			Vec3(tx - 1.5, ceiling / 2, z0 - 5),
			Vec3(0.3, ceiling, 8),
			hazard_material
		)
		box(
			"tunnel_wall",
			Vec3(tx + 1.5, ceiling / 2, z0 - 5),
			Vec3(0.3, ceiling, 8),
			hazard_material
		)
		box(
			"tunnel_roof",
			Vec3(tx, ceiling + 0.15, z0 - 5),
			Vec3(3.3, 0.3, 8),
			hazard_material
		)
	end

	station(
		"tunnels",
		Vec3(tunnel_x, 0, z0 + 2),
		"Low ceilings",
		{"0.9, 1.1, 1.5 m clearance", "crouch is 0.69 m, standing 1.37 m"}
	)
	local crease_x = lane_x(5)

	for i, width in ipairs{0.45, 0.55, 0.65, 0.8, 1.0} do
		local cx = crease_x + (i - 3) * 4
		box(
			"crease_wall",
			Vec3(cx - width / 2 - 1, 1.5, z0 - 4),
			Vec3(2, 3, 6),
			step_material
		)
		box(
			"crease_wall",
			Vec3(cx + width / 2 + 1, 1.5, z0 - 4),
			Vec3(2, 3, 6),
			step_material
		)
	end

	for i, angle in ipairs{20, 45, 90} do
		local cx = crease_x + (i - 2) * 8
		local rad = math.rad(angle / 2)

		for side = -1, 1, 2 do
			box(
				"wedge_wall",
				Vec3(cx + side * math.sin(rad) * 3, 1.5, z0 - 14 - math.cos(rad) * 3),
				Vec3(0.3, 3, 6),
				step_material,
				Quat(0, math.sin(side * rad / 2), 0, math.cos(side * rad / 2))
			)
		end
	end

	station(
		"creases",
		Vec3(crease_x, 0, z0 + 2),
		"Narrow gaps and wedges",
		{"gaps 0.45 .. 1.0 m (body is 0.61 m)", "wedges of 20, 45, 90 degrees"}
	)
	local beam_x = lane_x(6)

	for i, width in ipairs{0.3, 0.5, 0.8, 1.2} do
		box(
			"beam",
			Vec3(beam_x + (i - 2.5) * 3, 0.5, z0 - 6),
			Vec3(width, 1, 12),
			step_material
		)
	end

	station(
		"beams",
		Vec3(beam_x, 0, z0 + 2),
		"Beams",
		{"1 m high, 0.3 .. 1.2 m wide", "walk the edge, fall off"}
	)
end

do
	local z0 = row_z(9)
	local x = lane_x(1)
	local steps = 18
	local rise = 0.18

	for i = 1, steps do
		local yaw = math.rad(i * 20)
		local height = rise * i
		box(
			"spiral_step",
			Vec3(x + math.cos(yaw) * 3, height / 2, z0 - 8 + math.sin(yaw) * 3),
			Vec3(2.2, height, 1.4),
			step_material,
			Quat(0, math.sin(-yaw / 2), 0, math.cos(-yaw / 2))
		)
	end

	box(
		"spiral_column",
		Vec3(x, rise * steps / 2, z0 - 8),
		Vec3(2, rise * steps, 2),
		convex_material
	)
	station(
		"spiral",
		Vec3(x + 3, 0, z0 - 4),
		"Spiral stairs",
		{"18 steps, 0.18 m rise, turning"}
	)
	local mover_x = lane_x(2)

	for i, mover in ipairs{
		{
			axis = Vec3(1, 0, 0),
			amplitude = 6,
			period = 6,
			base = Vec3(mover_x, 0.25, z0 - 4),
			size = Vec3(4, 0.5, 4),
		},
		{
			axis = Vec3(0, 1, 0),
			amplitude = 2,
			period = 8,
			base = Vec3(mover_x, 2.2, z0 - 14),
			size = Vec3(4, 0.4, 4),
		},
		{rate = 0.6, base = Vec3(mover_x, 0.3, z0 - 25), size = Vec3(8, 0.6, 8)},
	} do
		local ent = track(
			shapes.Box{
				Name = "gym_mover",
				Position = mover.base,
				Size = mover.size,
				Material = mover_material,
				RigidBody = {MotionType = "kinematic", Friction = 1},
			}
		)
		gym.movers[#gym.movers + 1] = {
			entity = ent,
			base = mover.base,
			axis = mover.axis,
			amplitude = mover.amplitude,
			period = mover.period,
			rate = mover.rate,
		}
	end

	station(
		"movers",
		Vec3(mover_x, 0.5, z0 - 4),
		"Moving platforms",
		{
			"sideways platform, an elevator and a turntable",
			"does the character ride along?",
		}
	)
	local prop_x = lane_x(3)

	for i, mass in ipairs{2, 10, 50, 250} do
		local side = 0.5 + i * 0.1
		track(
			shapes.Box{
				Name = "gym_crate",
				Position = Vec3(prop_x + (i - 2.5) * 2, side / 2 + 0.01, z0 - 4),
				Size = Vec3(side, side, side),
				Material = prop_material,
				RigidBody = {Mass = mass, AutomaticMass = false, Friction = 0.7},
			}
		)
	end

	for level = 0, 2 do
		for k = 0, 2 - level do
			track(
				shapes.Box{
					Name = "gym_stack",
					Position = Vec3(prop_x + 4 + (k + level * 0.5) * 0.8, 0.3 + level * 0.6, z0 - 10),
					Size = Vec3(0.75, 0.6, 0.75),
					Material = prop_material,
					RigidBody = {Mass = 8, AutomaticMass = false, Friction = 0.7},
				}
			)
		end
	end

	track(
		shapes.Sphere{
			Name = "gym_ball",
			Position = Vec3(prop_x - 4, 0.5, z0 - 10),
			Radius = 0.5,
			Material = mover_material,
			RigidBody = {Mass = 6, AutomaticMass = false, Friction = 0.5, Restitution = 0.3},
		}
	)
	station(
		"props",
		Vec3(prop_x, 0, z0 + 2),
		"Dynamic props",
		{
			"crates of 2, 10, 50, 250 kg, a stack and a ball",
			"walk into them, stand on them",
		}
	)
	local jump_x = lane_x(4)

	for i, height in ipairs{0.3, 0.45, 0.55, 0.65, 0.8, 1.0} do
		box("jump_block", Vec3(jump_x, height / 2, z0 - 3 - (i - 1) * 3), Vec3(3, height, 2))
	end

	station(
		"jumps",
		Vec3(jump_x, 0, z0 + 1),
		"Jump heights",
		{"0.30 .. 1.0 m blocks every 3 m", "jump apex is about 0.6 m"}
	)
	local launch_x = lane_x(5)
	local rad = math.rad(20)
	local length = 6
	local direction = Vec3(0, math.sin(rad), -math.cos(rad))
	local normal = Vec3(0, math.cos(rad), math.sin(rad))
	box(
		"launch_ramp",
		Vec3(launch_x, 0, z0) + direction * (length / 2) - normal * 0.25,
		Vec3(4, 0.5, length),
		ramp_material,
		Quat(math.sin(rad / 2), 0, 0, math.cos(rad / 2))
	)
	local lip = length * math.sin(rad)
	box(
		"launch_landing",
		Vec3(launch_x, lip / 2 - 0.5, z0 - length * math.cos(rad) - 14),
		Vec3(6, lip + 1, 8),
		step_material
	)
	station(
		"launch",
		Vec3(launch_x, 0, z0 + 4),
		"Ramp launch",
		{"20 degree ramp ending in a gap", "sprint up: you should leave the ground"}
	)
	local wall_x = lane_x(6)

	for i, angle in ipairs{35, 45, 55, 65, 75} do
		local rad_w = math.rad(angle)
		box(
			"slope_wall",
			Vec3(wall_x + (i - 3) * 4.5, 0, z0 - 4) + Vec3(0, math.sin(rad_w) * 2, -math.cos(rad_w) * 2),
			Vec3(3.5, 0.4, 4),
			hazard_material,
			Quat(math.sin(rad_w / 2), 0, 0, math.cos(rad_w / 2)),
			0.8
		)
	end

	station(
		"slope_limit",
		Vec3(wall_x, 0, z0 + 2),
		"Slope limit",
		{
			"35, 45, 55, 65, 75 degree slabs",
			"where does walking up stop and sliding start",
		}
	)
end

event.AddListener("PhysicsUpdate", "gym_movers", function(dt)
	gym.clock = (gym.clock or 0) + dt

	for _, mover in ipairs(gym.movers) do
		if mover.entity:IsValid() then
			if mover.rate then
				local half = gym.clock * mover.rate / 2
				mover.entity.transform:SetRotation(Quat(0, math.sin(half), 0, math.cos(half)))
			else
				local offset = math.sin(gym.clock * math.pi * 2 / mover.period) * mover.amplitude
				mover.entity.transform:SetPosition(mover.base + mover.axis * offset)
			end
		end
	end
end)

event.AddListener("Update", "gym_labels", function()
	local rig = _G.PLAYER_RIG

	if not rig or not rig:IsValid() then return end

	local position = rig.transform:GetPosition()

	for _, entry in ipairs(gym.stations) do
		if (entry.position - position):GetLength() < LABEL_DISTANCE then
			local lines = {entry.title}

			for _, line in ipairs(entry.lines) do
				lines[#lines + 1] = line
			end

			debug_draw.DrawText{
				id = "gym_" .. entry.name,
				position = entry.position + Vec3(0, 2.2, 0),
				lines = lines,
				time = 0.2,
				padding = 6,
				line_gap = 2,
				background_alpha = 0.66,
				title_color = Color(0.7, 0.9, 1, 1),
				text_color = Color(0.9, 0.9, 0.94, 1),
			}
		end
	end
end)

event.AddListener("Draw2D", "gym_overlay", function()
	local rig = _G.PLAYER_RIG

	if not rig or not rig:IsValid() then return end

	local movement = rig.character_movement
	local body = rig.rigid_body
	local feet = rig.transform:GetPosition()
	local velocity = body:GetVelocity()
	local normal = body.GroundNormal
	local nearest, nearest_distance

	for _, entry in ipairs(gym.stations) do
		local distance = (entry.position - feet):GetLength()

		if not nearest_distance or distance < nearest_distance then
			nearest = entry
			nearest_distance = distance
		end
	end

	local lines = {
		"Character",
		string.format(
			"mode %s%s%s",
			movement.Mode,
			movement.Swimming and " swimming" or "",
			movement.Crouching and " crouching" or ""
		),
		string.format("feet %.2f %.2f %.2f", feet.x, feet.y, feet.z),
		string.format(
			"speed %.2f m/s  vertical %.2f",
			math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z),
			velocity.y
		),
		"",
		"Ground",
		string.format(
			"movement grounded %s  jumping %s",
			tostring(movement:GetGrounded()),
			tostring(movement.jumping or false)
		),
		string.format("solver contact %s", tostring(body:GetGrounded())),
		string.format(
			"ground %s",
			body.GroundEntity and
				body.GroundEntity:IsValid() and
				body.GroundEntity.Name or
				"none"
		),
		string.format(
			"normal %.2f %.2f %.2f  slope %.1f deg  (walkable above %.2f)",
			normal.x,
			normal.y,
			normal.z,
			math.deg(math.acos(math.clamp(normal.y, -1, 1))),
			movement.MinGroundNormalY
		),
		string.format(
			"flat ground memory %.2f s  step height %.2f m",
			math.max(movement.flat_ground_time or 0, 0),
			movement.StepHeight
		),
		string.format("render offset %.3f", rig.transform.RenderOffset.y),
	}

	if nearest then
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("nearest %s (%.1f m)", nearest.name, nearest_distance)
		lines[#lines + 1] = "gym.Goto(name) teleports to a station"
	end

	local width = render2d.GetSize()
	debug_draw.DrawTextBlock(
		lines,
		width - 340,
		16,
		{
			padding = 8,
			line_gap = 3,
			background_alpha = 0.7,
			title_color = Color(0.7, 0.9, 1, 1),
			text_color = Color(0.9, 0.9, 0.94, 1),
		}
	)
end)

function gym.Goto(name)
	for _, entry in ipairs(gym.stations) do
		if entry.name == name then
			_G.PLAYER_RIG.character_movement:TeleportTo(entry.position)
			return entry
		end
	end

	error("unknown gym station " .. name, 2)
end

return gym
