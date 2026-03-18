local physics = import("goluwa/physics.lua")
local world_contact_cache = import("goluwa/physics/world_contact/cache.lua")
local world_contact_state = {}
local WORLD_CONTACT_TANGENT_LIMIT = 0.08
local WORLD_CONTACT_NORMAL_DOT = 0.9
local CONTACT_KIND_POLICIES = {
	manifold = {
		kind = "manifold",
		persistent_feature_cache = true,
		retain_steps = 2,
		normal_dot = WORLD_CONTACT_NORMAL_DOT,
		depth_limit = 0.3,
		tangent_limit = WORLD_CONTACT_TANGENT_LIMIT,
		patch_requires_coherent_contacts = true,
		patch_velocity_y_limit = 0.75,
		patch_angular_speed_limit = 1.5,
		patch_up_y_limit = 0.9,
	},
}

function world_contact_state.GetContactKindPolicy(kind)
	return CONTACT_KIND_POLICIES[kind]
end

local function ensure_contact_state(manifold, kind)
	local state = manifold.state[kind]
	local policy = world_contact_state.GetContactKindPolicy(kind)

	if not state then
		state = {policy = policy}
		manifold.state[kind] = state
	end

	state.policy = state.policy or policy
	state.cache = manifold[kind]
	state.entries = state.entries or {}
	state.step_stamp = state.step_stamp or 0
end

function world_contact_state.GetWorldContactManifold(body)
	local manifold = body.WorldContactManifold

	if not manifold then
		manifold = {state = {}}
		body.WorldContactManifold = manifold
	end

	manifold.state = manifold.state or {}

	for kind, _ in pairs(CONTACT_KIND_POLICIES) do
		manifold[kind] = manifold[kind] or {}
		ensure_contact_state(manifold, kind)
	end

	return manifold
end

function world_contact_state.GetContactCache(body, kind)
	local manifold = world_contact_state.GetWorldContactManifold(body)
	manifold[kind] = manifold[kind] or {}
	ensure_contact_state(manifold, kind)
	return manifold[kind]
end

function world_contact_state.GetContactState(body, kind)
	local manifold = world_contact_state.GetWorldContactManifold(body)
	manifold[kind] = manifold[kind] or {}
	ensure_contact_state(manifold, kind)
	return manifold.state[kind]
end

local function cache_contact_set(state, contacts)
	state.entries = state.entries or {}
	state.step_stamp = (state.step_stamp or 0) + 1
	local entries = state.entries
	local cache = state.cache or {}
	local step_stamp = state.step_stamp
	local policy = state.policy or {}
	local has_fresh_contacts = false

	for _, contact in ipairs(contacts) do
		if not contact.cached_reuse then
			has_fresh_contacts = true

			break
		end
	end

	for _, contact in ipairs(contacts) do
		if contact.cached_reuse and not has_fresh_contacts then goto continue end

		local key = world_contact_cache.LocalPointKey(contact.local_point)
		local feature_key = contact.feature_key or
			world_contact_cache.WorldFeatureKey(contact.hit, contact.position, contact.normal)
		local primary_key = world_contact_cache.GetPrimaryContactCacheKey(policy, key, feature_key)

		if primary_key then
			local entry = entries[primary_key] or
				(
					feature_key and
					cache[feature_key]
				)
				or
				(
					key and
					cache[key]
				)
				or
				{}

			if entry.cache_key and entry.cache_key ~= primary_key then
				entries[entry.cache_key] = nil
			end

			entry.cache_key = primary_key
			world_contact_cache.UpdateCachedContactEntry(entry, contact, key, feature_key, step_stamp)
			entries[primary_key] = entry
		end

		::continue::
	end

	world_contact_cache.PruneContactEntries(state)
	world_contact_cache.RebuildContactCacheAliases(state)
end

function world_contact_state.CacheContacts(body, kind, contacts)
	cache_contact_set(world_contact_state.GetContactState(body, kind), contacts)
end

function world_contact_state.AgeContactCache(body, kind)
	local state = world_contact_state.GetContactState(body, kind)
	state.step_stamp = (state.step_stamp or 0) + 1
	world_contact_cache.PruneContactEntries(state)
	world_contact_cache.RebuildContactCacheAliases(state)
end

function world_contact_state.GetCachedContactEntryForContact(body, kind, local_point, hit, position, normal)
	local cache = world_contact_state.GetContactCache(body, kind)
	local feature_key = world_contact_cache.WorldFeatureKey(hit, position, normal)

	if feature_key and cache[feature_key] then
		return feature_key, cache[feature_key]
	end

	local cache_key = world_contact_cache.LocalPointKey(local_point)
	local cached = cache_key and cache[cache_key] or nil
	return cache_key, cached
end

function world_contact_state.TryHydrateCachedContact(contact, cached, policy)
	if not (contact and cached) then return false end

	if not world_contact_cache.MatchesCachedHit(cached, contact.hit) then
		return false
	end

	world_contact_cache.HydrateContactFromCache(contact, cached, policy)
	return true
end

function world_contact_state.CollectCachedManifoldContacts(body, kind, contacts, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local finalize_world_contact = options.finalize_world_contact
	local bias_world_contact_depth = options.bias_world_contact_depth
	local get_support_contact_slop = options.get_support_contact_slop
	local state = world_contact_state.GetContactState(body, kind)
	local policy = state.policy
	local velocity = body:GetVelocity()
	local angular_speed = body:GetAngularVelocity():GetLength()
	local up_y = math.abs(body:GetRotation():GetUp().y)
	local allow_cached_reuse = body:GetGrounded()

	if not allow_cached_reuse then
		local has_support_entries = false
		local has_triangle_support_entries = false

		for _, entry in pairs(state.entries or {}) do
			if entry.normal and entry.normal.y >= body:GetMinGroundNormalY() then
				has_support_entries = true

				if entry.triangle_index ~= nil then has_triangle_support_entries = true end
			end
		end

		if not has_support_entries then return end

		local max_speed = has_triangle_support_entries and 0.75 or 1.2
		local max_vertical_speed = has_triangle_support_entries and 0.45 or 0.8
		local max_angular_speed = has_triangle_support_entries and 1.0 or 2.5
		local min_up_y = has_triangle_support_entries and 0.72 or 0.65

		if
			velocity:GetLength() > max_speed or
			math.abs(velocity.y) > max_vertical_speed or
			angular_speed > max_angular_speed or
			up_y < min_up_y
		then
			return
		end

		allow_cached_reuse = true
	end

	for _, entry in pairs(state.entries or {}) do
		if entry.local_point_key and entry.position and entry.normal and entry.hit then
			local local_point = world_contact_cache.ParseLocalPointKey(entry.local_point_key)

			if local_point then
				local normal = entry.normal:GetLength() > epsilon and entry.normal:GetNormalized() or nil

				if normal then
					local point = body:LocalToWorld(local_point)
					local target = entry.position + normal * body:GetCollisionMargin()
					local raw_depth = (target - point):Dot(normal)
					local depth = bias_world_contact_depth(raw_depth, get_support_contact_slop(body, normal, entry.hit))

					if depth and depth > epsilon and depth <= policy.depth_limit then
						finalize_world_contact(
							body,
							kind,
							policy,
							contacts,
							{
								point = point,
								position = entry.position:Copy(),
								hit = entry.hit,
								normal = normal,
								depth = depth,
								feature_key = entry.feature_key,
								cached_reuse = true,
							},
							local_point
						)
					end
				end
			end
		end
	end
end

function world_contact_state.GetCachedSupportGroundNormal(body, kind, epsilon)
	epsilon = epsilon or physics.EPSILON
	local state = world_contact_state.GetContactState(body, kind)
	local velocity = body:GetVelocity()
	local angular_speed = body:GetAngularVelocity():GetLength()
	local up_y = math.abs(body:GetRotation():GetUp().y)
	local min_ground_y = body:GetMinGroundNormalY()
	local has_triangle_support_entries = false
	local grounded_normal = nil
	local grounded_weight = 0

	for _, entry in pairs(state.entries or {}) do
		if entry.normal and entry.normal.y >= min_ground_y then
			grounded_normal = (grounded_normal or physics.Up * 0) + entry.normal
			grounded_weight = grounded_weight + 1

			if entry.triangle_index ~= nil then has_triangle_support_entries = true end
		end
	end

	if grounded_weight <= epsilon then return nil end

	local max_speed = has_triangle_support_entries and 0.75 or 1.2
	local max_vertical_speed = has_triangle_support_entries and 0.45 or 0.8
	local max_angular_speed = has_triangle_support_entries and 1.0 or 2.5
	local min_up_y = has_triangle_support_entries and 0.72 or 0.65

	if
		velocity:GetLength() > max_speed or
		math.abs(velocity.y) > max_vertical_speed or
		angular_speed > max_angular_speed or
		up_y < min_up_y
	then
		return nil
	end

	return (grounded_normal / grounded_weight):GetNormalized()
end

return world_contact_state
