local module = {}

function module.CreateServices(services)
	local physics = services.physics

	local function solve_contact(body, point, hit, dt)
		local normal = physics.GetHitNormal(hit, point)

		if not (hit and normal) then return false end

		local target = hit.position + normal * body.CollisionMargin
		local correction = target - point
		local depth = correction:Dot(normal)

		if depth <= 0 then return false end

		body:ApplyCorrection(0, normal * depth, point, nil, nil, dt)

		if normal.y >= body.MinGroundNormalY then
			body:SetGrounded(true)
			body:SetGroundNormal(normal)
		end

		return true
	end

	local function solve_motion_contacts(body, dt)
		if not body.CollisionEnabled then return end

		local sweep_margin = body.CollisionMargin + body.CollisionProbeDistance

		for _, local_point in ipairs(body:GetCollisionLocalPoints()) do
			local previous = body:GeometryLocalToWorld(local_point, body:GetPreviousPosition(), body:GetPreviousRotation())
			local current = body:GeometryLocalToWorld(local_point)
			local delta = current - previous
			local distance = delta:GetLength()

			if distance > 0.0001 then
				local hit = physics.Trace(
					previous,
					delta,
					distance + sweep_margin,
					body.Owner,
					body.FilterFunction
				)

				if hit and hit.distance <= distance + sweep_margin then
					solve_contact(body, current, hit, dt)
				end
			end
		end
	end

	local function solve_support_contacts(body, dt)
		if not body.CollisionEnabled then return end

		local shape = body:GetPhysicsShape()

		if shape and shape.SolveSupportContacts then
			return shape:SolveSupportContacts(body, dt, solve_contact)
		end
	end

	local function solve_body_contacts(body, dt)
		solve_motion_contacts(body, dt)
		solve_support_contacts(body, dt)
	end

	return {
		SolveContact = solve_contact,
		SolveBodyContacts = solve_body_contacts,
	}
end

return module