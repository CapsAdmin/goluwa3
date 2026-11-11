local AABB = import("goluwa/structs/aabb.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local trace_break = import("goluwa/jit/tracebreak.lua")
local sweep_candidates = {}

local function should_skip_rigid_body(body, ignore_entity, filter_fn, options)
	if not body then return true end

	if not body:IsValid() then return true end

	if not body.CollisionEnabled then return true end

	local owner = body.Owner

	if
		not owner or
		owner == ignore_entity or
		(
			ignore_entity and
			body.TraceOwner == ignore_entity
		)
	then
		return true
	end

	if
		(
			options and
			options.IgnoreKinematicBodies ~= false
		)
		and
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

local CANDIDATE_AABB_CURRENT = AABB(0, 0, 0, 0, 0, 0)
local CANDIDATE_AABB_PREVIOUS = AABB(0, 0, 0, 0, 0, 0)
local get_body_bounds

do
	local math_abs = math.abs

	local function is_hull_body(body)
		if body.candidate_hull_version == body.ColliderVersion then
			return body.candidate_hull
		end

		local hull = body:IsDynamic()

		for _, collider in ipairs(body:GetColliders()) do
			if collider:GetShapeType() ~= "convex" then hull = false end
		end

		body.candidate_hull = hull
		body.candidate_hull_version = body.ColliderVersion
		return hull
	end

	-- a moving body is queried at a new pose many times per step; the rotated box of its local hull points bounds it without transforming every hull vertex
	function get_body_bounds(body, position, rotation, out)
		if not is_hull_body(body) then
			return body:GetBroadphaseAABB(position, rotation, out)
		end

		body:GetHalfExtents()
		local local_bounds = body.LocalBounds
		local min, max = local_bounds.min, local_bounds.max
		local cx, cy, cz = (min.x + max.x) * 0.5, (min.y + max.y) * 0.5, (min.z + max.z) * 0.5
		local hx, hy, hz = (max.x - min.x) * 0.5, (max.y - min.y) * 0.5, (max.z - min.z) * 0.5
		local x, y, z, w = rotation.x, rotation.y, rotation.z, rotation.w
		local xx, yy, zz = x * x, y * y, z * z
		local xy, xz, yz = x * y, x * z, y * z
		local wx, wy, wz = w * x, w * y, w * z
		local m00, m01, m02 = 1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)
		local m10, m11, m12 = 2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)
		local m20, m21, m22 = 2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)
		local wcx = position.x + m00 * cx + m01 * cy + m02 * cz
		local wcy = position.y + m10 * cx + m11 * cy + m12 * cz
		local wcz = position.z + m20 * cx + m21 * cy + m22 * cz
		local ex = math_abs(m00) * hx + math_abs(m01) * hy + math_abs(m02) * hz
		local ey = math_abs(m10) * hx + math_abs(m11) * hy + math_abs(m12) * hz
		local ez = math_abs(m20) * hx + math_abs(m21) * hy + math_abs(m22) * hz
		out.min_x, out.min_y, out.min_z = wcx - ex, wcy - ey, wcz - ez
		out.max_x, out.max_y, out.max_z = wcx + ex, wcy + ey, wcz + ez
		return out
	end
end

local function get_rigid_body_candidate_aabb(body)
	local current_position = body:GetPosition()
	local current_rotation = body:GetRotation()
	local previous_position = body:GetPreviousPosition()
	local previous_rotation = body:GetPreviousRotation()
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

	local bounds = get_body_bounds(body, current_position, current_rotation, CANDIDATE_AABB_CURRENT)

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

	local previous_bounds = get_body_bounds(body, previous_position, previous_rotation, CANDIDATE_AABB_PREVIOUS)
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
	local current_position = collider:GetPosition()
	local current_rotation = collider:GetRotation()
	local previous_position = collider:GetPreviousPosition()
	local previous_rotation = collider:GetPreviousRotation()
	local has_previous = current_position and
		current_rotation and
		previous_position and
		previous_rotation and
		true or
		false
	-- a collider reads missing fields through to its body, which would share the body's cache
	local cache = rawget(collider, "sweep_candidate_aabb_cache")

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

	local bounds = collider:GetBroadphaseAABB(current_position, current_rotation, CANDIDATE_AABB_CURRENT)

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

	local previous_bounds = collider:GetBroadphaseAABB(previous_position, previous_rotation, CANDIDATE_AABB_PREVIOUS)
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

local candidate_query = {}

local function append_rigid_body_candidate(entry)
	local body = entry.body
	local query = candidate_query
	local include_body = (
			query.effective_options.IgnoreRigidBodies == false
		)
		or
		should_query_body_as_world(body, query.effective_options)

	if
		include_body and
		not should_skip_rigid_body(body, query.ignore_entity, query.filter_fn, query.options)
	then
		local bounds = entry.bounds
		local position = body.Position

		if entry.px ~= position.x or entry.py ~= position.y or entry.pz ~= position.z then
			bounds = get_rigid_body_candidate_aabb(body) or bounds
		end

		if bounds and AABB.IsBoxIntersecting(query.world_aabb, bounds) then
			query.out[#query.out + 1] = body
		end
	end
end

local function collect_rigid_body_candidates(physics, world_aabb, ignore_entity, filter_fn, options, out)
	trace_break()
	out = out or {}
	local effective_options = options or EMPTY_OPTIONS
	local broadphase = physics.broadphase

	if effective_options.IgnoreRigidBodies ~= false then
		if effective_options.IgnoreWorld == true then return out end

		local world_bodies = RigidBody.WorldGeometryBodies

		for i = 1, #world_bodies do
			local body = world_bodies[i]

			if not should_skip_rigid_body(body, ignore_entity, filter_fn, options) then
				local bounds = get_rigid_body_candidate_aabb(body)

				if bounds and AABB.IsBoxIntersecting(world_aabb, bounds) then
					out[#out + 1] = body
				end
			end
		end

		return out
	end

	if broadphase then
		local entries = broadphase:QueryAABB(world_aabb, query_entry_cache)
		local query = candidate_query
		query.world_aabb, query.ignore_entity, query.filter_fn, query.options, query.effective_options, query.out = world_aabb, ignore_entity, filter_fn, options, effective_options, out

		for i = 1, #entries do
			append_rigid_body_candidate(entries[i])
		end

		local overflow_entries = broadphase.OverflowEntries

		for i = 1, #overflow_entries do
			append_rigid_body_candidate(overflow_entries[i])
		end

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

sweep_candidates.ShouldSkipRigidBody = should_skip_rigid_body
sweep_candidates.ShouldQueryBodyAsWorld = should_query_body_as_world
sweep_candidates.GetRigidBodyCandidateAABB = get_rigid_body_candidate_aabb
sweep_candidates.GetColliderCandidateAABB = get_collider_candidate_aabb
sweep_candidates.CollectRigidBodyCandidates = collect_rigid_body_candidates
return sweep_candidates
