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

		local rigid_body_pairs = solver.BuildBroadphasePairs and solver.BuildBroadphasePairs(bodies) or bodies
		local constraints = physics.Constraints or physics.DistanceConstraints or {}
		local simulation_islands = solver.BuildSimulationIslands and
			solver.BuildSimulationIslands(bodies, rigid_body_pairs, constraints) or
			nil
		local newly_awoken_bodies = {}

		if simulation_islands and simulation_islands[1] and solver.PrepareSimulationIslands then
			local woke_any
			woke_any, newly_awoken_bodies = solver.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)

			if woke_any then
				for body_index = 1, #newly_awoken_bodies do
					local body = newly_awoken_bodies[body_index]

					if physics.IsActiveRigidBody(body) and body:GetAwake() then
						body:SetGrounded(false)
						body:SetGroundNormal(physics.Up)
						body:Integrate(sub_dt, physics.Gravity)
					end
				end

				rigid_body_pairs = solver.BuildBroadphasePairs and solver.BuildBroadphasePairs(bodies) or bodies
				simulation_islands = solver.BuildSimulationIslands and
					solver.BuildSimulationIslands(bodies, rigid_body_pairs, constraints) or
					nil

				if simulation_islands and simulation_islands[1] and solver.PrepareSimulationIslands then
					solver.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)
				end
			end
		end

		for _ = 1, iterations do
			if simulation_islands and simulation_islands[1] then
				for island_index = 1, #simulation_islands do
					local island = simulation_islands[island_index]

					if
						not (
							solver.IsSimulationIslandSleeping and
							solver.IsSimulationIslandSleeping(island)
						)
					then
						solver.SolveRigidBodyPairs(island.pairs, sub_dt)
						local dynamic_bodies = island.awake_dynamic_bodies or island.dynamic_bodies or island.bodies

						for body_index = 1, #dynamic_bodies do
							local body = dynamic_bodies[body_index]

							if physics.IsActiveRigidBody(body) then
								solver.SolveBodyContacts(body, sub_dt)
							end
						end

						solver.SolveDistanceConstraints(sub_dt, island.constraints)
					end
				end
			else
				solver.SolveRigidBodyPairs(rigid_body_pairs, sub_dt)

				for _, body in ipairs(bodies) do
					if physics.IsActiveRigidBody(body) then
						if body:IsDynamic() and body:GetAwake() then
							solver.SolveBodyContacts(body, sub_dt)
						end
					end
				end

				solver.SolveDistanceConstraints(sub_dt, constraints)
			end
		end

		for _, body in ipairs(bodies) do
			if physics.IsActiveRigidBody(body) then
				body:UpdateVelocities(sub_dt)
				body:UpdateSleepState(sub_dt)
			end
		end

		if simulation_islands and simulation_islands[1] and solver.FinalizeSimulationIslands then
			solver.FinalizeSimulationIslands(simulation_islands)
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