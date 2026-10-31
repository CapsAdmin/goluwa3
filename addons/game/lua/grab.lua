local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local keyframes = import("lua/keyframes.lua")
local actors = import("lua/actors.lua")
local grab = {}

function grab.GetBaseFrame(grabber, drawn)
	local transform = grabber.transform
	local position, rotation

	if drawn then position, rotation = transform:GetRenderPositionRotation() end

	return transform.OverridePosition or position or transform:GetPosition(),
	transform.OverrideRotation or rotation or transform:GetRotation()
end

local LATCH = {}
LATCH.__index = LATCH

do
	local blended = Quat()
	local inverse = Quat()
	local blade = Vec3()

	local function get_node_position(weapon, name)
		local m = weapon.prefab:GetNode(name).transform:GetWorldMatrix()
		return m.m30, m.m31, m.m32
	end

	function LATCH:GetRenderFrame(position, rotation, physics)
		local grabber = self.Grabber
		local def = self.Def
		local weight = 1
		local base_position, base_rotation = grab.GetBaseFrame(grabber, not physics)

		if def then
			local anims = grabber.character_pose.anims

			for i = 1, #anims do
				if anims[i].def == def then
					local phase = math.min(anims[i].phase, self.PhaseLimit)
					local _, _, target = keyframes.EvaluateCarry(def, phase, self.Bones, self.Offset, self.Rotation)
					weight = keyframes.EvaluateAttach(def, phase)
					local impale, along = keyframes.EvaluateImpale(def, phase)

					if impale > 0.001 and self.Weapon and self.Weapon:IsValid() then
						local bx, by, bz = get_node_position(self.Weapon, "blade_base")
						local tx, ty, tz = get_node_position(self.Weapon, "blade_tip")
						blade:Set(
							bx + (tx - bx) * along - base_position.x,
							by + (ty - by) * along - base_position.y,
							bz + (tz - bz) * along - base_position.z
						)
						inverse:SetConjugated(base_rotation)
						blade:CopyFrom(inverse:VecMul(blade))
						self.Offset:Set(
							self.Offset.x + (blade.x - target.x) * impale,
							self.Offset.y + (blade.y - target.y) * impale,
							self.Offset.z + (blade.z - target.z) * impale
						)
					end

					break
				end
			end
		end

		local offset = base_rotation:VecMul(self.Offset)
		position:Set(base_position.x + offset.x, base_position.y + offset.y, base_position.z + offset.z)
		Quat.SetMul(rotation, base_rotation, self.Rotation)

		if weight < 1 then
			local home_position, home_rotation = self.HomePosition, self.HomeRotation
			position:Set(
				home_position.x + (position.x - home_position.x) * weight,
				home_position.y + (position.y - home_position.y) * weight,
				home_position.z + (position.z - home_position.z) * weight
			)
			local sign = home_rotation:Dot(rotation) < 0 and -1 or 1
			blended:Set(
				home_rotation.x + (rotation.x * sign - home_rotation.x) * weight,
				home_rotation.y + (rotation.y * sign - home_rotation.y) * weight,
				home_rotation.z + (rotation.z * sign - home_rotation.z) * weight,
				home_rotation.w + (rotation.w * sign - home_rotation.w) * weight
			)
			blended:Normalize()
			rotation:Set(blended.x, blended.y, blended.z, blended.w)
		end

		return position, rotation
	end
end

do
	local frame_position, frame_rotation = Vec3(), Quat()
	local inverse = Quat()
	local point = Vec3()

	function LATCH:GetBoneTarget(bone, out)
		self:GetRenderFrame(frame_position, frame_rotation)
		local base_position, base_rotation = grab.GetBaseFrame(self.Grabber, true)
		point:Set(bone.m30, bone.m31, bone.m32)
		local world = frame_position + frame_rotation:VecMul(point) - base_position
		inverse:SetConjugated(base_rotation)
		return out:CopyFrom(inverse:VecMul(world))
	end
end

do
	local rotation = Quat()

	function LATCH:Step(position)
		self:GetRenderFrame(position, rotation, true)
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

function grab.GetCarryBones(victim, names)
	local bones = victim.source_pose and victim.source_pose.bones

	if bones and bones[names[1]] and bones[names[2]] then return bones end

	local height = actors.GetCenter(victim).y - victim.transform:GetPosition().y
	local center = {m30 = 0, m31 = height, m32 = 0}
	return {[names[1]] = center, [names[2]] = center}
end

local function snapshot_bones(bones, names)
	local copy = {}

	for _, name in ipairs(names) do
		local bone = bones[name]
		copy[name] = {m30 = bone.m30, m31 = bone.m31, m32 = bone.m32}
	end

	return copy
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
			Bones = options.Def and
				options.Def.CarryBones and
				snapshot_bones(options.Bones, options.Def.CarryBones) or
				options.Bones,
			Weapon = options.Weapon,
			PhaseLimit = options.PhaseLimit or 1,
			Offset = options.Offset or Vec3(),
			Rotation = options.Rotation or Quat(0, 0, 0, 1),
			HomePosition = victim.transform:GetPosition():Copy(),
			HomeRotation = victim.transform:GetRotation():Copy(),
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
	victim.character_movement:IgnoreImpacts()

	if victim.ragdoll then
		victim.ragdoll:Knockdown(velocity)
	else
		victim.rigid_body:SetVelocity(velocity)
	end
end

return grab
