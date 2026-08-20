local AABB = import("goluwa/structs/aabb.lua")
local model_transform_utils = import("goluwa/physics/model_transform_utils.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local physics_singleton = import("goluwa/physics.lua")
local sweep_candidates = {}
local get_model_primitives = model_transform_utils.GetModelPrimitives

local function passes_entity_filter(entity, ignore_entity, filter_fn, options)
	if not entity or entity == ignore_entity then return false end

	if entity.PhysicsNoCollision or entity.NoPhysicsCollision then return false end

	if (options and options.IgnoreRigidBodies ~= false) and entity.rigid_body then
		return false
	end

	if
		(
			options and
			options.IgnoreKinematicBodies ~= false
		)
		and
		entity.rigid_body and
		entity.rigid_body.IsKinematic and
		entity.rigid_body:IsKinematic()
	then
		return false
	end

	if filter_fn and not filter_fn(entity) then return false end

	return true
end

local function should_skip_model(model, ignore_entity, filter_fn, options)
	local primitives = get_model_primitives(model)

	if not (model and model.Visible and primitives and primitives[1]) then
		return true
	end

	return not passes_entity_filter(model.Owner, ignore_entity, filter_fn, options)
end

local function should_skip_rigid_body(body, ignore_entity, filter_fn, options)
	if not body then return true end

	if not body:IsValid() then return true end

	if not body.CollisionEnabled then return true end

	local owner = body.Owner

	if not owner or owner == ignore_entity then return true end

	if
		(
			options and
			options.IgnoreKinematicBodies ~= false
		)
		and
		body.IsKinematic and
		body:IsKinematic()
	then
		return true
	end

	if filter_fn and not filter_fn(owner) then return true end

	return false
end

local function should_query_body_as_world(body, options)
	return options and options.IgnoreWorld ~= true and body and body.WorldGeometry == true
end

local function get_cached_candidate_aabb(cache, bounds, previous_bounds)
	local cached_bounds = cache.bounds

	if not cached_bounds then
		cached_bounds = AABB(
			bounds.min_x,
			bounds.min_y,
			bounds.min_z,
			bounds.max_x,
			bounds.max_y,
			bounds.max_z
		)
		cache.bounds = cached_bounds
	else
		cached_bounds.min_x = bounds.min_x
		cached_bounds.min_y = bounds.min_y
		cached_bounds.min_z = bounds.min_z
		cached_bounds.max_x = bounds.max_x
		cached_bounds.max_y = bounds.max_y
		cached_bounds.max_z = bounds.max_z
	end

	if previous_bounds then cached_bounds:Expand(previous_bounds) end

	return cached_bounds
end

local function matches_candidate_pose(
	cache,
	current_position,
	current_rotation,
	previous_position,
	previous_rotation,
	has_previous
)
	return cache and
		cache.has_previous == has_previous and
		cache.current_px == (
			current_position and
			current_position.x or
			nil
		)
		and
		cache.current_py == (
			current_position and
			current_position.y or
			nil
		)
		and
		cache.current_pz == (
			current_position and
			current_position.z or
			nil
		)
		and
		cache.current_rx == (
			current_rotation and
			current_rotation.x or
			nil
		)
		and
		cache.current_ry == (
			current_rotation and
			current_rotation.y or
			nil
		)
		and
		cache.current_rz == (
			current_rotation and
			current_rotation.z or
			nil
		)
		and
		cache.current_rw == (
			current_rotation and
			current_rotation.w or
			nil
		)
		and
		cache.previous_px == (
			previous_position and
			previous_position.x or
			nil
		)
		and
		cache.previous_py == (
			previous_position and
			previous_position.y or
			nil
		)
		and
		cache.previous_pz == (
			previous_position and
			previous_position.z or
			nil
		)
		and
		cache.previous_rx == (
			previous_rotation and
			previous_rotation.x or
			nil
		)
		and
		cache.previous_ry == (
			previous_rotation and
			previous_rotation.y or
			nil
		)
		and
		cache.previous_rz == (
			previous_rotation and
			previous_rotation.z or
			nil
		)
		and
		cache.previous_rw == (
			previous_rotation and
			previous_rotation.w or
			nil
		)
end

local function store_candidate_pose(
	cache,
	current_position,
	current_rotation,
	previous_position,
	previous_rotation,
	has_previous
)
	cache.has_previous = has_previous
	cache.current_px = current_position and current_position.x or nil
	cache.current_py = current_position and current_position.y or nil
	cache.current_pz = current_position and current_position.z or nil
	cache.current_rx = current_rotation and current_rotation.x or nil
	cache.current_ry = current_rotation and current_rotation.y or nil
	cache.current_rz = current_rotation and current_rotation.z or nil
	cache.current_rw = current_rotation and current_rotation.w or nil
	cache.previous_px = previous_position and previous_position.x or nil
	cache.previous_py = previous_position and previous_position.y or nil
	cache.previous_pz = previous_position and previous_position.z or nil
	cache.previous_rx = previous_rotation and previous_rotation.x or nil
	cache.previous_ry = previous_rotation and previous_rotation.y or nil
	cache.previous_rz = previous_rotation and previous_rotation.z or nil
	cache.previous_rw = previous_rotation and previous_rotation.w or nil
end

local function get_rigid_body_candidate_aabb(body)
	if not body.GetBroadphaseAABB then return nil end

	local current_position = body.GetPosition and body:GetPosition() or nil
	local current_rotation = body.GetRotation and body:GetRotation() or nil
	local previous_position = body.GetPreviousPosition and body:GetPreviousPosition() or nil
	local previous_rotation = body.GetPreviousRotation and body:GetPreviousRotation() or nil
	local has_previous = current_position and
		current_rotation and
		previous_position and
		previous_rotation and
		true or
		false
	local cache = body.sweep_candidate_aabb_cache

	if
		matches_candidate_pose(
			cache,
			current_position,
			current_rotation,
			previous_position,
			previous_rotation,
			has_previous
		)
	then
		return cache.bounds
	end

	local bounds = body:GetBroadphaseAABB(current_position, current_rotation)

	if not bounds or not has_previous then
		cache = cache or {}
		body.sweep_candidate_aabb_cache = cache
		store_candidate_pose(
			cache,
			current_position,
			current_rotation,
			previous_position,
			previous_rotation,
			false
		)
		return get_cached_candidate_aabb(cache, bounds)
	end

	if previous_position == current_position and previous_rotation == current_rotation then
		cache = cache or {}
		body.sweep_candidate_aabb_cache = cache
		store_candidate_pose(
			cache,
			current_position,
			current_rotation,
			previous_position,
			previous_rotation,
			true
		)
		return get_cached_candidate_aabb(cache, bounds)
	end

	local previous_bounds = body:GetBroadphaseAABB(previous_position, previous_rotation)
	cache = cache or {}
	body.sweep_candidate_aabb_cache = cache
	store_candidate_pose(
		cache,
		current_position,
		current_rotation,
		previous_position,
		previous_rotation,
		true
	)

	if not previous_bounds then return get_cached_candidate_aabb(cache, bounds) end

	return get_cached_candidate_aabb(cache, bounds, previous_bounds)
end

local function get_collider_candidate_aabb(collider)
	if not collider.GetBroadphaseAABB then return nil end

	local current_position = collider.GetPosition and collider:GetPosition() or nil
	local current_rotation = collider.GetRotation and collider:GetRotation() or nil
	local previous_position = collider.GetPreviousPosition and collider:GetPreviousPosition() or nil
	local previous_rotation = collider.GetPreviousRotation and collider:GetPreviousRotation() or nil
	local has_previous = current_position and
		current_rotation and
		previous_position and
		previous_rotation and
		true or
		false
	local cache = collider.sweep_candidate_aabb_cache

	if
		matches_candidate_pose(
			cache,
			current_position,
			current_rotation,
			previous_position,
			previous_rotation,
			has_previous
		)
	then
		return cache.bounds
	end

	local bounds = collider:GetBroadphaseAABB(current_position, current_rotation)

	if not bounds or not has_previous then
		cache = cache or {}
		collider.sweep_candidate_aabb_cache = cache
		store_candidate_pose(
			cache,
			current_position,
			current_rotation,
			previous_position,
			previous_rotation,
			false
		)
		return get_cached_candidate_aabb(cache, bounds)
	end

	if previous_position == current_position and previous_rotation == current_rotation then
		cache = cache or {}
		collider.sweep_candidate_aabb_cache = cache
		store_candidate_pose(
			cache,
			current_position,
			current_rotation,
			previous_position,
			previous_rotation,
			true
		)
		return get_cached_candidate_aabb(cache, bounds)
	end

	local previous_bounds = collider:GetBroadphaseAABB(previous_position, previous_rotation)
	cache = cache or {}
	collider.sweep_candidate_aabb_cache = cache
	store_candidate_pose(
		cache,
		current_position,
		current_rotation,
		previous_position,
		previous_rotation,
		true
	)

	if not previous_bounds then return get_cached_candidate_aabb(cache, bounds) end

	return get_cached_candidate_aabb(cache, bounds, previous_bounds)
end

local EMPTY_OPTIONS = {}
local query_entry_cache = {}
local untracked_cache = {stamp = nil, instance_count = nil, body_entries = nil, bodies = {}}

-- the set of bodies the broadphase has never tracked only changes when a
-- physics substep re-tracks bodies, the body entries table is replaced (e.g.
-- a physics ResetState), or the instance list changes, so cache it
local function get_untracked_bodies(broadphase)
	local cache = untracked_cache
	local instances = RigidBody.Instances

	if
		cache.stamp == broadphase.StepStamp and
		cache.instance_count == #instances and
		cache.body_entries == broadphase.BodyEntries
	then
		return cache.bodies
	end

	local bodies = cache.bodies

	for i = #bodies, 1, -1 do
		bodies[i] = nil
	end

	local body_entries = broadphase.BodyEntries

	for i = 1, #instances do
		local body = instances[i]

		if not body_entries[body] then bodies[#bodies + 1] = body end
	end

	cache.stamp = broadphase.StepStamp
	cache.instance_count = #instances
	cache.body_entries = broadphase.BodyEntries
	return bodies
end

local function append_rigid_body_candidate(
	entry,
	world_aabb,
	ignore_entity,
	filter_fn,
	options,
	effective_options,
	out
)
	local body = entry.body
	local include_body = (
			effective_options.IgnoreRigidBodies == false
		)
		or
		should_query_body_as_world(body, effective_options)

	if
		include_body and
		not should_skip_rigid_body(body, ignore_entity, filter_fn, options)
	then
		local bounds = entry.bounds

		if entry.center ~= body:GetPosition() then
			-- body moved since the broadphase last tracked it (e.g. transform
			-- changes between physics steps), fall back to the pose-cached bounds
			bounds = get_rigid_body_candidate_aabb(body) or bounds
		end

		if bounds and AABB.IsBoxIntersecting(world_aabb, bounds) then
			out[#out + 1] = body
		end
	end
end

local function collect_rigid_body_candidates(world_aabb, ignore_entity, filter_fn, options, out)
	out = out or {}
	local effective_options = options or EMPTY_OPTIONS
	local broadphase = physics_singleton.broadphase

	if broadphase then
		local entries = broadphase:QueryAABB(world_aabb, query_entry_cache)

		for i = 1, #entries do
			append_rigid_body_candidate(entries[i], world_aabb, ignore_entity, filter_fn, options, effective_options, out)
		end

		local overflow_entries = broadphase.OverflowEntries

		for i = 1, #overflow_entries do
			append_rigid_body_candidate(overflow_entries[i], world_aabb, ignore_entity, filter_fn, options, effective_options, out)
		end

		-- bodies the broadphase has never tracked (queries run before/between
		-- physics steps) still go through the pose-cached bounds
		local untracked = get_untracked_bodies(broadphase)

		for i = 1, #untracked do
			local body = untracked[i]
			local include_body = (
					effective_options.IgnoreRigidBodies == false
				)
				or
				should_query_body_as_world(body, effective_options)

			if
				include_body and
				not should_skip_rigid_body(body, ignore_entity, filter_fn, options)
			then
				local bounds = get_rigid_body_candidate_aabb(body)

				if bounds and AABB.IsBoxIntersecting(world_aabb, bounds) then
					out[#out + 1] = body
				end
			end
		end

		return out
	end

	local instances = RigidBody.Instances

	for i = 1, #instances do
		local body = instances[i]
		local include_body = (
				options and
				options.IgnoreRigidBodies == false
			)
			or
			should_query_body_as_world(body, effective_options)

		if
			include_body and
			not should_skip_rigid_body(body, ignore_entity, filter_fn, options)
		then
			local bounds = get_rigid_body_candidate_aabb(body)

			if bounds and AABB.IsBoxIntersecting(world_aabb, bounds) then
				out[#out + 1] = body
			end
		end
	end

	return out
end

sweep_candidates.ShouldSkipModel = should_skip_model
sweep_candidates.ShouldSkipRigidBody = should_skip_rigid_body
sweep_candidates.ShouldQueryBodyAsWorld = should_query_body_as_world
sweep_candidates.GetRigidBodyCandidateAABB = get_rigid_body_candidate_aabb
sweep_candidates.GetColliderCandidateAABB = get_collider_candidate_aabb
sweep_candidates.CollectRigidBodyCandidates = collect_rigid_body_candidates

return sweep_candidates
