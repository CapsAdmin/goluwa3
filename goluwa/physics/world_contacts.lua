local world_contact_cache = import("goluwa/physics/world_contact_cache.lua")
local world_contact_pipeline = import("goluwa/physics/world_contact_pipeline.lua")
local world_contact_resolution = import("goluwa/physics/world_contact_resolution.lua")
local world_contact_state = import("goluwa/physics/world_contact_state.lua")
local world_contact_sampling = import("goluwa/physics/world_contact_sampling.lua")
local world_contacts = {}
local EPSILON = 0.00001
local BRUSH_FEATURE_EPSILON = 0.05
local WORLD_CONTACT_BRUSH_SLOP = 0.03
local WORLD_CONTACT_TRIANGLE_SLOP = 0.05
local WORLD_CONTACT_NORMAL_DOT = 0.9
local WORLD_MANIFOLD_MAX_CONTACTS = 8
local WORLD_MANIFOLD_MERGE_DISTANCE = 0.08

local function bias_world_contact_depth(depth, slop)
	slop = slop or 0

	if depth <= -slop then return nil end

	return depth + slop
end

local function get_support_contact_slop(body, normal, hit)
	if
		not (
			body and
			normal and
			body.GetMinGroundNormalY and
			normal.y >= body:GetMinGroundNormalY()
		)
	then
		return 0
	end

	if hit and hit.triangle_index ~= nil then return WORLD_CONTACT_TRIANGLE_SLOP end

	return WORLD_CONTACT_BRUSH_SLOP
end

local finalize_world_contact = world_contact_pipeline.CreateFinalizeWorldContact({
	epsilon = EPSILON,
	local_point_key = world_contact_cache.LocalPointKey,
	world_manifold_merge_distance = WORLD_MANIFOLD_MERGE_DISTANCE,
	world_feature_key = world_contact_cache.WorldFeatureKey,
	get_cached_contact_entry_for_contact = world_contact_state.GetCachedContactEntryForContact,
	try_hydrate_cached_contact = world_contact_state.TryHydrateCachedContact,
})

local world_manifold_contact_options = {
	kind = "manifold",
	epsilon = EPSILON,
	brush_feature_epsilon = BRUSH_FEATURE_EPSILON,
	world_contact_triangle_slop = WORLD_CONTACT_TRIANGLE_SLOP,
	world_manifold_merge_distance = WORLD_MANIFOLD_MERGE_DISTANCE,
	world_manifold_max_contacts = WORLD_MANIFOLD_MAX_CONTACTS,
	local_point_key = world_contact_cache.LocalPointKey,
	triangle_local_feature_key = world_contact_cache.TriangleLocalFeatureKey,
	finalize_world_contact = finalize_world_contact,
	bias_world_contact_depth = bias_world_contact_depth,
	get_support_contact_slop = get_support_contact_slop,
	get_contact_kind_policy = world_contact_state.GetContactKindPolicy,
}

local function solve_world_manifold_contacts(body, dt)
	if not body.CollisionEnabled then return false end

	local kind = "manifold"
	local contacts = {}
	world_manifold_contact_options.kind = kind
	world_contact_pipeline.CollectWorldManifoldContacts(body, kind, contacts, world_manifold_contact_options)

	if not contacts[1] then
		world_contact_sampling.CollectTraceContacts(
			body,
			kind,
			contacts,
			{
				epsilon = EPSILON,
				get_contact_kind_policy = world_contact_state.GetContactKindPolicy,
				finalize_world_contact = finalize_world_contact,
				local_point_key = world_contact_cache.LocalPointKey,
			}
		)
	end

	if #contacts < 2 then
		world_contact_state.CollectCachedManifoldContacts(
			body,
			kind,
			contacts,
			{
				epsilon = EPSILON,
				finalize_world_contact = finalize_world_contact,
				bias_world_contact_depth = bias_world_contact_depth,
				get_support_contact_slop = get_support_contact_slop,
			}
		)
	end

	if #contacts < 3 and world_contact_pipeline.ShouldUseWorldManifoldPatch(body, contacts, WORLD_CONTACT_NORMAL_DOT) then
		world_contact_state.CollectCachedManifoldContacts(
			body,
			kind,
			contacts,
			{
				epsilon = EPSILON,
				finalize_world_contact = finalize_world_contact,
				bias_world_contact_depth = bias_world_contact_depth,
				get_support_contact_slop = get_support_contact_slop,
			}
		)
	end

	if not contacts[1] then
		local cached_ground_normal = world_contact_state.GetCachedSupportGroundNormal(body, kind, EPSILON)
		world_contact_state.AgeContactCache(body, kind)

		if cached_ground_normal then
			body:SetGrounded(true)
			body:SetGroundNormal(cached_ground_normal)
		end

		return false
	end

	local grounded_normal = nil
	local grounded_weight = 0
	local solved

	if world_contact_pipeline.ShouldUseWorldManifoldPatch(body, contacts, WORLD_CONTACT_NORMAL_DOT) then
		solved, grounded_normal, grounded_weight = world_contact_resolution.ApplyContactPatch(body, contacts, dt, grounded_normal, grounded_weight)
	else
		solved, grounded_normal, grounded_weight = world_contact_resolution.ApplyContactSequence(body, contacts, dt, grounded_normal, grounded_weight)
	end

	world_contact_state.CacheContacts(body, kind, contacts)

	if grounded_normal and grounded_weight > EPSILON then
		body:SetGroundNormal((grounded_normal / grounded_weight):GetNormalized())
	end

	return solved
end

function world_contacts.SolveBodyContacts(body, dt)
	solve_world_manifold_contacts(body, dt)
end

return world_contacts