local module = {}

local function sort(a, b)
	return a.left < b.left
end

function module.BuildEntries(physics, bodies)
	local entries = {}

	for _, body in ipairs(bodies) do
		if
			physics.IsActiveRigidBody(body) and
			body.CollisionEnabled and
			not (
				body.Owner and
				(
					body.Owner.PhysicsNoCollision or
					body.Owner.NoPhysicsCollision
				)
			)
		then
			local bounds = body:GetBroadphaseAABB()
			local previous_bounds = body:GetBroadphaseAABB(body:GetPreviousPosition(), body:GetPreviousRotation())
			bounds.min_x = math.min(bounds.min_x, previous_bounds.min_x)
			bounds.min_y = math.min(bounds.min_y, previous_bounds.min_y)
			bounds.min_z = math.min(bounds.min_z, previous_bounds.min_z)
			bounds.max_x = math.max(bounds.max_x, previous_bounds.max_x)
			bounds.max_y = math.max(bounds.max_y, previous_bounds.max_y)
			bounds.max_z = math.max(bounds.max_z, previous_bounds.max_z)
			entries[#entries + 1] = {
				body = body,
				bounds = bounds,
				center = body:GetPosition(),
				left = bounds.min_x,
				right = bounds.max_x,
			}
		end
	end

	table.sort(entries, sort)
	return entries
end

return module