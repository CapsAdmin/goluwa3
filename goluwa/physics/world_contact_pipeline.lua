local world_contact_cache = import("goluwa/physics/world_contact_cache.lua")
local world_contact_collectors = import("goluwa/physics/world_contact_collectors.lua")
local world_contact_scene = import("goluwa/physics/world_contact_scene.lua")
local world_contact_resolution = import("goluwa/physics/world_contact_resolution.lua")
local world_contact_pipeline = {}

local function merge_world_contact(contacts, contact, options)
	local local_point_key = options.local_point_key
	local merge_distance = options.world_manifold_merge_distance

	for i = 1, #contacts do
		local existing = contacts[i]

		if
			existing.local_point and
			contact.local_point and
			local_point_key(existing.local_point) == local_point_key(contact.local_point)
		then
			if existing.cached_reuse and not contact.cached_reuse then
				contacts[i] = contact
			elseif not (contact.cached_reuse and not existing.cached_reuse) then
				if (contact.depth or 0) > (existing.depth or 0) then contacts[i] = contact end
			end

			return
		end

		if
			existing.position and
			contact.position and
			(existing.position - contact.position):GetLength() <= merge_distance and
			existing.normal and
			contact.normal and
			existing.normal:Dot(contact.normal) >= 0.95
		then
			if existing.cached_reuse and not contact.cached_reuse then
				contacts[i] = contact
			elseif not (contact.cached_reuse and not existing.cached_reuse) then
				if (contact.depth or 0) > (existing.depth or 0) then contacts[i] = contact end
			end

			return
		end
	end

	contacts[#contacts + 1] = contact
end

function world_contact_pipeline.CreateFinalizeWorldContact(options)
	local epsilon = options.epsilon
	local world_feature_key = options.world_feature_key or world_contact_cache.WorldFeatureKey
	local get_cached_contact_entry_for_contact = options.get_cached_contact_entry_for_contact
	local try_hydrate_cached_contact = options.try_hydrate_cached_contact

	return function(body, kind, policy, contacts, contact, local_point)
		if
			not (
				contact and
				contact.normal and
				contact.position and
				contact.depth and
				contact.depth > epsilon
			)
		then
			return
		end

		contact.local_point = local_point
		contact.feature_key = contact.feature_key or
			world_feature_key(contact.hit, contact.position, contact.normal)
		local _, cached = get_cached_contact_entry_for_contact(
			body,
			kind,
			local_point,
			contact.hit,
			contact.position,
			contact.normal
		)

		if cached then try_hydrate_cached_contact(contact, cached, policy) end

		merge_world_contact(contacts, contact, options)
	end
	end

function world_contact_pipeline.CollectWorldManifoldContacts(body, kind, contacts, options)
	local policy = options.get_contact_kind_policy(kind)
	world_contact_scene.ForEachWorldPrimitiveCandidate(
		body,
		world_contact_collectors.CollectWorldPrimitiveContactsCallback,
		body,
		contacts,
		policy,
		options
	)
	table.sort(contacts, function(a, b)
		return (a.depth or 0) > (b.depth or 0)
	end)

	for i = (options.world_manifold_max_contacts or #contacts) + 1, #contacts do
		contacts[i] = nil
	end

	return contacts
end

function world_contact_pipeline.ShouldUseWorldManifoldPatch(body, contacts, normal_dot)
	if not world_contact_resolution.ContactsFormCoherentPatch(contacts, normal_dot) then return false end

	local velocity = body:GetVelocity()
	local angular_speed = body:GetAngularVelocity():GetLength()
	local up_y = math.abs(body:GetRotation():GetUp().y)
	return math.abs(velocity.y) <= 0.75 and angular_speed <= 1.5 and up_y >= 0.85
end

return world_contact_pipeline