local physics = import("goluwa/physics.lua")
local solver = import("goluwa/physics/solver.lua")
local kinematic_controller = import("goluwa/physics/kinematic_controller.lua")
local RigidBodyComponent = import("goluwa/ecs/components/3d/rigid_body.lua")

function physics.UpdateRigidBodies(dt)
	if not dt or dt <= 0 then return end

	local bodies = RigidBodyComponent.Instances or {}

	if #bodies == 0 then return end

	local substeps = math.max(1, physics.RigidBodySubsteps or 1)
	local iterations = math.max(1, physics.RigidBodyIterations or 1)
	local sub_dt = dt / substeps
	physics.BeginCollisionFrame()

	for _, body in ipairs(bodies) do
		if physics.IsActiveRigidBody(body) then body:SynchronizeFromTransform() end
	end

	for _ = 1, substeps do
		if solver.BeginStep then solver:BeginStep() end

		for _, body in ipairs(bodies) do
			if physics.IsActiveRigidBody(body) then
				if body:IsKinematic() or body:HasKinematicController() then
					kinematic_controller.UpdateBody(body, sub_dt, physics.Gravity)
				elseif body:GetAwake() then
					body:SetGrounded(false)
					body:SetGroundNormal(physics.Up)
					body:Integrate(sub_dt, physics.Gravity)
				else
					body.PreviousPosition = body.Position:Copy()
					body.PreviousRotation = body.Rotation:Copy()
				end
			end
		end

		for _ = 1, iterations do
			solver.SolveRigidBodyPairs(bodies, sub_dt)

			for _, body in ipairs(bodies) do
				if physics.IsActiveRigidBody(body) then
					if body:IsDynamic() and body:GetAwake() then
						solver.SolveBodyContacts(body, sub_dt)
					end
				end
			end

			solver.SolveDistanceConstraints(sub_dt)
		end

		for _, body in ipairs(bodies) do
			if physics.IsActiveRigidBody(body) then
				body:UpdateVelocities(sub_dt)
				body:UpdateSleepState(sub_dt)
			end
		end
	end

	for _, body in ipairs(bodies) do
		if physics.IsActiveRigidBody(body) then body:ClearAccumulators() end
	end

	for _, body in ipairs(bodies) do
		if physics.IsActiveRigidBody(body) then body:WriteToTransform() end
	end

	physics.DispatchCollisionEvents()
end

return physics