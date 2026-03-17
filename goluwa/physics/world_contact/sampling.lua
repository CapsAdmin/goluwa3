local physics = import("goluwa/physics.lua")
local shape_accessors = import("goluwa/physics/shape_accessors.lua")
local world_contact_sampling = {}

local function append_unique_sample(samples, lookup, key_fn, body_local_point, world_point, previous_world_point, preferred_direction)
	local key = key_fn(body_local_point)

	if not key or lookup[key] then return end

	lookup[key] = true
	samples[#samples + 1] = {
		local_point = body_local_point,
		point = world_point,
		previous_point = previous_world_point,
		preferred_direction = preferred_direction,
	}
end

local function add_collider_sample(samples, lookup, key_fn, body, collider, local_sample)
	local world_point = collider:GeometryLocalToWorld(local_sample)
	local previous_world_point = collider:GeometryLocalToWorld(
		local_sample,
		collider:GetPreviousPosition(),
		collider:GetPreviousRotation()
	)
	local body_local_point = body:WorldToLocal(world_point)
	local delta = world_point - previous_world_point
	local preferred_direction = delta:GetLength() > physics.EPSILON and (delta / delta:GetLength()) or nil
	append_unique_sample(
		samples,
		lookup,
		key_fn,
		body_local_point,
		world_point,
		previous_world_point,
		preferred_direction
	)
end

function world_contact_sampling.BuildColliderSamples(body, collider, source, key_fn)
	local samples = {}
	local lookup = {}

	if source ~= "support" then
		for _, point in ipairs(collider:GetCollisionLocalPoints() or {}) do
			add_collider_sample(samples, lookup, key_fn, body, collider, point)
		end
	end

	if source ~= "collision" then
		for _, point in ipairs(collider:GetSupportLocalPoints() or {}) do
			add_collider_sample(samples, lookup, key_fn, body, collider, point)
		end
	end

	return samples
end

function world_contact_sampling.BuildTraceContact(body, point, hit, epsilon)
	epsilon = epsilon or physics.EPSILON
	local surface_contact = physics.GetHitSurfaceContact and physics.GetHitSurfaceContact(hit, point) or nil
	local normal = surface_contact and surface_contact.normal or hit.normal or hit.face_normal or nil
	local contact_position = surface_contact and surface_contact.position or hit.position or nil

	if not (normal and contact_position) then return nil end

	local target = contact_position + normal * body:GetCollisionMargin()
	local correction = target - point
	local depth = correction:Dot(normal)

	if depth <= epsilon then return nil end

	return {
		point = point,
		position = contact_position:Copy(),
		hit = hit,
		normal = normal,
		depth = depth,
	}
end

function world_contact_sampling.CollectTraceContacts(body, kind, contacts, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local get_contact_kind_policy = options.get_contact_kind_policy
	local finalize_world_contact = options.finalize_world_contact
	local local_point_key = options.local_point_key
	local owner = body:GetOwner()
	local filter = body:GetFilterFunction()
	local cast_up = body:GetCollisionMargin() + (
			body.GetCollisionProbeDistance and
			body:GetCollisionProbeDistance() or
			0
		)
	local velocity_length = body:GetVelocity():GetLength()
	local angular_speed = body:GetAngularVelocity():GetLength()
	local allow_sweep_fallback = not (body:GetGrounded() and velocity_length <= 0.2 and angular_speed <= 0.35)
	local policy = get_contact_kind_policy(kind)

	for _, collider in ipairs(body:GetColliders() or {}) do
		local polyhedron = shape_accessors.GetBodyPolyhedron(collider)
		local trace_sample_source = polyhedron and nil or "collision"

		if allow_sweep_fallback then
			for _, sample in ipairs(world_contact_sampling.BuildColliderSamples(body, collider, trace_sample_source, local_point_key)) do
				local previous_point = sample.previous_point or sample.point
				local sweep = sample.point - previous_point
				local sweep_distance = sweep:GetLength()

				if sweep_distance > epsilon then
					local hit = physics.Trace(previous_point, sweep, sweep_distance + cast_up, owner, filter)

					if
						hit and
						hit.distance <= sweep_distance + cast_up and
						not (
							polyhedron and
							hit.primitive and
							hit.primitive.brush_planes
						)
					then
						local contact = world_contact_sampling.BuildTraceContact(body, sample.point, hit, epsilon)

						if contact then
							finalize_world_contact(body, kind, policy, contacts, contact, sample.local_point)
						end
					end
				end
			end
		end
	end
end

return world_contact_sampling