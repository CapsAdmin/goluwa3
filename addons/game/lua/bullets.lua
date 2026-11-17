local network = import("goluwa/network/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local damage = import("lua/damage.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local bullets = {}

function bullets.GetEye(character)
	return character.transform:GetPosition() + character.character_movement:GetViewOffset()
end

function bullets.Spread(forward, spread)
	if spread <= 0 then return forward end

	local right = forward:GetCross(Vec3(0, 1, 0))

	if right:GetLength() < 1e-3 then right = Vec3(1, 0, 0) end

	right:Normalize()
	local up = right:GetCross(forward)
	local angle = math.randomf(0, math.pi * 2)
	local radius = math.sqrt(math.random()) * math.tan(spread)
	return (
		forward + right * (
			math.cos(angle) * radius
		) + up * (
			math.sin(angle) * radius
		)
	):GetNormalized()
end

function bullets.Fire(info)
	local weapon = info.Weapon
	local attacker = info.Attacker
	local origin = info.Origin
	local range = info.Range or 100
	local impulse = info.Impulse or 4
	local authority = network.HasAuthority()
	weapon_effects.MuzzleFlash(weapon, info.Direction, info.Muzzle)

	for _ = 1, info.Count or 1 do
		local direction = bullets.Spread(info.Direction, info.Spread or 0)
		local hit = damage.Sweep(origin, direction * range, attacker)

		if not hit then
			weapon_effects.Tracer(weapon, origin + direction * range)
		else
			local force = direction * impulse
			weapon_effects.Bullet(
				weapon,
				hit.point,
				hit.normal,
				force,
				hit.entity or NULL,
				weapon_effects.GetSurface(hit),
				info.HoleSize or 1
			)

			if authority then
				local victim, multiplier

				if hit.entity then victim, multiplier = damage.GetVictim(hit.entity) end

				if victim and victim.health then
					damage.Deal(
						victim,
						{
							Attacker = attacker,
							Inflictor = weapon,
							Damage = info.Damage * multiplier * weapon.weapon:GetDamageScale(),
							Type = info.Type or "generic",
							Attributes = weapon.weapon.Attributes,
							Position = hit.point,
							Normal = hit.normal,
							Force = force,
							Part = hit.entity.ragdoll_part and hit.entity.ragdoll_part.Group,
						}
					)
				end

				local body = hit.rigid_body or (hit.entity and hit.entity.rigid_body)

				if body and body:IsDynamic() then body:ApplyImpulse(force, hit.point) end
			end
		end
	end
end

return bullets
