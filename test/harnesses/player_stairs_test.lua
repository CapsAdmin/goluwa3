local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local rig = _G.PLAYER_RIG
local look, movement, body = rig.player_input, rig.player_movement, rig.rigid_body
look:SetMode("walk")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local poly = Polygon3D.New()

local function tri(a, b, c, center)
	local n = (b - a):GetCross(c - a)

	if n:Dot(((a + b + c) / 3) - center) < 0 then b, c = c, b end

	poly:AddVertex({pos = a})
	poly:AddVertex({pos = b})
	poly:AddVertex({pos = c})
end

local function add_box(min, max)
	local center = (min + max) / 2
	local x0, y0, z0, x1, y1, z1 = min.x, min.y, min.z, max.x, max.y, max.z
	local v = {
		Vec3(x0, y0, z0),
		Vec3(x1, y0, z0),
		Vec3(x1, y1, z0),
		Vec3(x0, y1, z0),
		Vec3(x0, y0, z1),
		Vec3(x1, y0, z1),
		Vec3(x1, y1, z1),
		Vec3(x0, y1, z1),
	}
	local faces = {
		{1, 2, 3, 4},
		{5, 6, 7, 8},
		{1, 2, 6, 5},
		{4, 3, 7, 8},
		{1, 4, 8, 5},
		{2, 3, 7, 6},
	}

	for _, f in ipairs(faces) do
		tri(v[f[1]], v[f[2]], v[f[3]], center)
		tri(v[f[1]], v[f[3]], v[f[4]], center)
	end
end

local STEP_H, STEP_D, N = tonumber(os.getenv("RISE") or 0.25), 0.6, 12
local DOWN = os.getenv("DOWN")

if DOWN then
	local low = -STEP_H * N
	add_box(Vec3(-20, low - 1, -40), Vec3(20, low, 20))
	add_box(Vec3(-20, low, -3), Vec3(20, 0, 20))

	for i = 1, N do
		add_box(Vec3(-20, low, -3 - i * STEP_D), Vec3(20, -STEP_H * i, -3 - (i - 1) * STEP_D))
	end
else
	add_box(Vec3(-20, -1, -40), Vec3(20, 0, 20))

	for i = 1, N do
		add_box(Vec3(-20, 0, -3 - i * STEP_D), Vec3(20, STEP_H * i, -3 - (i - 1) * STEP_D))
	end
end

poly:BuildBoundingBox()
local world = Entity.New({Name = "stairs_world"})
world:AddComponent("transform")
world:AddComponent(
	"rigid_body",
	{
		Shape = MeshShape.New(poly),
		MotionType = "static",
		Friction = 0.5,
		WorldGeometry = true,
	}
)
local start_y = movement.Height * 0.5 + 0.02
rig.transform:SetPosition(Vec3(0, start_y, DOWN and -1 or 0))
body:SynchronizeFromTransform()
body.PreviousPosition = body.Position:Copy()

event.AddListener(
	"PhysicsUpdate",
	"stairs_input",
	function()
		look.move_local = Vec3(0, 0, 1)
		look.mouse_trapped = true
		look.speed_multiplier = 1
		movement.input_frame = system.GetFrameNumber()
	end,
	{priority = 100}
)

local cr = import("goluwa/physics/contact_resolution.lua")
local watch = false

do
	local f = cr.ResolvePairClusters
	cr.ResolvePairClusters = function(a, b, clusters, n, dt, o)
		if watch then
			local parts = {}

			for i = 1, n do
				local c = clusters[i].contacts[1]
				parts[#parts + 1] = string.format(
					"[n %.2f %.2f %.2f ov %.3f pa(%.3f %.3f %.3f) pb(%.3f %.3f %.3f)]",
					clusters[i].normal.x,
					clusters[i].normal.y,
					clusters[i].normal.z,
					clusters[i].overlap,
					c.point_a.x,
					c.point_a.y,
					c.point_a.z,
					c.point_b.x,
					c.point_b.y,
					c.point_b.z
				)
			end

			print(
				string.format(
					"   RC pos %.3f %.3f %.3f v %.2f %.2f %.2f: %s",
					b.Position.x,
					b.Position.y,
					b.Position.z,
					b.Velocity.x,
					b.Velocity.y,
					b.Velocity.z,
					table.concat(parts, " ")
				)
			)
		end

		return f(a, b, clusters, n, dt, o)
	end
end

local steps, airborne, last_z = 0, 0, nil

event.AddListener("PhysicsUpdate", "stairs_driver", function()
	steps = steps + 1
	watch = false

	if steps > 60 and not movement.was_grounded then airborne = airborne + 1 end

	if steps >= 40 and steps <= 100 then
		local p = rig.transform:GetPosition()
		print(
			string.format(
				"  t=%d y=%.3f z=%.3f vy=%.2f vz=%.2f ctl=%s body=%s",
				steps,
				p.y,
				p.z,
				body:GetVelocity().y,
				body:GetVelocity().z,
				tostring(movement.was_grounded),
				tostring(body:GetGrounded())
			)
		)
	end

	if false then
		local p = rig.transform:GetPosition()
		print(
			string.format(
				"  t=%d y=%.3f z=%.3f vz=%.2f grounded=%s",
				steps,
				p.y,
				p.z,
				body:GetVelocity().z,
				tostring(movement.was_grounded)
			)
		)
	end

	if steps == 360 then
		local p = rig.transform:GetPosition()
		print(
			string.format(
				"STAIRS rise=%.2f %s final pos y=%.2f z=%.2f feet=%.2f airborne_ticks=%d/300",
				STEP_H,
				DOWN and "down" or "up",
				p.y,
				p.z,
				p.y - movement.Height * 0.5,
				airborne
			)
		)
		system.ShutDown(0)
	end
end)
