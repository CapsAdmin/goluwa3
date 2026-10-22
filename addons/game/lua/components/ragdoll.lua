local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Entity = import("goluwa/entities/entity.lua")
local constraints = import("goluwa/physics/constraints.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local biped_pose = import("lua/biped_pose.lua")
local RagdollPart = import("lua/components/ragdoll_part.lua")
local aim_pose = import("lua/aim_pose.lua")
local META = objects.CreateTemplate("ragdoll")
-- an empty Network table is what makes the component part of the spawn packet
META.Network = {}
META:StartStorable()
META:GetSet("CorpseTime", 0)
META:EndStorable()
local PART_FRICTION = 0.8
local PART_BONES = {}

for _, definition in ipairs(biped.Parts) do
	PART_BONES[definition.Bone] = true
end

local PART_LINEAR_DAMPING = 0.1
local PART_ANGULAR_DAMPING = 1
local PART_ROLLING_FRICTION = 6
local PART_MAX_SPEED = 40
local JOINT_FRICTION = 0.6
local RELEASE_JITTER = 0.4
local RELEASE_SPIN = 1.5
local local_center = Vec3()
local world_offset = Vec3()
local local_rotation = Quat()
local world_rotation = Quat()
local part_matrix = Matrix44()

function META:Initialize()
	if self.initialized then return end

	self.initialized = true
	self.bones = {}
	self.parts = {}
	self.part_by_name = {}
	self.joints = {}
	self.released = false
	self.dead_time = 0
	self.walking = nil
	self:AddGlobalEvent("PhysicsUpdate")
end

function META:ComputePose()
	local owner = self.Owner
	local pose = owner.character_pose
	local driver = pose.driver
	local animator = driver and driver.Owner.animator
	local rig = animator and animator:GetRig()

	if rig then
		for name, source in pairs(biped.SourceBones) do
			self.bones[name] = rig:GetBone(source)
		end

		if not self.frames then self:BuildFrames() end

		return
	end

	local holder = owner.weapon_holder
	local active = holder and holder:GetActiveWeapon()
	biped_pose.Compute(
		self.bones,
		owner.character_movement:GetHeight(),
		pose.crouch_alpha,
		pose,
		active ~= nil,
		active ~= nil and active.weapon:IsTwoHanded()
	)
end

-- a part is fixed to its bone: where the segment sits in the bone's own frame never changes, so the part follows the animation
-- and the bone follows the part without sampling anything at the moment of death
function META:BuildFrames()
	local frames = {}

	for _, definition in ipairs(biped.Parts) do
		local bone = self.bones[definition.Bone]
		local from, to = self.bones[definition.From], self.bones[definition.To]
		local offset = definition.ToOffset
		local dx, dy, dz = to.m30 - from.m30, to.m31 - from.m31, to.m32 - from.m32

		if offset then dx, dy, dz = dx + offset.x, dy + offset.y, dz + offset.z end

		local inverse = bone:GetRotation():GetConjugated()
		local direction = inverse:VecMul(Vec3(dx, dy, dz))
		local center = inverse:VecMul(Vec3(from.m30 - bone.m30 + dx * 0.5, from.m31 - bone.m31 + dy * 0.5, from.m32 - bone.m32 + dz * 0.5))
		local rotation = Quat()
		aim_pose.SetBetween(rotation, 0, 1, 0, direction.x, direction.y, direction.z)
		frames[definition.Name] = {rotation = rotation, center = center}
	end

	self.frames = frames
end

function META:GetPartTarget(definition)
	local frame = self.frames and self.frames[definition.Name]

	if frame then
		local bone = self.bones[definition.Bone]
		local bone_rotation = bone:GetRotation()
		Quat.SetVecMul(local_center, bone_rotation, frame.center)
		local_center:Set(local_center.x + bone.m30, local_center.y + bone.m31, local_center.z + bone.m32)
		Quat.SetMul(local_rotation, bone_rotation, frame.rotation)
	else
		local bones = self.bones
		local from, to = bones[definition.From], bones[definition.To]
		local offset = definition.ToOffset
		local dx, dy, dz = to.m30 - from.m30, to.m31 - from.m31, to.m32 - from.m32

		if offset then dx, dy, dz = dx + offset.x, dy + offset.y, dz + offset.z end

		local_center:Set(from.m30 + dx * 0.5, from.m31 + dy * 0.5, from.m32 + dz * 0.5)
		aim_pose.SetBetween(local_rotation, 0, 1, 0, dx, dy, dz)
	end

	local transform = self.Owner.transform
	local rotation = transform:GetRotation()
	Quat.SetVecMul(world_offset, rotation, local_center)
	Quat.SetMul(world_rotation, rotation, local_rotation)
	local position = transform:GetPosition()
	world_offset:Set(world_offset.x + position.x, world_offset.y + position.y, world_offset.z + position.z)
	return world_offset, world_rotation
end

function META:DrivePart(part, teleport)
	local position, rotation = self:GetPartTarget(part.definition)
	local transform = part.entity.transform
	transform:SetPosition(position:Copy())
	transform:SetRotation(rotation:Copy())

	if teleport then
		local body = part.body
		body.Position:CopyFrom(position)
		body.Rotation:CopyFrom(rotation)
		body.PreviousPosition:CopyFrom(position)
		body.PreviousRotation:CopyFrom(rotation)
		body.Velocity:Set(0, 0, 0)
		body.AngularVelocity:Set(0, 0, 0)
	end
end

function META:Build()
	local owner = self.Owner
	local height = owner.character_movement:GetHeight()
	self:ComputePose()

	for _, definition in ipairs(biped.Parts) do
		local from, to = biped.Rest[definition.From], biped.Rest[definition.To]
		local offset = definition.ToOffset or Vec3()
		local length = Vec3(
			(to[1] - from[1]) * height + offset.x,
			(to[2] - from[2]) * height + offset.y,
			(to[3] - from[3]) * height + offset.z
		):GetLength()
		local position, rotation = self:GetPartTarget(definition)
		local entity = Entity.New{
			Name = "ragdoll_" .. definition.Name,
			transform = {Position = position:Copy(), Rotation = rotation:Copy()},
			rigid_body = {
				Shape = CapsuleShape.New(definition.Radius, length + definition.Radius * 2),
				MotionType = "kinematic",
				Mass = definition.Mass,
				AutomaticMass = false,
				Friction = PART_FRICTION,
				LinearDamping = PART_LINEAR_DAMPING,
				AngularDamping = PART_ANGULAR_DAMPING,
				CollisionMask = 0,
			},
			ragdoll_part = {Group = definition.Name, Multiplier = definition.Multiplier},
		}
		entity.ragdoll_part.Character = owner
		local part = {definition = definition, entity = entity, body = entity.rigid_body}
		part.body.TraceOwner = owner
		self.parts[#self.parts + 1] = part
		self.part_by_name[definition.Name] = part
	end

	local capsule = owner.rigid_body

	for i, part in ipairs(self.parts) do
		capsule:IgnoreCollisionWith(part.body)

		for j = i + 1, #self.parts do
			part.body:IgnoreCollisionWith(self.parts[j].body)
		end

		self:DrivePart(part, true)
	end
end

function META:SetPartsCollidable(collidable)
	for _, part in ipairs(self.parts) do
		part.body:SetCollisionEnabled(collidable)
	end
end

function META:BuildJoints()
	local rotation = self.Owner.transform:GetRotation()
	local joints = self.joints
	local axis = Vec3()

	for _, definition in ipairs(biped.Joints) do
		local parent, child = self.part_by_name[definition.Parent], self.part_by_name[definition.Child]
		local bone = self.bones[definition.Anchor]
		local anchor = self.Owner.transform:GetPosition() + rotation:VecMul(Vec3(bone.m30, bone.m31, bone.m32))
		local joint

		if definition.Hinge then
			joint = constraints.Hinge(
				parent.body,
				child.body,
				anchor,
				rotation:VecMul(Vec3(1, 0, 0)),
				{LowerAngle = definition.Hinge[1], UpperAngle = definition.Hinge[2], Friction = JOINT_FRICTION}
			)
		else
			local from, to = self.bones[child.definition.From], self.bones[child.definition.To]
			local offset = child.definition.ToOffset or Vec3()
			axis = rotation:VecMul(Vec3(to.m30 - from.m30 + offset.x, to.m31 - from.m31 + offset.y, to.m32 - from.m32 + offset.z)):GetNormalized()
			joint = constraints.Ragdoll(
				parent.body,
				child.body,
				anchor,
				axis,
				{
					TwistMin = -definition.Twist,
					TwistMax = definition.Twist,
					SwingYMin = -definition.Swing,
					SwingYMax = definition.Swing,
					SwingZMin = -definition.Swing,
					SwingZMax = definition.Swing,
					TwistFriction = JOINT_FRICTION,
					SwingFriction = JOINT_FRICTION,
				}
			)
		end

		joints[#joints + 1] = joint
	end
end

function META:Capture()
	if not self.parts[1] then return end

	for _, joint in ipairs(self.joints) do
		joint:Remove()
	end

	self.joints = {}
	self.released = false
	self.dead_time = 0
	self:ComputePose()

	for _, part in ipairs(self.parts) do
		if part.entity.network then part.entity:RemoveComponent("network") end
	end

	for _, part in ipairs(self.parts) do
		local body = part.body
		body:SetMotionType("kinematic")
		body:SetCollisionMask(0)
		self:DrivePart(part, true)
	end

	self:ClearRig()
end

function META:Release()
	if self.released then return end

	if not self.parts[1] then self:Build() end

	self:ComputePose()
	local velocity = self.Owner.rigid_body:GetVelocity()

	for _, part in ipairs(self.parts) do
		self:DrivePart(part, true)
	end

	self:BuildJoints()

	for _, part in ipairs(self.parts) do
		local body = part.body
		body:SetCollisionEnabled(true)
		body:SetCollisionMask(-1)
		body:SetCCD(true)
		body:SetMaxLinearSpeed(PART_MAX_SPEED)
		body:SetFrictionCombineMode("max")
		body:SetRollingFriction(PART_ROLLING_FRICTION)
		body:SetRollingFrictionCombineMode("max")
		body:SetMotionType("dynamic")
		body:SetVelocity(
			Vec3(
				velocity.x + math.randomf(-RELEASE_JITTER, RELEASE_JITTER),
				velocity.y,
				velocity.z + math.randomf(-RELEASE_JITTER, RELEASE_JITTER)
			)
		)
		body:SetAngularVelocity(Vec3(math.randomf(-RELEASE_SPIN, RELEASE_SPIN), 0, math.randomf(-RELEASE_SPIN, RELEASE_SPIN)))
		body:Wake()
	end

	self.released = true
	local character_id = self.Owner.network and self.Owner.network.NetworkId or -1

	if character_id ~= -1 then
		for _, part in ipairs(self.parts) do
			part.entity.ragdoll_part:SetCharacterId(character_id)
			part.entity:AddComponent("network")
		end
	end
end

function META:OnDeath()
	if network.HasAuthority() then self:Release() end
end

function META:OnCharacterReset()
	if network.HasAuthority() then self:Capture() end
end

function META:FollowHead()
	local owner = self.Owner
	local head = self.part_by_name.head.body
	local rotation = head.Rotation
	local view = owner.character_movement:GetViewOffset()
	Quat.SetVecMul(world_offset, rotation, view)
	owner.transform:SetPosition(Vec3(head.Position.x - world_offset.x, head.Position.y - world_offset.y, head.Position.z - world_offset.z))
	owner.transform:SetRotation(rotation:Copy())
end

function META:OnPhysicsUpdate(dt)
	if not network.HasAuthority() then return end

	local owner = self.Owner
	local movement = owner.character_movement

	if not movement or not owner.rigid_body then return end

	if not self.parts[1] then self:Build() end

	if self.released then
		self:FollowHead()

		if self.CorpseTime > 0 then
			self.dead_time = self.dead_time + dt

			if self.dead_time >= self.CorpseTime then owner:Remove() end
		end

		return
	end

	local walking = movement.mode == "walk"

	if walking ~= self.walking then
		self.walking = walking
		self:SetPartsCollidable(walking)
	end

	if not walking then return end

	self:ComputePose()

	for _, part in ipairs(self.parts) do
		self:DrivePart(part)
	end
end

function META:IsReleased()
	if self.released then return true end

	if network.HasAuthority() then return false end

	local owner = self.Owner

	if not owner.health:IsDead() or not owner.network then
		self:DropReplicatedParts()
		return false
	end

	if self.replicated then return true end

	local by_group = {}

	for _, component in ipairs(RagdollPart.Instances or {}) do
		if component.CharacterId == owner.network.NetworkId then
			by_group[component.Group] = component.Owner
		end
	end

	local parts = {}

	for _, definition in ipairs(biped.Parts) do
		local entity = by_group[definition.Name]

		if not entity then return false end

		parts[#parts + 1] = {definition = definition, entity = entity}
	end

	self.parts = parts
	self.replicated = true
	return true
end

function META:DropReplicatedParts()
	if not self.replicated then return end

	self.replicated = false
	self.parts = {}
	self:ClearRig()
end

function META:ClearRig()
	local rig = self.driven_rig

	if rig then
		for _, name in ipairs(aim_pose.Bones) do
			rig:ClearBone(biped.SourceBones[name])
		end

		for _, part in ipairs(biped.Parts) do
			rig:ClearBone(biped.SourceBones[part.Bone])
		end
	end

	self.driven_rig = nil
end

function META:DriveRig(rig)
	local owner_transform = self.Owner.transform
	local entity_position, entity_rotation = owner_transform:GetRenderPositionRotation()
	entity_position = entity_position or owner_transform:GetPosition()
	entity_rotation = entity_rotation or owner_transform:GetRotation()
	local inverse = entity_rotation:GetConjugated()

	if not self.frames then
		for name, source in pairs(biped.SourceBones) do
			self.bones[name] = rig:GetBone(source)
		end

		self:BuildFrames()
	end

	for _, part in ipairs(self.parts) do
		local transform = part.entity.transform
		local position, rotation = transform:GetRenderPositionRotation()
		position = position or transform:GetPosition()
		rotation = rotation or transform:GetRotation()
		local frame = self.frames[part.definition.Name]
		local bone_rotation = inverse * rotation * frame.rotation:GetConjugated()
		local local_position = inverse:VecMul(position - entity_position) - bone_rotation:VecMul(frame.center)
		part_matrix:Identity()
		part_matrix:SetRotation(bone_rotation)
		part_matrix:SetTranslation(local_position.x, local_position.y, local_position.z)
		rig:SetBone(biped.SourceBones[part.definition.Bone], part_matrix, "model")
	end

	if not self.driven_rig then
		for _, name in ipairs(aim_pose.Bones) do
			if not PART_BONES[name] then rig:ClearBone(biped.SourceBones[name]) end
		end
	end

	rig:Compute()
	self.driven_rig = rig
end

function META:OnRemove()
	for _, joint in ipairs(self.joints) do
		joint:Remove()
	end

	for _, part in ipairs(self.parts) do
		if part.entity:IsValid() then part.entity:Remove() end
	end
end

return META:Register()
