local module = {}

function module.CreateServices(services)
	local physics = services.physics
	local EPSILON = 0.00001
	local Vec3 = import("goluwa/structs/vec3.lua")

	local function get_world_support_points(body)
		if body.GetShapeType and body:GetShapeType() == "box" then
			local half = body:GetHalfExtents()
			local ex = half.x
			local ey = half.y
			local ez = half.z
			local points = {}
			local samples_x = {-1, 0, 1}
			local samples_z = {-1, 0, 1}

			for _, sx in ipairs(samples_x) do
				for _, sz in ipairs(samples_z) do
					points[#points + 1] = {
						local_point = Vec3(ex * sx, -ey, ez * sz),
					}
				end
			end

			return points
		end

		local points = {}

		for _, local_point in ipairs(body:GetSupportLocalPoints() or {}) do
			points[#points + 1] = {local_point = local_point}
		end

		return points
	end

	local function solve_contact(body, point, hit, dt)
		local normal = physics.GetHitNormal(hit, point)

		if not (hit and normal) then return false end

		local target = hit.position + normal * body:GetCollisionMargin()
		local correction = target - point
		local depth = correction:Dot(normal)

		if depth <= 0 then return false end

		body:ApplyCorrection(0, normal * depth, point, nil, nil, dt)

		if normal.y >= body:GetMinGroundNormalY() then
			body:SetGrounded(true)
			body:SetGroundNormal(normal)
		end

		if physics.RecordWorldCollision then
			physics.RecordWorldCollision(body, hit, normal, depth)
		end

		return true
	end

	local function get_point_velocity(body, point)
		return body:GetVelocity() + body:GetAngularVelocity():GetCross(point - body:GetPosition())
	end

	local function apply_static_contact_impulse(body, point, normal)
		if not (body.HasSolverMass and body:HasSolverMass()) then return end

		local point_velocity = get_point_velocity(body, point)
		local normal_speed = point_velocity:Dot(normal)
		local normal_impulse = 0

		if normal_speed < -EPSILON then
			local inverse_mass = body:GetInverseMassAlong(normal, point)

			if inverse_mass > EPSILON then
				normal_impulse = -normal_speed / inverse_mass
				body:ApplyImpulse(normal * normal_impulse, point)
				point_velocity = get_point_velocity(body, point)
			end
		end

		local tangent_velocity = point_velocity - normal * point_velocity:Dot(normal)
		local tangent_speed = tangent_velocity:GetLength()

		if tangent_speed <= EPSILON then return end

		local friction = math.max(body:GetFriction() or 0, 0)

		if friction <= 0 then return end

		local tangent = tangent_velocity / tangent_speed
		local tangent_inverse_mass = body:GetInverseMassAlong(tangent, point)

		if tangent_inverse_mass <= EPSILON then return end

		local tangent_impulse = -point_velocity:Dot(tangent) / tangent_inverse_mass
		local max_friction_impulse = math.max(normal_impulse, 0.05) * friction
		tangent_impulse = math.max(-max_friction_impulse, math.min(max_friction_impulse, tangent_impulse))

		if math.abs(tangent_impulse) > EPSILON then
			body:ApplyImpulse(tangent * tangent_impulse, point)
		end
	end

	local function query_support_contact(body, local_point, cast_up, cast_distance)
		local point = body:GeometryLocalToWorld(local_point)
		local hit = physics.Trace(
			point + physics.Up * cast_up,
			physics.Up * -1,
			cast_distance,
			body:GetOwner(),
			body:GetFilterFunction()
		)
		local normal = physics.GetHitNormal(hit, point)

		if not (hit and normal) then return nil end

		local target = hit.position + normal * body:GetCollisionMargin()
		local correction = target - point
		local depth = correction:Dot(normal)

		if depth <= 0 then return nil end

		return {
			point = point,
			local_point = local_point,
			hit = hit,
			normal = normal,
			depth = depth,
		}
	end

	local function solve_support_contact_patch(body, dt)
		local velocity = body:GetVelocity()
		local downward = math.max(0, -velocity.y * dt)
		local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
		local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()
		local support_points = get_world_support_points(body)
		local grounded_normal = nil
		local grounded_weight = 0
		local solved = false

		for _ = 1, 2 do
			local pass_solved = false

			for _, point_data in ipairs(support_points) do
				local contact = query_support_contact(body, point_data.local_point, cast_up, cast_distance)

				if contact then
					pass_solved = true
					body:ApplyCorrection(0, contact.normal * contact.depth, contact.point, nil, nil, dt)
					apply_static_contact_impulse(body, contact.point, contact.normal)

					if contact.normal.y >= body:GetMinGroundNormalY() then
						grounded_normal = (grounded_normal or physics.Up * 0) + contact.normal * contact.depth
						grounded_weight = grounded_weight + contact.depth
						body:SetGrounded(true)
					end

					if physics.RecordWorldCollision then
						physics.RecordWorldCollision(body, contact.hit, contact.normal, contact.depth)
					end

					solved = true
				end
			end

			if not pass_solved then break end
		end

		if grounded_normal and grounded_weight > EPSILON then
			body:SetGroundNormal((grounded_normal / grounded_weight):GetNormalized())
		end

		return solved
	end

	local function solve_motion_contacts(body, dt)
		if not body.CollisionEnabled then return end

		local sweep_margin = body:GetCollisionMargin() + body:GetCollisionProbeDistance()

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
					body:GetOwner(),
					body:GetFilterFunction()
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

		if shape and shape.GetRadius and shape.SolveSupportContacts then
			return shape:SolveSupportContacts(body, dt, solve_contact)
		end

		return solve_support_contact_patch(body, dt)
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