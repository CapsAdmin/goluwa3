local physics = import("goluwa/physics.lua")
local motion = import("goluwa/physics/motion.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local world_contacts = {}
local EPSILON = 0.00001
local BRUSH_FEATURE_EPSILON = 0.05
local SUPPORT_CACHE_DEPTH_LIMIT = 0.2
local SUPPORT_CACHE_TANGENT_LIMIT = 0.08
local SUPPORT_CACHE_NORMAL_DOT = 0.9
local MOTION_CACHE_DEPTH_LIMIT = 0.12
local MOTION_CACHE_SEPARATION_SPEED = 0.35
local WORLD_TANGENT_WARM_START_SCALE = 0.15
local WORLD_MAX_TANGENT_WARM_SPEED = 0.25
local CONTACT_KIND_POLICIES = {
	support = {
		kind = "support",
		legacy_cache_field = "WorldSupportContactCache",
		cached_surface_mode = "support_position",
		normal_dot = SUPPORT_CACHE_NORMAL_DOT,
		depth_limit = SUPPORT_CACHE_DEPTH_LIMIT,
		tangent_limit = SUPPORT_CACHE_TANGENT_LIMIT,
		patch_requires_coherent_contacts = true,
		patch_velocity_y_limit = 0.75,
		patch_angular_speed_limit = 1.5,
		patch_up_y_limit = 0.9,
	},
	motion = {
		kind = "motion",
		legacy_cache_field = "WorldMotionContactCache",
		cached_surface_mode = "motion_projection",
		normal_dot = SUPPORT_CACHE_NORMAL_DOT,
		depth_limit = MOTION_CACHE_DEPTH_LIMIT,
		separation_speed = MOTION_CACHE_SEPARATION_SPEED,
		patch_requires_coherent_contacts = true,
	},
}

local function sync_body_motion_history(body, dt)
	dt = dt or body.StepDt or (1 / 60)
	body.PreviousPosition = body.Position - body:GetVelocity() * dt
	body.PreviousRotation = motion.IntegrateRotation(body.Rotation, body:GetAngularVelocity(), -dt)
end

local function has_world_trace_source()
	return physics.GetWorldTraceSource and physics.GetWorldTraceSource() ~= nil
end

local function get_contact_kind_policy(kind)
	return CONTACT_KIND_POLICIES[kind]
end

local function get_world_contact_manifold(body)
	local manifold = body.WorldContactManifold

	if not manifold then
		manifold = {state = {}}
		body.WorldContactManifold = manifold
	end

	manifold.state = manifold.state or {}

	for kind, policy in pairs(CONTACT_KIND_POLICIES) do
		manifold[kind] = manifold[kind] or body[policy.legacy_cache_field] or {}
		manifold.state[kind] = manifold.state[kind] or {policy = policy}
		manifold.state[kind].policy = policy
		manifold.state[kind].cache = manifold[kind]
		body[policy.legacy_cache_field] = manifold[kind]
	end

	return manifold
end

local function get_contact_cache(body, kind)
	local manifold = get_world_contact_manifold(body)
	manifold[kind] = manifold[kind] or {}
	manifold.state[kind] = manifold.state[kind] or {policy = get_contact_kind_policy(kind)}
	manifold.state[kind].policy = manifold.state[kind].policy or get_contact_kind_policy(kind)
	manifold.state[kind].cache = manifold[kind]
	return manifold[kind]
end

local function get_contact_state(body, kind)
	local manifold = get_world_contact_manifold(body)
	manifold.state[kind] = manifold.state[kind] or {policy = get_contact_kind_policy(kind)}
	manifold.state[kind].policy = manifold.state[kind].policy or get_contact_kind_policy(kind)
	manifold.state[kind].cache = get_contact_cache(body, kind)
	return manifold.state[kind]
end

local function clear_contact_cache(body, kind)
	local policy = get_contact_kind_policy(kind)
	local manifold = body.WorldContactManifold
	local cache = manifold and manifold[kind] or body[policy.legacy_cache_field]

	if not cache then return end

	for key in pairs(cache) do
		cache[key] = nil
	end
end

local function local_point_key(local_point)
	if not local_point then return nil end

	return string.format("%.5f|%.5f|%.5f", local_point.x, local_point.y, local_point.z)
end

local function matches_cached_hit(cached, hit)
	if not (cached and hit) then return false end

	if cached.entity ~= hit.entity then return false end

	if cached.primitive ~= hit.primitive then return false end

	if cached.primitive_index ~= hit.primitive_index then return false end

	if cached.triangle_index ~= nil or hit.triangle_index ~= nil then
		return cached.triangle_index == hit.triangle_index
	end

	return true
end

local function get_cached_tangent(contact, normal)
	local tangent = contact and contact.tangent or nil

	if not tangent then return nil end

	tangent = tangent - normal * tangent:Dot(normal)

	if tangent:GetLength() <= EPSILON then return nil end

	return tangent:GetNormalized()
end

local function hydrate_contact_from_cache(contact, cached, policy)
	if not (contact and cached and cached.normal and contact.normal) then return end

	if contact.normal:Dot(cached.normal) < policy.normal_dot then return end

	contact.tangent_impulse = cached.tangent_impulse or 0
	contact.tangent = cached.tangent and cached.tangent:Copy() or nil
	contact.cached = true
end

local function cache_contact_set(cache, contacts)
	for key in pairs(cache) do
		cache[key] = nil
	end

	for _, contact in ipairs(contacts) do
		local key = local_point_key(contact.local_point)

		if key then
			cache[key] = {
				position = contact.position and contact.position:Copy() or contact.point:Copy(),
				normal = contact.normal:Copy(),
				tangent = contact.tangent and contact.tangent:Copy() or nil,
				tangent_impulse = contact.tangent_impulse or 0,
				hit = contact.hit,
				entity = contact.hit and contact.hit.entity or nil,
				primitive = contact.hit and contact.hit.primitive or nil,
				primitive_index = contact.hit and contact.hit.primitive_index or nil,
				triangle_index = contact.hit and contact.hit.triangle_index or nil,
			}
		end
	end
end

local function cache_contacts(body, kind, contacts)
	cache_contact_set(get_contact_cache(body, kind), contacts)
end

local function get_cached_contact_entry(body, kind, local_point)
	local cache_key = local_point_key(local_point)
	local cached = cache_key and get_contact_cache(body, kind)[cache_key] or nil
	return cache_key, cached
end

local function try_hydrate_cached_contact(contact, cached, policy)
	if not (contact and cached) then return false end

	if not matches_cached_hit(cached, contact.hit) then return false end

	hydrate_contact_from_cache(contact, cached, policy)
	return true
end

local function get_normalized_cached_contact_normal(cached)
	if not (cached and cached.position and cached.normal) then return nil end

	local normal = cached.normal

	if normal:GetLength() <= EPSILON then return nil end

	return normal:GetNormalized()
end

local function get_support_cached_contact_surface(_, _, cached)
	local normal = get_normalized_cached_contact_normal(cached)

	if not normal then return nil end

	return normal, cached.position:Copy()
end

local function get_motion_cached_contact_surface(body, point, cached, policy)
	local normal = get_normalized_cached_contact_normal(cached)

	if not normal then return nil end

	if cached.hit and cached.hit.entity == body:GetOwner() then return nil end

	local point_velocity = body:GetVelocity() + body:GetAngularVelocity():GetCross(point - body:GetPosition())
	local normal_speed = point_velocity:Dot(normal)

	if normal_speed > policy.separation_speed then return nil end

	local plane_dist = cached.position:Dot(normal)
	local projected = point - normal * (point:Dot(normal) - plane_dist)
	return normal, projected
end

CONTACT_KIND_POLICIES.support.cached_surface_builder = get_support_cached_contact_surface
CONTACT_KIND_POLICIES.motion.cached_surface_builder = get_motion_cached_contact_surface

local function get_cached_contact_surface(body, point, cached, policy)
	if not policy.cached_surface_builder then return nil end

	return policy.cached_surface_builder(body, point, cached, policy)
end

local function build_cached_contact(body, point, local_point, cached, policy)
	local normal, contact_position = get_cached_contact_surface(body, point, cached, policy)

	if not (normal and contact_position) then return nil end

	local target = contact_position + normal * body:GetCollisionMargin()
	local correction = target - point
	local depth = correction:Dot(normal)

	if depth <= EPSILON or depth > policy.depth_limit then return nil end

	if policy.tangent_limit then
		local tangent = correction - normal * depth

		if tangent:GetLength() > policy.tangent_limit then return nil end
	end

	return {
		point = point,
		local_point = local_point,
		hit = cached.hit,
		normal = normal,
		depth = depth,
		position = contact_position,
		cached = true,
	}
end

local build_contact_set

local function append_point_contacts(descriptor, pass_contacts, point_contacts, local_point, cached, max_contacts)
	if not point_contacts then return false end

	local limit = max_contacts and math.min(#point_contacts, max_contacts) or #point_contacts
	local added = false

	for i = 1, limit do
		local contact = point_contacts[i]
		contact.local_point = local_point

		if cached then try_hydrate_cached_contact(contact, cached, descriptor.policy) end

		pass_contacts[#pass_contacts + 1] = contact
		added = true
	end

	return added
end

local function query_manifold_point_contacts(descriptor, query, pass_contacts, solve_state)
	local body = descriptor.body
	local _, cached = get_cached_contact_entry(body, descriptor.kind, query.local_point)
	local hit = physics.Trace(
		query.trace_origin,
		query.trace_direction,
		query.trace_distance,
		body:GetOwner(),
		body:GetFilterFunction()
	)

	if
		hit and
		(
			not query.hit_distance_limit or
			hit.distance <= query.hit_distance_limit
		)
	then
		if query.try_solve_hit and query.try_solve_hit(hit, solve_state) then
			return false, true
		end

		local point_contacts = build_contact_set(body, query.point, hit, query.preferred_direction)
		local added = append_point_contacts(
			descriptor,
			pass_contacts,
			point_contacts,
			query.local_point,
			cached,
			query.max_contacts
		)
		return added, false
	end

	if query.allow_cached and cached then
		local cached_contact = build_cached_contact(body, query.point, query.local_point, cached, descriptor.policy)

		if cached_contact then
			pass_contacts[#pass_contacts + 1] = cached_contact
			return true, false
		end
	end

	return false, false
end

local function get_world_support_points(body)
	if has_world_trace_source() and body.GetShapeType and body:GetShapeType() == "box" then
		local half = body:GetHalfExtents()
		local ex = half.x
		local ey = half.y
		local ez = half.z
		local points = {}
		local samples_x = {-1, 0, 1}
		local samples_z = {-1, 0, 1}

		for _, sx in ipairs(samples_x) do
			for _, sz in ipairs(samples_z) do
				points[#points + 1] = {
					local_point = Vec3(ex * sx, -ey, ez * sz),
				}
			end
		end

		return points
	end

	local points = {}
	local support_points = body:GetSupportLocalPoints() or {}
	local sparse = has_world_trace_source() and #support_points > 9
	local stride = sparse and math.max(1, math.floor(#support_points / 9)) or 1

	for index = 1, #support_points, stride do
		local local_point = support_points[index]
		points[#points + 1] = {local_point = local_point}
	end

	return points
end

local apply_static_contact_impulse
local build_contact
local apply_contact_sequence
local get_point_velocity

local function try_solve_sphere_brush_contact(body, hit, dt)
	local shape = body.GetPhysicsShape and body:GetPhysicsShape() or nil

	if
		not (
			shape and
			shape.GetTypeName and
			shape:GetTypeName() == "sphere" and
			shape.GetRadius and
			hit and
			hit.primitive and
			hit.primitive.brush_planes and
			hit.primitive.brush_planes[1]
		)
	then
		return false
	end

	local center = body:GetPosition()
	local radius = shape:GetRadius()
	local margin = body:GetCollisionMargin()
	local inflate = radius + margin
	local planes = hit.primitive.brush_planes
	local closest = center:Copy()
	local changed = false

	for _ = 1, 8 do
		local pass_changed = false

		for _, plane in ipairs(planes) do
			local signed_distance = closest:Dot(plane.normal) - plane.dist

			if signed_distance > EPSILON then
				closest = closest - plane.normal * signed_distance
				pass_changed = true
				changed = true
			end
		end

		if not pass_changed then break end
	end

	local delta = center - closest
	local distance = delta:GetLength()

	if changed and distance > EPSILON then
		if distance > inflate then return false end

		local normal = delta / distance
		local depth = inflate - distance

		if depth <= EPSILON then return false end

		local contact_point = center - normal * radius
		body:ApplyCorrection(0, normal * depth, contact_point, nil, nil, dt)
		apply_static_contact_impulse(body, contact_point, normal, dt)

		if normal.y >= body:GetMinGroundNormalY() then
			body:SetGrounded(true)
			body:SetGroundNormal(normal)
		end

		if physics.RecordWorldCollision then
			physics.RecordWorldCollision(body, hit, normal, depth)
		end

		return true
	end

	local max_signed_distance = -math.huge
	local signed_distances = {}

	for i, plane in ipairs(planes) do
		local signed_distance = center:Dot(plane.normal) - plane.dist
		signed_distances[i] = signed_distance

		if signed_distance > max_signed_distance then
			max_signed_distance = signed_distance
		end
	end

	if max_signed_distance <= -inflate then return false end

	local blend_epsilon = math.max(0.02, radius * 0.1)
	local normal = Vec3(0, 0, 0)
	local active_planes = {}

	for i, plane in ipairs(planes) do
		if signed_distances[i] >= max_signed_distance - blend_epsilon then
			normal = normal + plane.normal
			active_planes[#active_planes + 1] = plane
		end
	end

	if normal:GetLength() <= EPSILON then return false end

	normal = normal:GetNormalized()
	local depth = 0

	for _, plane in ipairs(active_planes) do
		local denom = normal:Dot(plane.normal)

		if denom > EPSILON then
			depth = math.max(depth, (inflate + center:Dot(plane.normal) - plane.dist) / denom)
		end
	end

	if depth <= EPSILON then return false end

	local contact_point = center - normal * radius
	body:ApplyCorrection(0, normal * depth, contact_point, nil, nil, dt)
	apply_static_contact_impulse(body, contact_point, normal, dt)

	if normal.y >= body:GetMinGroundNormalY() then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	if physics.RecordWorldCollision then
		physics.RecordWorldCollision(body, hit, normal, depth)
	end

	return true
end

local function append_contact(contacts, contact)
	if contact then contacts[#contacts + 1] = contact end
end

local function get_brush_feature_planes(hit, reference_point, preferred_direction)
	if
		not (
			hit and
			reference_point and
			hit.primitive and
			hit.primitive.brush_planes and
			hit.primitive.brush_planes[1]
		)
	then
		return nil
	end

	local max_signed_distance = -math.huge
	local signed_distances = {}
	local active_planes = {}
	local filtered_planes = nil

	for i, plane in ipairs(hit.primitive.brush_planes) do
		local signed_distance = reference_point:Dot(plane.normal) - plane.dist
		signed_distances[i] = signed_distance

		if signed_distance > max_signed_distance then
			max_signed_distance = signed_distance
		end
	end

	for i, plane in ipairs(hit.primitive.brush_planes) do
		if signed_distances[i] >= max_signed_distance - BRUSH_FEATURE_EPSILON then
			active_planes[#active_planes + 1] = plane
		end
	end

	if not active_planes[1] then return nil end

	if preferred_direction and preferred_direction:GetLength() > EPSILON then
		filtered_planes = {}

		for _, plane in ipairs(active_planes) do
			if preferred_direction:Dot(plane.normal) <= -0.05 then
				filtered_planes[#filtered_planes + 1] = plane
			end
		end

		if filtered_planes[1] then
			table.sort(filtered_planes, function(a, b)
				return preferred_direction:Dot(a.normal) < preferred_direction:Dot(b.normal)
			end)
		end
	end

	return filtered_planes and filtered_planes[1] and filtered_planes or active_planes
end

local function build_plane_contact(body, point, hit, normal, plane_dist)
	local projected = point - normal * (point:Dot(normal) - plane_dist)
	local target = projected + normal * body:GetCollisionMargin()
	local correction = target - point
	local depth = correction:Dot(normal)

	if depth <= 0 then return nil end

	return {
		point = point,
		position = projected:Copy(),
		hit = hit,
		normal = normal,
		depth = depth,
	}
end

build_contact_set = function(body, point, hit, preferred_direction)
	local planes = get_brush_feature_planes(hit, point, preferred_direction)

	if planes then
		local contacts = {}

		for _, plane in ipairs(planes) do
			append_contact(contacts, build_plane_contact(body, point, hit, plane.normal, plane.dist))
		end

		if contacts[1] then return contacts end
	end

	local contact = build_contact(body, point, hit)

	if not contact then return nil end

	return {contact}
end

local function solve_contact(body, point, hit, dt)
	if try_solve_sphere_brush_contact(body, hit, dt) then return true end

	local contacts = build_contact_set(body, point, hit)

	if not (contacts and contacts[1]) then return false end

	local grounded_normal = nil
	local grounded_weight = 0
	local solved, next_grounded_normal, next_grounded_weight = apply_contact_sequence(body, contacts, dt, grounded_normal, grounded_weight)

	if next_grounded_normal and next_grounded_weight > EPSILON then
		body:SetGroundNormal((next_grounded_normal / next_grounded_weight):GetNormalized())
	end

	return solved
end

build_contact = function(body, point, hit)
	local surface_contact = physics.GetHitSurfaceContact and physics.GetHitSurfaceContact(hit, point) or nil
	local normal = surface_contact and surface_contact.normal or nil
	local contact_position = surface_contact and surface_contact.position or (hit and hit.position) or nil

	if not (hit and normal and contact_position) then return nil end

	local target = contact_position + normal * body:GetCollisionMargin()
	local correction = target - point
	local depth = correction:Dot(normal)

	if depth <= 0 then return nil end

	return {
		point = point,
		position = contact_position:Copy(),
		hit = hit,
		normal = normal,
		depth = depth,
	}
end
get_point_velocity = function(body, point)
	return body:GetVelocity() + body:GetAngularVelocity():GetCross(point - body:GetPosition())
end

function apply_static_contact_impulse(body, point, normal, dt, contact)
	if not (body.HasSolverMass and body:HasSolverMass()) then return end

	local point_velocity = get_point_velocity(body, point)
	local normal_speed = point_velocity:Dot(normal)
	local normal_impulse = 0
	local applied_impulse = false
	local allow_persistent_tangent = contact and contact.cached and normal.y < body:GetMinGroundNormalY()
	local tangent = allow_persistent_tangent and get_cached_tangent(contact, normal) or nil
	local previous_tangent_impulse = allow_persistent_tangent and (contact.tangent_impulse or 0) or 0
	local tangent_warmed = false

	if tangent and math.abs(previous_tangent_impulse) > EPSILON then
		local tangent_speed = math.abs(point_velocity:Dot(tangent))

		if tangent_speed <= WORLD_MAX_TANGENT_WARM_SPEED then
			local warm_impulse = tangent * (previous_tangent_impulse * WORLD_TANGENT_WARM_START_SCALE)
			body:ApplyImpulse(warm_impulse, point)
			point_velocity = get_point_velocity(body, point)
			normal_speed = point_velocity:Dot(normal)
			applied_impulse = true
			tangent_warmed = true
		end
	end

	if normal_speed < -EPSILON then
		local inverse_mass = body:GetInverseMassAlong(normal, point)

		if inverse_mass > EPSILON then
			normal_impulse = -normal_speed / inverse_mass
			body:ApplyImpulse(normal * normal_impulse, point)
			point_velocity = get_point_velocity(body, point)
			applied_impulse = true
		end
	end

	local tangent_velocity = point_velocity - normal * point_velocity:Dot(normal)
	local tangent_speed = tangent_velocity:GetLength()

	if tangent_speed <= EPSILON then
		if contact then
			contact.tangent_impulse = 0
			contact.tangent = nil
		end

		if applied_impulse then sync_body_motion_history(body, dt) end

		return
	end

	local friction = math.max(body:GetFriction() or 0, 0)

	if friction <= 0 then
		if contact then
			contact.tangent_impulse = 0
			contact.tangent = nil
		end

		if applied_impulse then sync_body_motion_history(body, dt) end

		return
	end

	tangent = tangent_velocity / tangent_speed
	local tangent_inverse_mass = body:GetInverseMassAlong(tangent, point)

	if tangent_inverse_mass <= EPSILON then return end

	local tangent_impulse = -point_velocity:Dot(tangent) / tangent_inverse_mass
	local max_friction_impulse = math.max(normal_impulse, 0.05) * friction

	if allow_persistent_tangent then
		local new_tangent_impulse = math.max(
			-max_friction_impulse,
			math.min(max_friction_impulse, previous_tangent_impulse + tangent_impulse)
		)
		tangent_impulse = new_tangent_impulse - previous_tangent_impulse
		contact.tangent_impulse = new_tangent_impulse
		contact.tangent = tangent:Copy()
	else
		tangent_impulse = math.max(-max_friction_impulse, math.min(max_friction_impulse, tangent_impulse))
	end

	if math.abs(tangent_impulse) > EPSILON then
		body:ApplyImpulse(tangent * tangent_impulse, point)
		applied_impulse = true
	elseif contact and tangent_warmed then
		contact.tangent = tangent:Copy()
	end

	if applied_impulse then sync_body_motion_history(body, dt) end
end

local function apply_contact_patch(body, contacts, dt, grounded_normal, grounded_weight)
	local patch_count = #contacts

	if patch_count == 0 then return false, grounded_normal, grounded_weight end

	for i = 1, patch_count do
		local contact = contacts[i]
		body:ApplyCorrection(0, contact.normal * (contact.depth / patch_count), contact.point, nil, nil, dt)
	end

	for i = 1, patch_count do
		local contact = contacts[i]
		apply_static_contact_impulse(body, contact.point, contact.normal, dt, contact)

		if contact.normal.y >= body:GetMinGroundNormalY() then
			grounded_normal = (grounded_normal or physics.Up * 0) + contact.normal * contact.depth
			grounded_weight = grounded_weight + contact.depth
			body:SetGrounded(true)
		end

		if physics.RecordWorldCollision then
			physics.RecordWorldCollision(body, contact.hit, contact.normal, contact.depth)
		end
	end

	return true, grounded_normal, grounded_weight
end

local function contacts_form_coherent_patch(contacts)
	if #contacts <= 1 then return false end

	local reference = contacts[1] and contacts[1].normal

	if not reference then return false end

	for i = 2, #contacts do
		local normal = contacts[i] and contacts[i].normal

		if not (normal and reference:Dot(normal) >= 0.9) then return false end
	end

	return true
end

apply_contact_sequence = function(body, contacts, dt, grounded_normal, grounded_weight)
	local solved = false

	for i = 1, #contacts do
		local contact = contacts[i]
		body:ApplyCorrection(0, contact.normal * contact.depth, contact.point, nil, nil, dt)
		apply_static_contact_impulse(body, contact.point, contact.normal, dt, contact)

		if contact.normal.y >= body:GetMinGroundNormalY() then
			grounded_normal = (grounded_normal or physics.Up * 0) + contact.normal * contact.depth
			grounded_weight = grounded_weight + contact.depth
			body:SetGrounded(true)
		end

		if physics.RecordWorldCollision then
			physics.RecordWorldCollision(body, contact.hit, contact.normal, contact.depth)
		end

		solved = true
	end

	return solved, grounded_normal, grounded_weight
end

local function clear_contacts(contacts)
	for i = #contacts, 1, -1 do
		contacts[i] = nil
	end
end

local function create_contact_pass_descriptor(kind, body, contacts)
	local state = get_contact_state(body, kind)
	return {
		kind = kind,
		body = body,
		contacts = contacts,
		state = state,
		policy = state.policy,
	}
end

local function collect_descriptor_point_contacts(descriptor, pass_contacts, solve_state)
	local pass_solved = false

	for _, point_item in ipairs(descriptor.state.point_items or {}) do
		local query = descriptor.build_point_query(point_item, solve_state)

		if
			query and
			query_manifold_point_contacts(descriptor, query, pass_contacts, solve_state)
		then
			pass_solved = true
		end
	end

	return pass_solved
end

local function should_use_descriptor_patch(descriptor, contacts)
	local policy = descriptor.policy
	local state = descriptor.state

	if
		policy.patch_requires_coherent_contacts and
		not contacts_form_coherent_patch(contacts)
	then
		return false
	end

	if
		policy.patch_velocity_y_limit and
		math.abs(state.velocity.y) > policy.patch_velocity_y_limit
	then
		return false
	end

	if
		policy.patch_angular_speed_limit and
		state.angular_speed > policy.patch_angular_speed_limit
	then
		return false
	end

	if policy.patch_up_y_limit and state.up_y < policy.patch_up_y_limit then
		return false
	end

	return true
end

local function solve_manifold_contact_passes(descriptor, dt)
	local body = descriptor.body
	local kind = descriptor.kind
	local contacts = descriptor.contacts
	local grounded_normal = nil
	local grounded_weight = 0
	local state = {solved = false}

	for _ = 1, descriptor.pass_count do
		clear_contacts(contacts)
		local pass_solved = descriptor.collect_contacts(contacts, state)

		if not pass_solved then break end

		local patch_solved

		if descriptor.should_use_patch(contacts, state) then
			patch_solved, grounded_normal, grounded_weight = apply_contact_patch(body, contacts, dt, grounded_normal, grounded_weight)
		else
			patch_solved, grounded_normal, grounded_weight = apply_contact_sequence(body, contacts, dt, grounded_normal, grounded_weight)
		end

		cache_contacts(body, kind, contacts)
		state.solved = state.solved or patch_solved
	end

	if not state.solved then clear_contact_cache(body, kind) end

	if grounded_normal and grounded_weight > EPSILON then
		body:SetGroundNormal((grounded_normal / grounded_weight):GetNormalized())
	end

	return state.solved
end

local function create_world_contact_pass_descriptor(kind, body, dt, configure)
	local descriptor = create_contact_pass_descriptor(kind, body, {})
	descriptor.state.dt = dt
	descriptor.state.kind = kind
	descriptor.state.point_items = descriptor.state.point_items or {}
	descriptor.pass_count = 1
	configure(descriptor)
	descriptor.collect_contacts = descriptor.collect_contacts or
		function(pass_contacts, solve_state)
			return collect_descriptor_point_contacts(descriptor, pass_contacts, solve_state)
		end
	return descriptor
end

local function create_support_contact_pass_descriptor(body, dt)
	return create_world_contact_pass_descriptor(
		"support",
		body,
		dt,
		function(descriptor)
			local velocity = body:GetVelocity()
			local angular_speed = body:GetAngularVelocity():GetLength()
			local downward = math.max(0, -velocity.y * dt)
			local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
			local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()
			local support_points = get_world_support_points(body)
			local up_y = math.abs(body:GetRotation():GetUp().y)
			local allow_cached_support = body:GetGrounded() and
				math.abs(velocity.y) <= 0.75 and
				angular_speed <= 1.5 and
				up_y >= 0.85
			descriptor.state.trace_mode = "support"
			descriptor.state.point_source = "support_points"
			descriptor.state.query_builder = "support_probe"
			descriptor.state.cached_surface_mode = descriptor.policy.cached_surface_mode
			descriptor.state.velocity = velocity
			descriptor.state.angular_speed = angular_speed
			descriptor.state.cast_up = cast_up
			descriptor.state.cast_distance = cast_distance
			descriptor.state.support_points = support_points
			descriptor.state.point_items = support_points
			descriptor.state.up_y = up_y
			descriptor.state.allow_cached = allow_cached_support
			descriptor.state.patch_velocity_y_limit = descriptor.policy.patch_velocity_y_limit
			descriptor.state.patch_angular_speed_limit = descriptor.policy.patch_angular_speed_limit
			descriptor.state.patch_up_y_limit = descriptor.policy.patch_up_y_limit
			descriptor.pass_count = has_world_trace_source() and 1 or 2
			descriptor.build_point_query = function(point_data)
				local point = body:GeometryLocalToWorld(point_data.local_point)
				return {
					local_point = point_data.local_point,
					point = point,
					trace_origin = point + physics.Up * descriptor.state.cast_up,
					trace_direction = physics.Up * -1,
					trace_distance = descriptor.state.cast_distance,
					preferred_direction = physics.Up * -1,
					allow_cached = descriptor.state.allow_cached,
					max_contacts = 1,
				}
			end
			descriptor.should_use_patch = function(pass_contacts)
				return should_use_descriptor_patch(descriptor, pass_contacts)
			end
		end
	)
end

local function create_motion_contact_pass_descriptor(body, dt)
	return create_world_contact_pass_descriptor(
		"motion",
		body,
		dt,
		function(descriptor)
			local sweep_margin = body:GetCollisionMargin() + body:GetCollisionProbeDistance()
			local velocity = body:GetVelocity()
			local angular_speed = body:GetAngularVelocity():GetLength()
			local allow_cached_motion = not body:GetGrounded() and velocity:GetLength() <= 12 and angular_speed <= 6
			descriptor.state.trace_mode = "sweep"
			descriptor.state.point_source = "collision_points"
			descriptor.state.query_builder = "motion_sweep"
			descriptor.state.cached_surface_mode = descriptor.policy.cached_surface_mode
			descriptor.state.sweep_margin = sweep_margin
			descriptor.state.velocity = velocity
			descriptor.state.angular_speed = angular_speed
			descriptor.state.allow_cached = allow_cached_motion
			descriptor.state.collision_points = body:GetCollisionLocalPoints()
			descriptor.state.point_items = descriptor.state.collision_points
			descriptor.state.patch_requires_coherent_contacts = descriptor.policy.patch_requires_coherent_contacts == true
			descriptor.pass_count = has_world_trace_source() and 2 or 1
			descriptor.build_point_query = function(local_point)
				local previous = body:GeometryLocalToWorld(local_point, body:GetPreviousPosition(), body:GetPreviousRotation())
				local current = body:GeometryLocalToWorld(local_point)
				local delta = current - previous
				local distance = delta:GetLength()

				if distance <= 0.0001 then return nil end

				local preferred_direction = distance > EPSILON and (delta / distance) or nil
				return {
					local_point = local_point,
					point = current,
					trace_origin = previous,
					trace_direction = delta,
					trace_distance = distance + descriptor.state.sweep_margin,
					hit_distance_limit = distance + descriptor.state.sweep_margin,
					preferred_direction = preferred_direction,
					allow_cached = descriptor.state.allow_cached,
					try_solve_hit = function(hit, query_solve_state)
						if try_solve_sphere_brush_contact(body, hit, dt) then
							query_solve_state.solved = true
							return true
						end

						return false
					end,
				}
			end
			descriptor.should_use_patch = function(pass_contacts)
				return should_use_descriptor_patch(descriptor, pass_contacts)
			end
		end
	)
end

local function solve_support_contact_patch(body, dt)
	local descriptor = create_support_contact_pass_descriptor(body, dt)
	return solve_manifold_contact_passes(descriptor, dt)
end

local function solve_motion_contacts(body, dt)
	if not body.CollisionEnabled then return end

	local descriptor = create_motion_contact_pass_descriptor(body, dt)
	return solve_manifold_contact_passes(descriptor, dt)
end

local function solve_support_contacts(body, dt)
	if not body.CollisionEnabled then return end

	local shape = body:GetPhysicsShape()

	if shape and shape.GetRadius and shape.SolveSupportContacts then
		return shape:SolveSupportContacts(body, dt, solve_contact)
	end

	return solve_support_contact_patch(body, dt)
end

function world_contacts.SolveContact(body, point, hit, dt)
	return solve_contact(body, point, hit, dt)
end

function world_contacts.SolveBodyContacts(body, dt)
	solve_motion_contacts(body, dt)
	solve_support_contacts(body, dt)
end

return world_contacts