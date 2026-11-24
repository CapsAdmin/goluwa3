local objects = import("goluwa/objects/objects.lua")
local timer = import("goluwa/timer.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("boid")
META.CorpseTime = 30
local DEATH_LIFT = 2
local DEATH_SPIN = 6
local CORPSE_FRICTION = 0.8

local function remove_entity(entity)
	entity:Remove()
end

function META:OnDeath(info)
	local entity = self.Owner
	self.dead = true

	if self.flock:GetDefinition().Sounds then self.flock:PlaySound(self, "Die") end

	entity.animator:SetPlaying(false)
	local body = entity.rigid_body
	body:SetMotionType("dynamic")
	body:SetCollisionMask(-1)
	body:SetCollideWorldOnly(true)
	body:SetFriction(CORPSE_FRICTION)
	body:SetFrictionCombineMode("max")
	body:SetVelocity(Vec3(self.hx * self.speed, DEATH_LIFT, self.hz * self.speed))
	body:SetAngularVelocity(
		Vec3(
			math.randomf(-DEATH_SPIN, DEATH_SPIN),
			math.randomf(-DEATH_SPIN, DEATH_SPIN),
			math.randomf(-DEATH_SPIN, DEATH_SPIN)
		)
	)

	if info.Force then body:ApplyImpulse(info.Force, info.Position) end

	timer.Delay(META.CorpseTime, remove_entity, nil, entity, entity)
end

return META:Register()
