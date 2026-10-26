local RigidBody = import("goluwa/physics/rigid_body.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local slash = {}

local function to_attacker_side(normal, to_attacker)
	normal = normal:GetNormalized()

	if normal:Dot(to_attacker:GetNormalized()) < -0.05 then return normal * -1 end

	return normal
end

function slash.Strike(holder, inflictor, cut_local, amount, scale, range, element)
	local center = actors.GetCenter(holder)
	local forward = actors.GetForward(holder)
	local strike = center + forward * (range * 0.55)
	local hit_any = false
	local hits = {}
	local right = actors.GetRight(holder)
	local cut = (
		right * cut_local.x + Vec3(0, cut_local.y, 0) + forward * cut_local.z
	):GetNormalized()
	local plane_normal = cut:GetCross(forward)
	local stab = plane_normal:GetLength() < 0.2

	for _, victim in ipairs(actors.Find(strike, range, holder)) do
		local victim_center = actors.GetCenter(victim)
		local to_victim = victim_center - center
		to_victim.y = 0

		if to_victim:GetLength() < 0.7 or to_victim:GetNormalized():Dot(forward) > 0.15 then
			local normal = to_attacker_side(plane_normal, center - victim_center)
			local point, part = victim_center, nil

			if stab then
				normal = forward * -1
			else
				point = victim_center - normal * normal:Dot(victim_center - center)
			end

			local trace = damage.Sweep(center, point - center, holder)

			if trace and trace.entity and damage.GetVictim(trace.entity) == victim then
				point = trace.point
				part = trace.entity.ragdoll_part and trace.entity.ragdoll_part.Group
			end

			damage.Deal(
				victim,
				{
					Attacker = holder,
					Inflictor = inflictor,
					Damage = amount,
					Type = "slash",
					Position = point,
					Normal = normal,
					Force = cut * 5 * scale,
					Part = part,
					Direction = cut,
					Reaction = scale,
				}
			)

			if element ~= "" and victim.health and not victim.health:IsDead() then
				damage.Deal(
					victim,
					{
						Attacker = holder,
						Inflictor = inflictor,
						Damage = amount * 0.5,
						Type = element,
						Position = point,
						Normal = normal,
					}
				)
			end

			effects.Impact(point, normal, element ~= "" and element or "slash", scale, cut)
			hits[#hits + 1] = {victim = victim, point = point, normal = normal}
			hit_any = true
		end
	end

	for _, body in ipairs(RigidBody.Instances) do
		local owner = body.Owner

		if
			body:IsDynamic() and
			not owner.health and
			not owner.ragdoll_part and
			(
				body:GetPosition() - strike
			):GetLength() < range
		then
			body:ApplyImpulse(forward * 4 * scale / body.InverseMass ^ 0.5, body:GetPosition())
			hit_any = true
		end
	end

	return hit_any, cut, hits, stab and forward * -1 or plane_normal:GetNormalized()
end

return slash
