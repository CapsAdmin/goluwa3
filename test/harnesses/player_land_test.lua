local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local rig = _G.PLAYER_RIG
local look, movement, body = rig.player_input, rig.player_movement, rig.rigid_body
look:SetMode("walk")
local steam = import("goluwa/steam/steam.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Quat = import("goluwa/structs/quat.lua")
steam.SetMap("gm_construct")
local ready, wait = false, 0
local cr = import("goluwa/physics/contact_resolution.lua")
local sc = import("goluwa/physics/shapes/support_contacts.lua")
local dbg = false

do
	local f = cr.ResolvePairClusters
	cr.ResolvePairClusters = function(a, b, clusters, n, dt, o)
		if dbg then
			local parts = {}

			for i = 1, n do
				parts[#parts + 1] = string.format(
					"[n %.2f %.2f %.2f ov %.4f]",
					clusters[i].normal.x,
					clusters[i].normal.y,
					clusters[i].normal.z,
					clusters[i].overlap
				)
			end

			print(
				string.format("   RC y=%.4f vy=%.2f %s", b.Position.y, b.Velocity.y, table.concat(parts, " "))
			)
		end

		return f(a, b, clusters, n, dt, o)
	end
	local g = sc.SweepCollider
	sc.SweepCollider = function(b, dt)
		local hit = g(b, dt)

		if dbg then
			print(
				string.format(
					"   SUP y=%.4f -> %s",
					b.Position.y,
					hit and
						string.format(
							"n %.2f %.2f %.2f dist %.4f",
							hit.normal.x,
							hit.normal.y,
							hit.normal.z,
							hit.distance
						) or
						"none"
				)
			)
		end

		return hit
	end
end

local steps, phase, jump_step, land_step, land_x = 0, "load", nil, nil, nil
local forward = Vec3(0, 0, -1)
local hold = true

event.AddListener(
	"PhysicsUpdate",
	"land_input",
	function()
		look.move_local = (phase == "air" or phase == "walk") and hold and Vec3(0, 0, 1) or Vec3()
		look.mouse_trapped = true
		look.speed_multiplier = tonumber(os.getenv("SPEED") or 1)
		movement.input_frame = system.GetFrameNumber()
	end,
	{priority = 100}
)

local start_z

event.AddListener("Update", "land_load", function(dt)
	wait = wait + dt

	if phase == "load" and steam.bsp_world and steam.bsp_world.rigid_body and wait > 6 then
		look:SetRotation(Quat():SetAngles(Ang3(0, -1.50123 + math.pi, 0)))
		look:SetMode("walk")
		rig.transform:SetPosition(Vec3(33.878006, -1.484, 24.879402))
		body:SynchronizeFromTransform()
		phase = "settle"
		steps = 0
	end
end)

event.AddListener("PhysicsUpdate", "land_driver", function()
	if phase == "load" then return end

	steps = steps + 1
	local p = rig.transform:GetPosition()
	local v = body:GetVelocity()

	if phase == "settle" and steps == 60 then
		phase = "walk"
		start_z = p.z
		walk_start = steps
	end

	if phase == "walk" and steps == 120 then
		print(
			string.format(
				"WALK speed after 1s: %.2f m/s (GroundSpeed %.2f)",
				Vec3(v.x, 0, v.z):GetLength(),
				movement.GroundSpeed
			)
		)
		movement.jump_requested = true
		phase = "air"
		jump_step = steps
	elseif phase == "air" and steps > jump_step + 3 and movement.was_grounded then
		land_step = steps
		land_z = p.z
		land_x = p.x
		hold = false
		phase = "landed"
		print(string.format("LAND at step %d (%.2fs after jump)", steps, (steps - jump_step) / 60))
	elseif phase == "landed" then
		local k = steps - land_step

		if k % 6 == 0 and k <= 90 then
			print(
				string.format(
					"  +%2d  speed=%.2f grounded=%s travelled=%.2f m",
					k,
					Vec3(v.x, 0, v.z):GetLength(),
					tostring(movement.was_grounded),
					(Vec3(p.x, 0, p.z) - Vec3(land_x, 0, land_z)):GetLength()
				)
			)
		end

		if k > 90 then system.ShutDown(0) end
	end

	dbg = phase == "air" and steps - jump_step >= 44 and steps - jump_step <= 47

	if phase == "air" and steps - jump_step >= 38 and steps - jump_step <= 56 then
		print(
			string.format(
				"  a%d y=%.4f vy=%.3f g=%s body_g=%s",
				steps - jump_step,
				p.y,
				v.y,
				tostring(movement.was_grounded),
				tostring(body:GetGrounded())
			)
		)
	end

	if false then
		print(
			string.format(
				"  air %d speed=%.2f y=%.2f grounded=%s",
				steps - jump_step,
				Vec3(v.x, 0, v.z):GetLength(),
				p.y,
				tostring(movement.was_grounded)
			)
		)
	end
end)
