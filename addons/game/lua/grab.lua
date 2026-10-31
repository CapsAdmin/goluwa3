local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local system = import("goluwa/system.lua")
local physics = import("goluwa/physics.lua")
local keyframes = import("lua/keyframes.lua")
local actors = import("lua/actors.lua")
local grab = {}
local SWEEP_SHARE = 0.9

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

	function LATCH:GetWantedFrame(position, rotation, drawn)
		local grabber = self.Grabber
		local def = self.Def
		local weight = 1
		local base_position, base_rotation = grab.GetBaseFrame(grabber, drawn)

		if def then
			local phase = self.PhaseLimit
			local anims = grabber.character_pose.anims

			for i = 1, #anims do
				if anims[i].def == def then
					phase = math.min(anims[i].phase, self.PhaseLimit)

					break
				end
			end

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
	local SKIN = 0.02
	local SLIDES = 3
	local BLOCKED_SPEED = 3
	local BLOCKED_COOLDOWN = 0.25
	local UP = Vec3(0, 1, 0)
	local OPTIONS = {IgnoreRigidBodies = false}
	local rotation = Quat()
	local anchor = Vec3()
	local clear = Vec3()
	local move = Vec3()
	local up = Vec3()

	local function is_world(entity)
		local body = entity.rigid_body
		return body ~= nil and (body.WorldGeometry or body:IsStatic())
	end

	function LATCH:Slide(from, to, radius)
		local victim = self.Victim
		local blocked
		move:Set(to.x - from.x, to.y - from.y, to.z - from.z)

		for _ = 1, SLIDES do
			local length = move:GetLength()

			if length < 1e-5 then break end

			local hit = physics.Sweep(from, move, radius, victim, is_world, OPTIONS)

			if not hit then
				from:Set(from.x + move.x, from.y + move.y, from.z + move.z)

				break
			end

			local travel = math.max(hit.fraction * length - SKIN, 0) / length
			from:Set(from.x + move.x * travel, from.y + move.y * travel, from.z + move.z * travel)
			local rest = 1 - travel
			move:Set(move.x * rest, move.y * rest, move.z * rest)
			local normal = hit.normal
			local into = move.x * normal.x + move.y * normal.y + move.z * normal.z

			if into < 0 then
				move:Set(move.x - normal.x * into, move.y - normal.y * into, move.z - normal.z * into)

				if not blocked or -into > blocked.depth then
					blocked = blocked or {}
					blocked.depth = -into
					blocked.point = hit.point or hit.position
					blocked.normal = normal
				end
			end
		end

		return blocked
	end

	function LATCH:KeepEnd(from, direction, extent, radius)
		local hit = physics.RayCast(from, direction, extent, self.Victim, is_world, OPTIONS)

		if not hit then return end

		local depth = extent - hit.distance
		local push = Vec3(-direction.x * depth, -direction.y * depth, -direction.z * depth)
		self:Slide(from, from + push, radius)
	end

	function LATCH:Constrain(position, rotation, origin)
		anchor:CopyFrom(position + rotation:VecMul(self.Anchor))
		clear:CopyFrom(origin)
		local radius = self.Radius
		local blocked = self:Slide(clear, anchor, radius)
		up:CopyFrom(rotation:VecMul(UP))
		self:KeepEnd(clear, up * -1, self.Anchor.y, radius)
		self:KeepEnd(clear, up, self.Height - self.Anchor.y, radius)
		position:Set(
			position.x + clear.x - anchor.x,
			position.y + clear.y - anchor.y,
			position.z + clear.z - anchor.z
		)
		return blocked
	end

	function LATCH:Step(position, dt)
		self:GetWantedFrame(position, rotation)
		local blocked = self:Constrain(position, rotation, actors.GetCenter(self.Grabber))
		self.blocked_cooldown = math.max(self.blocked_cooldown - dt, 0)

		if blocked and self.blocked_cooldown <= 0 then
			local speed = blocked.depth / dt

			if speed >= BLOCKED_SPEED then
				self.blocked_cooldown = BLOCKED_COOLDOWN
				self.Grabber:CallLocalEvent("OnLatchBlocked", self, blocked.point, blocked.normal, speed)
			end
		end

		return rotation
	end

	local center = Vec3()

	function LATCH:GetRenderFrame(position, rotation)
		local frame = system.GetFrameNumber()

		if self.drawn_frame ~= frame then
			self.drawn_frame = frame
			local grabber = self.Grabber
			local drawn = self.DrawnPosition
			self:GetWantedFrame(drawn, self.DrawnRotation, true)
			local base = grab.GetBaseFrame(grabber, true)
			local physical = grabber.transform:GetPosition()
			local body = actors.GetCenter(grabber)
			center:Set(
				base.x + body.x - physical.x,
				base.y + body.y - physical.y,
				base.z + body.z - physical.z
			)
			self:Constrain(drawn, self.DrawnRotation, center)
		end

		local drawn, turned = self.DrawnPosition, self.DrawnRotation
		position:Set(drawn.x, drawn.y, drawn.z)
		rotation:Set(turned.x, turned.y, turned.z, turned.w)
		return position, rotation
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
			Radius = math.min(movement.Radius, grabber.character_movement.Radius) * SWEEP_SHARE,
			Height = movement:GetHeight(),
			DrawnPosition = Vec3(),
			DrawnRotation = Quat(),
			blocked_cooldown = 0,
		},
		LATCH
	)
	local names = latch.Def and latch.Def.CarryBones
	local bones = latch.Bones

	if names then
		local right, left = bones[names[1]], bones[names[2]]
		latch.Anchor = Vec3((right.m30 + left.m30) / 2, (right.m31 + left.m31) / 2, (right.m32 + left.m32) / 2)
	else
		latch.Anchor = Vec3(0, actors.GetCenter(victim).y - victim.transform:GetPosition().y, 0)
	end

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
