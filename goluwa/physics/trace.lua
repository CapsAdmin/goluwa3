local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics/shared.lua")
local raycast = import("goluwa/physics/raycast.lua")

local function filter(entity, options)
	options = options or {}
	local ignore_kinematic = options.IgnoreKinematicBodies ~= false
	local ignore_rigid = options.IgnoreRigidBodies ~= false

	if entity == options.IgnoreEntity then return false end

	if entity.PhysicsNoCollision or entity.NoPhysicsCollision then return false end

	if ignore_kinematic and entity.kinematic_body then return false end

	if ignore_rigid and entity.rigid_body then return false end

	if options.FilterFunction and not options.FilterFunction(entity) then
		return false
	end

	return true
end

local function cast_with_filter(
	origin,
	direction,
	max_distance,
	ignore_entity,
	filter_fn,
	options,
	ignore_rigid_override
)
	local cast_options = options or {}
	local previous_ignore_entity = cast_options.IgnoreEntity
	local previous_filter_function = cast_options.FilterFunction
	local previous_ignore_rigid = cast_options.IgnoreRigidBodies
	cast_options.IgnoreEntity = ignore_entity
	cast_options.FilterFunction = filter_fn

	if ignore_rigid_override ~= nil then
		cast_options.IgnoreRigidBodies = ignore_rigid_override
	end

	local hits = raycast.Cast(origin, direction, max_distance or math.huge, filter, cast_options)
	cast_options.IgnoreEntity = previous_ignore_entity
	cast_options.FilterFunction = previous_filter_function

	if ignore_rigid_override ~= nil then
		cast_options.IgnoreRigidBodies = previous_ignore_rigid
	end

	return hits
end

function physics.Trace(origin, direction, max_distance, ignore_entity, filter_fn, options)
	local hits = cast_with_filter(origin, direction, max_distance, ignore_entity, filter_fn, options)
	return hits[1]
end

function physics.TraceDown(origin, radius, ignore_entity, max_distance, filter_fn, options)
	options = options or {}
	local allow_rigid = options.IgnoreRigidBodies == false
	local hits = cast_with_filter(
		origin,
		Vec3(0, -1, 0),
		max_distance,
		ignore_entity,
		filter_fn,
		options,
		allow_rigid and true or nil
	)
	local best_hit = nil

	for _, hit in ipairs(hits) do
		if hit.normal and hit.normal.y >= 0 then
			best_hit = hit

			break
		end
	end

	if not best_hit then best_hit = hits[1] end

	if allow_rigid then
		local rigid_body = physics.GetRigidBodyMeta()

		for _, body in ipairs(rigid_body.Instances or {}) do
			if not (physics.IsActiveRigidBody(body) and body.Owner ~= ignore_entity) then
				goto continue
			end

			if body.Owner and (body.Owner.PhysicsNoCollision or body.Owner.NoPhysicsCollision) then
				goto continue
			end

			if filter_fn and not filter_fn(body.Owner) then goto continue end

			local shape = body.GetPhysicsShape and body:GetPhysicsShape()
			local hit = shape and
				shape.TraceDownAgainstBody and
				shape:TraceDownAgainstBody(body, origin, max_distance)

			if hit and (not best_hit or hit.distance < best_hit.distance) then
				best_hit = hit
			end

			::continue::
		end
	end

	return best_hit
end

local function get_hit_face_normal(hit)
	if
		not (
			hit and
			hit.primitive and
			hit.primitive.polygon3d and
			hit.triangle_index ~= nil
		)
	then
		return hit and hit.normal or nil
	end

	local poly = hit.primitive.polygon3d
	local vertices = poly.Vertices

	if not vertices or #vertices == 0 then return hit.normal end

	local base = hit.triangle_index * 3
	local indices = poly.indices
	local i0
	local i1
	local i2

	if indices then
		i0 = indices[base + 1] + 1
		i1 = indices[base + 2] + 1
		i2 = indices[base + 3] + 1
	else
		i0 = base + 1
		i1 = base + 2
		i2 = base + 3
	end

	local v0 = vertices[i0] and vertices[i0].pos
	local v1 = vertices[i1] and vertices[i1].pos
	local v2 = vertices[i2] and vertices[i2].pos

	if not (v0 and v1 and v2) then return hit.normal end

	if hit.entity and hit.entity.transform then
		local world = hit.entity.transform:GetWorldMatrix()
		v0 = Vec3(world:TransformVector(v0.x, v0.y, v0.z))
		v1 = Vec3(world:TransformVector(v1.x, v1.y, v1.z))
		v2 = Vec3(world:TransformVector(v2.x, v2.y, v2.z))
	end

	return (v1 - v0):GetCross(v2 - v0):GetNormalized()
end

function physics.GetHitNormal(hit, reference_point)
	local normal = get_hit_face_normal(hit)

	if not normal then return nil end

	if reference_point and hit and hit.position then
		if (reference_point - hit.position):Dot(normal) < 0 then normal = normal * -1 end
	elseif hit and hit.normal and normal:Dot(hit.normal) < 0 then
		normal = normal * -1
	end

	return normal
end

return physics