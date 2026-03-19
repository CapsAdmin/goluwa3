local broadphase = {}
local world_static_query = import("goluwa/physics/world_static_query.lua")
local world_mesh_body = import("goluwa/physics/world_mesh_body.lua")

local function sort(a, b)
	return a.left < b.left
end

function broadphase.BuildEntries(physics, bodies)
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

function broadphase.BuildCandidatePairsFromEntries(entries)
	local pairs = {}

	for i = 1, #entries do
		local a = entries[i]
		local max_right = a.right

		for j = i + 1, #entries do
			local b = entries[j]

			if b.left > max_right then break end

			if a.bounds:IsBoxIntersecting(b.bounds) then
				pairs[#pairs + 1] = {
					entry_a = a,
					entry_b = b,
				}
			end
		end
	end

	return pairs
end

local function append_world_primitive_pairs(physics, pairs, entries)
	local seen = setmetatable({}, {__mode = "k"})

	for i = 1, #entries do
		local entry_a = entries[i]
		local body = entry_a and entry_a.body

		if not (body and body.IsDynamic and body:IsDynamic() and body.GetAwake and body:GetAwake()) then
			goto continue_entry
		end

		world_static_query.ForEachWorldPrimitiveCandidate(
			body,
			function(model, entity, primitive, primitive_index)
				local proxy_body = world_mesh_body.GetPrimitiveBody(model, entity, primitive, primitive_index)

				if not (proxy_body and physics.ShouldBodiesCollide(body, proxy_body)) then return end
				local body_seen = seen[body]

				if not body_seen then
					body_seen = setmetatable({}, {__mode = "k"})
					seen[body] = body_seen
				elseif body_seen[proxy_body] then
					return
				end

				body_seen[proxy_body] = true
				local proxy_bounds = proxy_body:GetBroadphaseAABB()
				pairs[#pairs + 1] = {
					entry_a = entry_a,
					entry_b = {
						body = proxy_body,
						bounds = proxy_bounds,
						center = proxy_body:GetPosition(),
						left = proxy_bounds.min_x,
						right = proxy_bounds.max_x,
					},
				}
			end,
			nil,
			nil,
			nil,
			nil,
			world_static_query.BuildExpandedBodyWorldContactAABB(body)
		)

		::continue_entry::
	end

	return pairs
end

function broadphase.BuildCandidatePairs(physics, bodies)
	local entries = broadphase.BuildEntries(physics, bodies)
	local pairs = broadphase.BuildCandidatePairsFromEntries(entries)
	append_world_primitive_pairs(physics, pairs, entries)
	return pairs
end

return broadphase
