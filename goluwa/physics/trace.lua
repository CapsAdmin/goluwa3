local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics/shared.lua")
local raycast = import("goluwa/physics/raycast.lua")
local RigidBodyComponent = import("goluwa/ecs/components/3d/rigid_body.lua")

local function filter(entity, ignore_entity, filter_fn, ignore_kinematic, ignore_rigid)
	if entity == ignore_entity then return false end

	if entity.PhysicsNoCollision or entity.NoPhysicsCollision then return false end

	if
		ignore_kinematic and
		entity.rigid_body and
		entity.rigid_body.IsKinematic and
		entity.rigid_body:IsKinematic()
	then
		return false
	end

	if ignore_rigid and entity.rigid_body then return false end

	if filter_fn and not filter_fn(entity) then return false end

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
	local ignore_kinematic = cast_options.IgnoreKinematicBodies ~= false
	local ignore_rigid = cast_options.IgnoreRigidBodies ~= false
	local world_source = cast_options.WorldSource

	if ignore_rigid_override ~= nil then ignore_rigid = ignore_rigid_override end

	if world_source == nil and physics.GetWorldTraceSource then
		world_source = physics.GetWorldTraceSource()
	end

	local use_render_meshes = cast_options.UseRenderMeshes

	if use_render_meshes == nil then use_render_meshes = world_source == nil end

	if cast_options.ClosestOnly ~= false then
		if world_source then
			local hit = raycast.CastClosestFromSource(
				world_source,
				origin,
				direction,
				max_distance or math.huge,
				filter,
				ignore_entity,
				filter_fn,
				ignore_kinematic,
				ignore_rigid
			)
			return hit and {hit} or {}
		end

		if not use_render_meshes then return {} end

		local hit = raycast.CastClosest(
			origin,
			direction,
			max_distance or math.huge,
			filter,
			ignore_entity,
			filter_fn,
			ignore_kinematic,
			ignore_rigid
		)
		return hit and {hit} or {}
	end

	if world_source then
		return raycast.CastFromSource(
			world_source,
			origin,
			direction,
			max_distance or math.huge,
			filter,
			ignore_entity,
			filter_fn,
			ignore_kinematic,
			ignore_rigid
		)
	end

	if not use_render_meshes then return {} end

	local hits = raycast.Cast(
		origin,
		direction,
		max_distance or math.huge,
		filter,
		ignore_entity,
		filter_fn,
		ignore_kinematic,
		ignore_rigid
	)
	return hits
end

local function is_straight_down(direction)
	return direction and
		math.abs(direction.x) <= 0.00001 and
		direction.y < -0.00001 and
		math.abs(direction.z) <= 0.00001
end

local function pick_best_world_hit(hits, direction)
	if not (hits and hits[1]) then return nil end

	if is_straight_down(direction) then
		for _, hit in ipairs(hits) do
			if hit.normal and hit.normal.y >= 0 then return hit end
		end
	end

	return hits[1]
end

function physics.Trace(origin, direction, max_distance, ignore_entity, filter_fn, options)
	options = options or {}
	local allow_rigid = options.IgnoreRigidBodies == false
	local downward_trace = is_straight_down(direction)
	local hits = cast_with_filter(
		origin,
		direction,
		max_distance,
		ignore_entity,
		filter_fn,
		options,
		allow_rigid and true or nil
	)
	local best_hit = pick_best_world_hit(hits, direction)

	if allow_rigid then
		local trace_radius = options.TraceRadius or 0

		for _, body in ipairs(RigidBodyComponent.Instances or {}) do
			if not (physics.IsActiveRigidBody(body) and body.Owner ~= ignore_entity) then
				goto continue
			end

			if body.Owner and (body.Owner.PhysicsNoCollision or body.Owner.NoPhysicsCollision) then
				goto continue
			end

			if
				options.IgnoreKinematicBodies ~= false and
				body.IsKinematic and
				body:IsKinematic()
			then
				goto continue
			end

			if filter_fn and not filter_fn(body.Owner) then goto continue end

			for _, collider in ipairs(body.GetColliders and body:GetColliders() or {}) do
				local hit = collider:GetPhysicsShape():TraceAgainstBody(collider, origin, direction, max_distance, trace_radius)

				if hit and (not best_hit or hit.distance < best_hit.distance) then
					best_hit = hit
				end
			end

			::continue::
		end
	end

	return best_hit
end

local function get_hit_face_normal(hit)
	if hit and hit.face_normal then return hit.face_normal end

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