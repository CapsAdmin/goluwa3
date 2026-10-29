local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local impacts = {}

function impacts.Fire(entity, part, kind, hit, speed)
	local material = physics.GetHitMaterial(hit)
	event.Call(
		"Impact",
		{
			Entity = entity,
			Part = part,
			Kind = kind,
			Surface = material and
				material:GetSurfaceType() or
				hit.entity.ragdoll_part and
				"flesh" or
				"default",
			Material = material,
			Other = hit.entity,
			Position = hit.position,
			Normal = hit.normal,
			Speed = speed,
		}
	)
end

function impacts.FireFootstep(character, part, hit, speed)
	local ragdoll = character.ragdoll

	if ragdoll and ragdoll:HasLimp() then return end

	impacts.Fire(character, part, "footstep", hit, speed)
end

do
	local RAY_OPTIONS = {IncludeRigidBodies = true}
	local SURFACE_BACKOFF = 0.25
	local SURFACE_PROBE = 2
	local target

	local function is_target(entity)
		return entity == target
	end

	local function get_surface_hit(entity, position, direction)
		if entity.rigid_body and entity.rigid_body:IsDynamic() then
			return {entity = entity, position = position, normal = direction * -1}
		end

		target = entity
		return physics.RayCast(
				position - direction * SURFACE_BACKOFF,
				direction,
				SURFACE_PROBE,
				nil,
				is_target,
				RAY_OPTIONS
			) or
			{entity = entity, position = position, normal = direction * -1}
	end

	local function fire_side(entity, hit, speed)
		local part = entity.ragdoll_part

		if part then
			impacts.Fire(part.Character, part.Group, "physics", hit, speed)
		else
			impacts.Fire(entity, nil, "physics", hit, speed)
		end
	end

	function impacts.FirePhysics(impact)
		local entity_a, entity_b = impact.entity_a, impact.entity_b

		if entity_a.character_movement or entity_b.character_movement then return end

		local part_a, part_b = entity_a.ragdoll_part, entity_b.ragdoll_part

		if part_a and part_b and part_a.Character == part_b.Character then return end

		local normal = impact.normal
		fire_side(
			entity_b,
			impact.hit_a or get_surface_hit(entity_a, impact.position, normal * -1),
			impact.speed
		)
		fire_side(entity_a, get_surface_hit(entity_b, impact.position, normal), impact.speed)
	end
end

return impacts
