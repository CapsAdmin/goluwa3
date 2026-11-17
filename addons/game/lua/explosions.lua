local Vec3 = import("goluwa/structs/vec3.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/actors.lua")
local explosions = {}
local UP = Vec3(0, 1, 0)
local COVER_SCALE = 0.3

local function get_falloff(distance, radius)
	return math.clamp(1 - distance / radius, 0, 1) ^ 1.5
end

function explosions.FindGround(position, ignore)
	local ground = damage.Sweep(position + Vec3(0, 0.3, 0), Vec3(0, -1.5, 0), ignore)

	if ground then return ground.point + ground.normal * 0.05, ground.normal end

	return position, UP
end

function explosions.Blast(info)
	local position = info.Position
	local radius = info.Radius
	local impulse = info.Impulse
	local inflictor = info.Inflictor
	local origin = position + Vec3(0, 0.1, 0)

	for _, entity in ipairs(actors.Find(position, radius)) do
		local center = actors.GetCenter(entity)
		local offset = center - origin
		local distance = offset:GetLength()
		local falloff = get_falloff(distance, radius)
		local direction = distance > 1e-3 and offset / distance or UP
		local cover = distance > 1e-3 and damage.Sweep(origin, offset, inflictor)

		if cover and cover.entity and damage.GetVictim(cover.entity) ~= entity then
			falloff = falloff * COVER_SCALE
		end

		if falloff > 0 then
			damage.Deal(
				entity,
				{
					Attacker = info.Attacker,
					Inflictor = inflictor,
					Damage = info.Damage * falloff,
					Type = info.Type or "magic",
					Attributes = info.Attributes or {"fire"},
					Position = position,
					Normal = -direction,
					Force = direction * impulse * falloff,
				}
			)
		end
	end

	local own_body = inflictor and inflictor.rigid_body

	for _, other in ipairs(RigidBody.Instances) do
		if other ~= own_body and other:IsDynamic() and not other.Owner.health then
			local offset = other:GetPosition() - origin
			local distance = offset:GetLength()
			local falloff = get_falloff(distance, radius)

			if falloff > 0 and distance > 1e-3 then
				other:ApplyImpulse(offset / distance * impulse * falloff * other:GetMass(), other:GetPosition())
			end
		end
	end
end

return explosions
