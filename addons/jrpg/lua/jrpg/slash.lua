local RigidBody = import("goluwa/physics/rigid_body.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local slash = {}
local SPRAY_TILT = 0.4
local SPRAY_JITTER = 0.12
local WORLD_SAMPLES = {-0.8, -0.4, 0, 0.4, 0.8}
local WORLD_SPACING = 0.3
local PROP_IMPULSE = 70

local function to_attacker_side(normal, to_attacker)
	normal = normal:GetNormalized()

	if normal:Dot(to_attacker:GetNormalized()) < -0.05 then return normal * -1 end

	return normal
end

function slash.StrikeWorld(holder, forward, cut, range, type_name, attributes, scale, amount)
	local center = actors.GetCenter(holder)
	local hit_any = false
	local world_points = {}

	for _, sample in ipairs(WORLD_SAMPLES) do
		local direction = (forward + cut * sample):GetNormalized()
		local trace = damage.Sweep(center, direction * range, holder)
		local struck = trace and trace.entity and damage.GetVictim(trace.entity)

		if struck and not (struck.health and not struck.health:IsDead()) then
			local fresh = true

			for _, other in ipairs(world_points) do
				if (other - trace.point):GetLength() < WORLD_SPACING then
					fresh = false

					break
				end
			end

			if fresh then
				world_points[#world_points + 1] = trace.point
				effects.Impact(
					trace.point,
					trace.normal,
					attributes[1] or type_name,
					scale,
					cut,
					(cut + trace.normal * SPRAY_TILT):GetNormalized(),
					amount
				)
				hit_any = true
			end
		end
	end

	return hit_any
end

function slash.Strike(
	holder,
	inflictor,
	forward,
	cut_local,
	amount,
	scale,
	range,
	type_name,
	attributes,
	target
)
	local center = actors.GetCenter(holder)
	local strike = center + forward * (range * 0.55)
	local hit_any = false
	local hits = {}
	local right = Vec3(-forward.z, 0, forward.x)
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
			local point, part, surface = victim_center, nil, nil

			if stab then
				normal = forward * -1
			else
				point = victim_center - normal * normal:Dot(victim_center - center)
			end

			local trace = damage.Sweep(center, point - center, holder)

			if trace and trace.entity and damage.GetVictim(trace.entity) == victim then
				point = trace.point
				surface = trace.normal
				part = trace.entity.ragdoll_part and trace.entity.ragdoll_part.Group
			end

			if target then
				local aimed

				if target.Part then
					local ragdoll_part = victim.ragdoll and victim.ragdoll:FindPart(target.Part)

					if ragdoll_part then
						local to_part = ragdoll_part.body:GetPosition() - center
						aimed = damage.Sweep(center, to_part + to_part:GetNormalized() * 0.5, holder)
					end
				else
					aimed = damage.Sweep(target.Origin, target.Direction * (range + 1), holder)
				end

				if
					aimed and
					aimed.entity and
					aimed.entity.ragdoll_part and
					damage.GetVictim(aimed.entity) == victim
				then
					point = aimed.point
					surface = aimed.normal
					part = aimed.entity.ragdoll_part.Group
				end
			end

			local info = {
				Attacker = holder,
				Inflictor = inflictor,
				Damage = amount,
				Type = type_name,
				Attributes = attributes,
				Position = point,
				Normal = normal,
				Force = cut * 5 * scale,
				Part = part,
				Direction = cut,
			}
			damage.Deal(victim, info)

			if surface then
				effects.Impact(
					point,
					surface,
					attributes[1] or type_name,
					scale,
					cut,
					(
						cut + surface * SPRAY_TILT + Vec3(
							math.randomf(-SPRAY_JITTER, SPRAY_JITTER),
							math.randomf(-SPRAY_JITTER, SPRAY_JITTER),
							math.randomf(-SPRAY_JITTER, SPRAY_JITTER)
						)
					):GetNormalized(),
					amount
				)
			else
				effects.Impact(point, normal, attributes[1] or type_name, scale, cut, nil, amount)
			end

			hits[#hits + 1] = {
				victim = victim,
				point = point,
				normal = normal,
				part = part,
				block = info.Block,
			}
			hit_any = true
		end
	end

	local hit_world = slash.StrikeWorld(holder, forward, cut, range, type_name, attributes, scale, amount)

	if hit_world then hit_any = true end

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
			body:ApplyImpulse(forward * PROP_IMPULSE * scale / body.InverseMass ^ 0.5, body:GetPosition())
			hit_any = true

			if #attributes == 0 then effects.HitOverlay(owner, type_name) end

			for _, name in ipairs(attributes) do
				effects.HitOverlay(owner, name)
			end
		end
	end

	return hit_any,
	cut,
	hits,
	stab and forward * -1 or plane_normal:GetNormalized(),
	hit_world
end

return slash
