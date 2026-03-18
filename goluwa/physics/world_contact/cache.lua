local Vec3 = import("goluwa/structs/vec3.lua")
local world_contact_cache = {}

local function quantize_world_feature_value(value, epsilon)
	local scaled = value / epsilon
	return scaled >= 0 and math.floor(scaled + 0.5) or math.ceil(scaled - 0.5)
end

function world_contact_cache.LocalPointKey(local_point)
	if not local_point then return nil end

	return string.format("%.5f|%.5f|%.5f", local_point.x, local_point.y, local_point.z)
end

function world_contact_cache.QuantizedVec3Key(vec, epsilon)
	if not vec then return nil end

	epsilon = epsilon or 0.05
	return quantize_world_feature_value(vec.x, epsilon) .. "|" .. quantize_world_feature_value(vec.y, epsilon) .. "|" .. quantize_world_feature_value(vec.z, epsilon)
end

function world_contact_cache.WorldFeatureKey(hit, position, normal)
	if not hit then return nil end

	local entity_key = hit.entity and tostring(hit.entity) or "world"
	local primitive_index = hit.primitive_index ~= nil and tostring(hit.primitive_index) or "?"
	local triangle_index = hit.triangle_index ~= nil and tostring(hit.triangle_index) or "-"
	local position_key = world_contact_cache.QuantizedVec3Key(position, 0.04) or "pos"
	local normal_key = world_contact_cache.QuantizedVec3Key(normal, 0.08) or "n"
	return entity_key .. "|" .. primitive_index .. "|" .. triangle_index .. "|" .. position_key .. "|" .. normal_key
end

function world_contact_cache.TriangleLocalFeatureKey(hit, local_point, normal)
	if not (hit and hit.triangle_index ~= nil and local_point) then return nil end

	local entity_key = hit.entity and tostring(hit.entity) or "world"
	local primitive_index = hit.primitive_index ~= nil and tostring(hit.primitive_index) or "?"
	local triangle_index = tostring(hit.triangle_index)
	local local_key = world_contact_cache.QuantizedVec3Key(local_point, 0.04) or "lp"
	local normal_key = world_contact_cache.QuantizedVec3Key(normal, 0.08) or "n"
	return entity_key .. "|" .. primitive_index .. "|" .. triangle_index .. "|local|" .. local_key .. "|" .. normal_key
end

function world_contact_cache.MatchesCachedHit(cached, hit)
	if not (cached and hit) then return false end

	if cached.entity ~= hit.entity then return false end

	if cached.primitive ~= hit.primitive then return false end

	if cached.primitive_index ~= hit.primitive_index then return false end

	if cached.triangle_index ~= nil or hit.triangle_index ~= nil then
		return cached.triangle_index == hit.triangle_index
	end

	return true
end

function world_contact_cache.GetCachedTangent(contact, normal, epsilon)
	epsilon = epsilon or 0.00001
	local tangent = contact and contact.tangent or nil

	if not tangent then return nil end

	tangent = tangent - normal * tangent:Dot(normal)

	if tangent:GetLength() <= epsilon then return nil end

	return tangent:GetNormalized()
end

function world_contact_cache.HydrateContactFromCache(contact, cached, policy)
	if not (contact and cached and cached.normal and contact.normal) then return end

	if contact.normal:Dot(cached.normal) < policy.normal_dot then return end

	contact.tangent_impulse = cached.tangent_impulse or 0
	contact.tangent = cached.tangent and cached.tangent:Copy() or nil
	contact.cached = true
end

function world_contact_cache.GetPrimaryContactCacheKey(policy, local_key, feature_key)
	if policy and policy.persistent_feature_cache and feature_key then
		return feature_key
	end

	return local_key or feature_key
end

function world_contact_cache.PruneContactEntries(state)
	local entries = state and state.entries or nil

	if not entries then return end

	local retain_steps = state.policy and state.policy.retain_steps or 0
	local min_step = (state.step_stamp or 0) - retain_steps

	for key, entry in pairs(entries) do
		if not entry.last_seen_step or entry.last_seen_step < min_step then
			entries[key] = nil
		end
	end
end

function world_contact_cache.RebuildContactCacheAliases(state)
	local cache = state and state.cache or nil

	if not cache then return end

	for key in pairs(cache) do
		cache[key] = nil
	end

	for _, entry in pairs(state.entries or {}) do
		if entry.local_point_key then cache[entry.local_point_key] = entry end

		if entry.feature_key then cache[entry.feature_key] = entry end
	end
end

function world_contact_cache.UpdateCachedContactEntry(entry, contact, local_key, feature_key, step_stamp)
	entry.position = contact.position and contact.position:Copy() or contact.point:Copy()
	entry.normal = contact.normal:Copy()
	entry.tangent = contact.tangent and contact.tangent:Copy() or nil
	entry.tangent_impulse = contact.tangent_impulse or 0
	entry.hit = contact.hit
	entry.entity = contact.hit and contact.hit.entity or nil
	entry.primitive = contact.hit and contact.hit.primitive or nil
	entry.primitive_index = contact.hit and contact.hit.primitive_index or nil
	entry.triangle_index = contact.hit and contact.hit.triangle_index or nil
	entry.feature_key = feature_key
	entry.local_point_key = local_key
	entry.last_seen_step = step_stamp
end

function world_contact_cache.ParseLocalPointKey(key)
	if not key then return nil end

	local x, y, z = key:match("^([^|]+)|([^|]+)|([^|]+)$")

	if not (x and y and z) then return nil end

	x = tonumber(x)
	y = tonumber(y)
	z = tonumber(z)

	if not (x and y and z) then return nil end

	return Vec3(x, y, z)
end

return world_contact_cache
