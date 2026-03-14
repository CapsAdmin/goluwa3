local module = {}

function module.CreateServices(services)
	local Vec3 = services.Vec3
	local resolve_pair_penetration = services.resolve_pair_penetration

	local function solve_aabb_pair_collision(body_a, body_b, bounds_a, bounds_b, dt)
		local overlap_x = math.min(bounds_a.max_x, bounds_b.max_x) - math.max(bounds_a.min_x, bounds_b.min_x)
		local overlap_y = math.min(bounds_a.max_y, bounds_b.max_y) - math.max(bounds_a.min_y, bounds_b.min_y)
		local overlap_z = math.min(bounds_a.max_z, bounds_b.max_z) - math.max(bounds_a.min_z, bounds_b.min_z)

		if overlap_x <= 0 or overlap_y <= 0 or overlap_z <= 0 then return end

		local center_delta = body_b:GetPosition() - body_a:GetPosition()
		local normal
		local overlap = overlap_x

		if overlap_y < overlap then
			overlap = overlap_y
			normal = Vec3(0, center_delta.y >= 0 and 1 or -1, 0)
		end

		if overlap_z < overlap then
			overlap = overlap_z
			normal = Vec3(0, 0, center_delta.z >= 0 and 1 or -1)
		end

		if not normal then normal = Vec3(center_delta.x >= 0 and 1 or -1, 0, 0) end

		return resolve_pair_penetration(body_a, body_b, normal, overlap, dt)
	end

	return {
		SolveAABBPairCollision = solve_aabb_pair_collision,
	}
end

return module