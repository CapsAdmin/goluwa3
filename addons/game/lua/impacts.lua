local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local system = import("goluwa/system.lua")
local impacts = {}

local function get_surface(hit)
	local material = physics.GetHitMaterial(hit)
	return material and
		material:GetSurfaceType() or
		hit.entity.ragdoll_part and
		"flesh" or
		"default",
	material
end

function impacts.Fire(entity, part, kind, hit, speed, mass, size)
	local surface, material = get_surface(hit)
	event.Call(
		"Impact",
		{
			Entity = entity,
			Part = part,
			Kind = kind,
			Surface = surface,
			Material = material,
			Other = hit.entity,
			Position = hit.position,
			Normal = hit.normal,
			Speed = speed,
			Mass = mass,
			Size = size,
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

	local function fire_side(entity, hit, speed, mass, size)
		local part = entity.ragdoll_part

		if part then
			impacts.Fire(part.Character, part.Group, "physics", hit, speed, mass, size)
		else
			impacts.Fire(entity, nil, "physics", hit, speed, mass, size)
		end
	end

	local function get_body_size(entity)
		local body = entity.rigid_body

		if not body or not body:IsDynamic() then return end

		local half = body:GetHalfExtents()
		return 2 * (half.x * half.y * half.z) ^ (1 / 3)
	end

	local function get_sounding_size(sounding, other)
		return get_body_size(sounding) or get_body_size(other)
	end

	local function get_reduced_mass(body_a, body_b)
		local mass_a = body_a and body_a:IsDynamic() and body_a:GetMass() or math.huge
		local mass_b = body_b and body_b:IsDynamic() and body_b:GetMass() or math.huge

		if mass_a == math.huge then return mass_b end

		if mass_b == math.huge then return mass_a end

		return mass_a * mass_b / (mass_a + mass_b)
	end

	local function is_ignored(entity_a, entity_b)
		if entity_a.character_movement or entity_b.character_movement then
			return true
		end

		local part_a, part_b = entity_a.ragdoll_part, entity_b.ragdoll_part
		return part_a and part_b and part_a.Character == part_b.Character
	end

	function impacts.FirePhysics(impact)
		local entity_a, entity_b = impact.entity_a, impact.entity_b

		if is_ignored(entity_a, entity_b) then return end

		local normal = impact.normal
		local mass = get_reduced_mass(impact.body_a, impact.body_b)
		fire_side(
			entity_b,
			impact.hit_a or get_surface_hit(entity_a, impact.position, normal * -1),
			impact.speed,
			mass,
			get_sounding_size(entity_a, entity_b)
		)
		fire_side(
			entity_a,
			get_surface_hit(entity_b, impact.position, normal),
			impact.speed,
			mass,
			get_sounding_size(entity_b, entity_a)
		)
	end

	local SURFACE_REFRESH = 0.25
	local surfaces = table.weak("k")

	local function fire_contact(entity, other, surface, material, contact, normal, rolling, mass, size)
		local part = entity.ragdoll_part
		event.Call(
			"Contact",
			{
				Entity = part and part.Character or entity,
				Part = part and part.Group,
				Other = other,
				Surface = surface,
				Material = material,
				Position = contact.position,
				Normal = normal,
				Slip = contact.slip,
				Roll = contact.roll,
				Rolling = rolling,
				Mass = mass,
				Size = size,
			}
		)
	end

	function impacts.FireContact(contact)
		local entity_a, entity_b = contact.entity_a, contact.entity_b

		if is_ignored(entity_a, entity_b) then return end

		local row = surfaces[entity_a]

		if not row then
			row = table.weak("k")
			surfaces[entity_a] = row
		end

		local now = system.GetElapsedTime()
		local cached = row[entity_b]

		if not cached or now - cached.time > SURFACE_REFRESH then
			local normal = contact.normal
			cached = cached or {}
			cached.time = now
			cached.surface_a, cached.material_a = get_surface(contact.hit_a or get_surface_hit(entity_a, contact.position, normal * -1))
			cached.surface_b, cached.material_b = get_surface(get_surface_hit(entity_b, contact.position, normal))
			row[entity_b] = cached
		end

		local mass = get_reduced_mass(contact.body_a, contact.body_b)
		fire_contact(
			entity_b,
			entity_a,
			cached.surface_a,
			cached.material_a,
			contact,
			contact.normal,
			contact.roller == contact.body_b,
			mass,
			get_sounding_size(entity_a, entity_b)
		)
		fire_contact(
			entity_a,
			entity_b,
			cached.surface_b,
			cached.material_b,
			contact,
			contact.normal * -1,
			contact.roller == contact.body_a,
			mass,
			get_sounding_size(entity_b, entity_a)
		)
	end
end

return impacts
