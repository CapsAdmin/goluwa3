local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local steam = import("goluwa/steam/steam.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local u = steam.source2meters
local rig = _G.PLAYER_RIG
local look, movement, body = rig.player_input, rig.player_movement, rig.rigid_body
look:SetMode("walk")
print(
	string.format(
		"DIMS radius=%.4f height=%.4f eye=%.4f step=%.4f gravity_scale=%.3f min_ground_y=%.2f",
		movement.Radius,
		movement.Height,
		movement.EyeHeight,
		movement.StepHeight,
		body:GetGravityScale(),
		body:GetMinGroundNormalY()
	)
)

local function box(name, size, position)
	local e = Entity.New({Name = name})
	e:AddComponent("transform")
	e.transform:SetPosition(position)
	e:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(size),
			Size = size,
			MotionType = "static",
			Friction = 0.5,
			Restitution = 0,
			WorldGeometry = true,
		}
	)
	return e
end

local floor = box("step_floor", Vec3(400, 1, 400), Vec3(0, -0.5, 0))

if os.getenv("NO_BHOP") then
	event.RemoveListener("PlayerMove", "bhop")
	movement:SetStickToGround(true)
	movement:SetAirAcceleration(10)
end

if os.getenv("TRACE") then
	local f = movement.TryStepUp
	movement.TryStepUp = function(self, d, dist)
		local r = f(self, d, dist)
		print(
			string.format(
				"  TryStepUp dist=%.3f -> %s  y=%.3f v=(%.2f %.2f %.2f) g=%s",
				dist,
				tostring(r),
				body:GetPosition().y,
				body.Velocity.x,
				body.Velocity.y,
				body.Velocity.z,
				tostring(body:GetGrounded())
			)
		)
		return r
	end

	event.AddListener(
		"PhysicsUpdate",
		"st_trace",
		function()
			print(
				string.format(
					"  tick y=%.3f v=(%.2f %.2f %.2f) g=%s was=%s",
					body:GetPosition().y,
					body.Velocity.x,
					body.Velocity.y,
					body.Velocity.z,
					tostring(body:GetGrounded()),
					tostring(movement.was_grounded)
				)
			)
		end,
		{priority = -50}
	)
end

local trials = {}

for h in (os.getenv("HEIGHTS") or "0.20,0.32,0.45"):gmatch("[^,]+") do
	trials[#trials + 1] = {height = tonumber(h), expect = tonumber(h) <= 0.34 and "climb" or "blocked"}
end

if os.getenv("NO_SUPPORT") then
	local sc = import("goluwa/physics/shapes/support_contacts.lua")
	sc.SweepCollider = function()
		return nil
	end
end

if os.getenv("NO_STEP") then movement.TryStepUp = function() end end

local trial_index, ledge, frames_in_trial, start_pos = 0, nil, 0, nil
local forward = Vec3(0, 0, -1)

event.AddListener(
	"PhysicsUpdate",
	"step_test_input",
	function()
		look.move_local = Vec3(0, 0, 1)
		look.mouse_trapped = true
		look.speed_multiplier = 1
		movement.input_frame = system.GetFrameNumber()
	end,
	{priority = 100}
)

local steps = 0

event.AddListener("PhysicsUpdate", "step_test_driver", function()
	steps = steps + 1
	local trial = trials[trial_index]

	if not trial or steps - frames_in_trial > 150 then
		if trial then
			local pos = rig.transform:GetPosition()
			local feet = pos.y - movement.Height * 0.5
			local travelled = (pos - start_pos):GetLength()
			print(
				string.format(
					"TRIAL ledge=%.2fm (%.1f units) expect=%s feet_y=%.3f travelled=%.2f grounded=%s => %s",
					trial.height,
					trial.height / u,
					trial.expect,
					feet,
					travelled,
					tostring(body:GetGrounded()),
					(
							(
								trial.expect == "climb" and
								feet > trial.height - 0.03
							)
							or
							(
								trial.expect == "blocked" and
								feet < 0.05
							)
						)
						and
						"OK" or
						"FAIL"
				)
			)
			ledge:Remove()
		end

		trial_index = trial_index + 1
		trial = trials[trial_index]

		if not trial then
			system.ShutDown(0)
			return
		end

		forward = Vec3(look:GetForward().x, 0, look:GetForward().z):GetNormalized()
		local right = forward:GetCross(Vec3(0, 1, 0))
		ledge = box(
			"step_ledge",
			Vec3(20, trial.height, 20),
			forward * 12 + Vec3(0, trial.height * 0.5, 0)
		)
		rig.transform:SetPosition(Vec3(0, movement.Height * 0.5 + 0.02, 0))
		body:SynchronizeFromTransform()
		body.PreviousPosition = body.Position:Copy()
		body:SetVelocity(Vec3())
		frames_in_trial = steps
		start_pos = rig.transform:GetPosition():Copy()
	end
end)
