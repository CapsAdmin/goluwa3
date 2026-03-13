local physics = import("goluwa/physics/shared.lua")
local solver = import("goluwa/physics/solver.lua")

function physics.UpdateRigidBodies(dt)
	if not dt or dt <= 0 then return end

	local rigid_body = physics.GetRigidBodyMeta()
	local bodies = rigid_body.Instances or {}

	if #bodies == 0 then return end

	local substeps = math.max(1, physics.RigidBodySubsteps or 1)
	local iterations = math.max(1, physics.RigidBodyIterations or 1)
	local sub_dt = dt / substeps

	for _, body in ipairs(bodies) do
		if physics.IsActiveRigidBody(body) then body:SynchronizeFromTransform() end
	end

	for _ = 1, substeps do
		for _, body in ipairs(bodies) do
			if physics.IsActiveRigidBody(body) then
				body:SetGrounded(false)
				body:SetGroundNormal(physics.Up)
				body:Integrate(sub_dt, physics.Gravity)
			end
		end

		for _ = 1, iterations do
			solver.SolveDistanceConstraints(sub_dt)
			solver.SolveRigidBodyPairs(bodies, sub_dt)

			for _, body in ipairs(bodies) do
				if physics.IsActiveRigidBody(body) then
					solver.SolveBodyContacts(body, sub_dt)
				end
			end
		end

		for _, body in ipairs(bodies) do
			if physics.IsActiveRigidBody(body) then body:UpdateVelocities(sub_dt) end
		end
	end

	for _, body in ipairs(bodies) do
		if physics.IsActiveRigidBody(body) then body:WriteToTransform() end
	end
end

return physics