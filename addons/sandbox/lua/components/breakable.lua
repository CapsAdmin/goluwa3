local objects = import("goluwa/objects/objects.lua")
local new_event = import("goluwa/network/replicated_event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local prop_data = import("goluwa/source_engine/prop_data.lua")
local damage = import("lua/damage.lua")
local props = import("lua/props.lua")
local sounds = import("lua/sounds.lua")
local META = objects.CreateTemplate("breakable")
META:StartStorable()
META:GetSet("Model", "")
META:GetSet("Offset", Vec3())
META:GetSet("Center", Vec3())
META:GetSet("Size", Vec3())
META:EndStorable()
local IMPACT_MIN_SPEED = 5
local IMPACT_DAMAGE = 0.04
local GIB_SPREAD = 1.5
local GIB_LIFT = 1
local GIB_LIFETIME = 5
local GIB_COLLISION_GROUP = 4
local GIB_COLLISION_MASK = bit.bnot(GIB_COLLISION_GROUP)
local play_break = new_event("breakable_break", function(model_path, position)
	local script = prop_data.Get(model_path).Sounds

	if script then
		sounds.PlayRandom(script.Waves, position, script.Volume, math.randomf(script.Pitch[1], script.Pitch[2]))
	end
end, function()
	return CLIENT
end)

function META:OnDeath(info)
	local owner = self.Owner
	local data = prop_data.Get(self.Model)
	local position = owner.transform:GetPosition()
	local rotation = owner.transform:GetRotation()
	local inherited = owner.rigid_body:GetVelocity():Copy()
	local push = info.Direction and info.Direction:GetNormalized() or Vec3()
	local models = data.Gibs
	local scattered = #models == 0
	play_break(self.Model, position)

	if scattered then
		models = {}

		for i = 1, data.Chunks and data.ChunkCount or 0 do
			models[i] = data.Chunks[math.random(#data.Chunks)]
		end
	end

	for _, gib in ipairs(models) do
		local at = position + rotation:VecMul(self.Offset)
		local gib_rotation = rotation

		if scattered then
			at = position + rotation:VecMul(
					self.Center + Vec3(
							math.randomf(-0.5, 0.5) * self.Size.x,
							math.randomf(-0.5, 0.5) * self.Size.y,
							math.randomf(-0.5, 0.5) * self.Size.z
						)
				)
			gib_rotation = Quat(math.randomf(-1, 1), math.randomf(-1, 1), math.randomf(-1, 1), math.randomf(-1, 1)):GetNormalized()
		end

		props.Spawn(
			gib,
			at,
			gib_rotation,
			function(entity)
				local body = entity.rigid_body
				body:SetCollisionGroup(GIB_COLLISION_GROUP)
				body:SetCollisionMask(GIB_COLLISION_MASK)
				body:SetVelocity(
					inherited + push * GIB_SPREAD + Vec3(
							math.randomf(-GIB_SPREAD, GIB_SPREAD),
							math.randomf(0, GIB_LIFT),
							math.randomf(-GIB_SPREAD, GIB_SPREAD)
						)
				)
			end,
			{Exact = true, Lifetime = GIB_LIFETIME, Gib = true}
		)
	end
end

local function hurt(victim, other, body, other_body, impact, normal)
	if not victim.breakable or victim.health:IsDead() then return end

	local mass = body.Mass
	local reduced = other_body:IsDynamic() and
		mass * other_body.Mass / (
			mass + other_body.Mass
		)
		or
		mass
	damage.Deal(
		victim,
		{
			Inflictor = other,
			Damage = IMPACT_DAMAGE * 0.5 * reduced * impact.speed * impact.speed,
			Type = "generic",
			Position = impact.position,
			Normal = normal,
			Direction = normal * -1,
		}
	)
end

event.AddListener("PhysicsImpact", "breakable_impact", function(impact)
	if not network.HasAuthority() or impact.speed < IMPACT_MIN_SPEED then return end

	local a, b = impact.entity_a, impact.entity_b
	hurt(a, b, impact.body_a, impact.body_b, impact, impact.normal * -1)
	hurt(b, a, impact.body_b, impact.body_a, impact, impact.normal)
end)

return META:Register()
