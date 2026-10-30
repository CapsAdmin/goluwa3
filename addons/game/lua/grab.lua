local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local keyframes = import("lua/keyframes.lua")
local actors = import("lua/actors.lua")
local grab = {}
local LATCH = {}
LATCH.__index = LATCH

function LATCH:GetRenderFrame(position, rotation)
	local grabber = self.Grabber
	local def = self.Def

	if def then
		local anims = grabber.character_pose.anims

		for i = 1, #anims do
			if anims[i].def == def then
				keyframes.EvaluateCarry(
					def,
					math.min(anims[i].phase, self.PhaseLimit),
					self.Bones,
					self.Offset,
					self.Rotation
				)

				break
			end
		end
	end

	local transform = grabber.transform
	local base_position = transform.OverridePosition or transform:GetPosition()
	local base_rotation = transform.OverrideRotation or transform:GetRotation()
	local offset = base_rotation:VecMul(self.Offset)
	position:Set(base_position.x + offset.x, base_position.y + offset.y, base_position.z + offset.z)
	Quat.SetMul(rotation, base_rotation, self.Rotation)
	return position, rotation
end

do
	local rotation = Quat()

	function LATCH:Step(position)
		self:GetRenderFrame(position, rotation)
		return rotation
	end
end

do
	local local_velocity = Vec3()

	function LATCH:GetVelocity(phase, duration)
		local grabber = self.Grabber
		local transform = grabber.transform
		keyframes.EvaluateVictimVelocity(self.Def, phase, duration, self.Bones, local_velocity)
		local base_rotation = transform.OverrideRotation or transform:GetRotation()
		return base_rotation:VecMul(local_velocity) + grabber.rigid_body:GetVelocity()
	end
end

function LATCH:IsHolding()
	return self.Grabber:IsValid() and actors.IsAlive(self.Grabber)
end

local PUPPET = {}
PUPPET.__index = PUPPET

function PUPPET:IsHolding()
	return true
end

function PUPPET:Step(position)
	position:Set(self.Position.x, self.Position.y, self.Position.z)
	return self.Rotation
end

function grab.Puppet(character)
	local puppet = setmetatable(
		{
			Grabber = character,
			Victim = character,
			Position = Vec3(),
			Rotation = Quat(0, 0, 0, 1),
		},
		PUPPET
	)
	character.character_movement.latch = puppet
	return puppet
end

function grab.Unpuppet(character)
	character.character_movement:Unlatch()
end

function grab.Latch(grabber, victim, options)
	local movement = victim.character_movement
	local grabber_pose = grabber.character_pose

	if movement.latch or grabber_pose.grab_latch then return end

	local latch = setmetatable(
		{
			Grabber = grabber,
			Victim = victim,
			Def = options.Def,
			Bones = options.Bones,
			PhaseLimit = options.PhaseLimit or 1,
			Offset = options.Offset or Vec3(),
			Rotation = options.Rotation or Quat(0, 0, 0, 1),
		},
		LATCH
	)
	movement.latch = latch
	grabber_pose.grab_latch = latch
	victim.character_pose:SetState("held", "1")
	return latch
end

function grab.Get(victim)
	return victim.character_movement.latch
end

function grab.IsHeld(victim)
	return victim.character_movement.latch ~= nil
end

function grab.Detach(victim)
	local movement = victim.character_movement
	local grabber = movement.latch.Grabber

	if grabber:IsValid() then grabber.character_pose.grab_latch = nil end

	victim.character_pose:SetState("held", nil)
	movement:Unlatch()
end

function grab.Release(victim, velocity)
	grab.Detach(victim)

	if victim.ragdoll then
		victim.ragdoll:Knockdown(velocity)
	else
		victim.rigid_body:SetVelocity(velocity)
	end
end

return grab
