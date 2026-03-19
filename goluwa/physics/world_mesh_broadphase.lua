local world_static_query = import("goluwa/physics/world_static_query.lua")
local world_mesh_body = import("goluwa/physics/world_mesh_body.lua")
local world_mesh_broadphase = {}

function world_mesh_broadphase.BuildProxyEntry(proxy_body)
	local bounds = proxy_body:GetBroadphaseAABB()
	return {
		body = proxy_body,
		bounds = bounds,
		center = proxy_body:GetPosition(),
		left = bounds.min_x,
		right = bounds.max_x,
	}
end

function world_mesh_broadphase.AppendCandidatePairs(physics, pairs, entries)
	local seen = setmetatable({}, {__mode = "k"})

	for i = 1, #entries do
		local entry_a = entries[i]
		local body = entry_a and entry_a.body

		if not (body and body.IsDynamic and body:IsDynamic() and body.GetAwake and body:GetAwake()) then
			goto continue_entry
		end

		world_mesh_body.ForEachPrimitiveBodyCandidate(
			body,
			function(proxy_body)
				local body_seen = seen[body]

				if not body_seen then
					body_seen = setmetatable({}, {__mode = "k"})
					seen[body] = body_seen
				elseif body_seen[proxy_body] then
					return
				end

				body_seen[proxy_body] = true
				pairs[#pairs + 1] = {
					entry_a = entry_a,
					entry_b = world_mesh_broadphase.BuildProxyEntry(proxy_body),
				}
			end,
			world_static_query.BuildExpandedBodyWorldContactAABB(body)
		)

		::continue_entry::
	end

	return pairs
end

return world_mesh_broadphase
