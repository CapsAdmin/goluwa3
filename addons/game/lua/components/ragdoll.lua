local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local constraints = import("goluwa/physics/constraints.lua")
local physics = import("goluwa/physics.lua")
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
META.Network = {Limp = {"boolean", 0.1, "reliable"}}
META:IsSet("Limp", false)
META:StartStorable()
META:GetSet("CorpseTime", 0)
META:GetSet("Profile", "humanoid")
META:EndStorable()
local PART_FRICTION = 0.8
local POSE_GAIN = 10
local POSE_RATE = 180
local ROOT_LIMP = 0.3
local ENTER_LIMP = 0.02
local EXIT_DISTANCE = 0.06
local EXIT_ANGLE = 0.2
local EXIT_FORCE_TIME = 1.5
local HOLD_LIMP = 0.8
local SETTLE_LIMP = 0.92
local HOLD_RATE = 4
local BLEND_TIME = 0.6
local SETTLE_MIN_TIME = 1
local SETTLE_MAX_TIME = 8
local SETTLE_SPEED = 0.35
local SETTLE_SPIN = 2
local NETWORK_LINGER = 1
local GROUND_PROBE = 4
local STAND_HEIGHT = 0.05
local PART_LINEAR_DAMPING = 0.1
local PART_ANGULAR_DAMPING = 1
local PART_ROLLING_FRICTION = 6
local PART_MAX_SPEED = 40
local JOINT_FRICTION = 0.6
local RELEASE_JITTER = 0.4
local RELEASE_SPIN = 1.5
local UP = Vec3(0, 1, 0)
local local_center = Vec3()
local world_offset = Vec3()
local local_rotation = Quat()
local world_rotation = Quat()
local part_matrix = Matrix44()
local blend_position = Vec3()

function META:Initialize()
	if self.initialized then return end

	self.initialized = true
	self.bones = {}
	self.parts = {}
	self.part_by_name = {}
	self.total_mass = 0
	self.sources = {}
	self.impulses = {}
	self.held = {}
	self.grabs = 0
	self.dynamic_count = 0
	self.global_active = false
	self.previous_velocities = {}
	self.dead_time = 0
	self.time = 0
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
		if next(driver.bones) then
			self.bones = driver.bones
		else
			for name, source in pairs(biped.SourceBones) do
				self.bones[name] = rig:GetBone(source)
			end
		end

		if not self.frames then self:BuildFrames() end

		return
	end

	if self.Profile == "eye" then
		self.bones = owner.procedural_pose:GetPoseBones()
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
	local profile = biped.Profiles[self.Profile]
	local part_bones = {}
	local owner_of = {}

	for _, definition in ipairs(profile.Parts) do
		part_bones[definition.Bone] = true
		owner_of[definition.Bone] = definition.Name
		local bone = self.bones[definition.Bone]
		local from, to = self.bones[definition.From], self.bones[definition.To]
		local offset = definition.ToOffset
		local dx, dy, dz = to.m30 - from.m30, to.m31 - from.m31, to.m32 - from.m32

		if offset then dx, dy, dz = dx + offset.x, dy + offset.y, dz + offset.z end

		local inverse = bone:GetRotation():GetConjugated()
		local direction = inverse:VecMul(Vec3(dx, dy, dz))
		local center = inverse:VecMul(
			Vec3(
				from.m30 - bone.m30 + dx * 0.5,
				from.m31 - bone.m31 + dy * 0.5,
				from.m32 - bone.m32 + dz * 0.5
			)
		)
		local rotation = Quat()
		aim_pose.SetBetween(rotation, 0, 1, 0, direction.x, direction.y, direction.z)
		frames[definition.Name] = {rotation = rotation, center = center}
	end

	local attached = {}

	for _, entry in ipairs(biped.Bones) do
		local name = entry[1]
		local parent = profile.Attach and profile.Attach[name] or entry[2]

		if not part_bones[name] and parent and self.bones[name] and self.bones[parent] then
			attached[#attached + 1] = {
				name = name,
				parent = parent,
				matrix = self.bones[name]:GetMultiplied(self.bones[parent]:GetInverse()),
			}
			owner_of[name] = owner_of[parent]
		end
	end

	self.attached = attached
	self.part_bones = part_bones
	self.owner_of = owner_of
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

-- the pose targets of every part in the world, and how fast the pose moves
function META:UpdateTargets(dt)
	self:ComputePose()

	for _, part in ipairs(self.parts) do
		local position, rotation = self:GetPartTarget(part.definition)
		local last = part.last_target

		if last and dt > 0 then
			part.pose_velocity:Set((position.x - last.x) / dt, (position.y - last.y) / dt, (position.z - last.z) / dt)
		end

		part.target_position:Set(position.x, position.y, position.z)
		part.target_rotation:Set(rotation.x, rotation.y, rotation.z, rotation.w)
		part.last_target = last or Vec3()
		part.last_target:Set(position.x, position.y, position.z)
	end
end

function META:DrivePart(part, teleport, position, rotation)
	position = position or part.target_position
	rotation = rotation or part.target_rotation
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
	self:ComputePose()
	local profile = biped.Profiles[self.Profile]
	local joint_of = {}

	for _, definition in ipairs(profile.Joints) do
		joint_of[definition.Child] = definition
	end

	for _, definition in ipairs(profile.Parts) do
		local from, to = self.bones[definition.From], self.bones[definition.To]
		local offset = definition.ToOffset or Vec3()
		local length = Vec3(
			to.m30 - from.m30 + offset.x,
			to.m31 - from.m31 + offset.y,
			to.m32 - from.m32 + offset.z
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
		local joint_definition = joint_of[definition.Name]
		local part = {
			definition = definition,
			entity = entity,
			body = entity.rigid_body,
			half = length * 0.5,
			joint_definition = joint_definition,
			parent = joint_definition and self.part_by_name[joint_definition.Parent],
			children = {},
			limp = 0,
			dynamic = false,
			ignored = {},
			target_position = Vec3(),
			target_rotation = Quat(),
			pose_velocity = Vec3(),
		}
		part.body.TraceOwner = owner

		if part.parent then table.insert(part.parent.children, part) end

		self.parts[#self.parts + 1] = part
		self.total_mass = self.total_mass + definition.Mass
		self.part_by_name[definition.Name] = part
	end

	for _, part in ipairs(self.parts) do
		owner.rigid_body:IgnoreCollisionWith(part.body)
	end

	self:UpdateTargets(0)

	for _, part in ipairs(self.parts) do
		self:DrivePart(part, true)
	end
end

function META:SetPartsCollidable(collidable)
	for _, part in ipairs(self.parts) do
		if not part.dynamic then part.body:SetCollisionEnabled(collidable) end
	end
end

local function get_direction(self, definition)
	local from, to = self.bones[definition.From], self.bones[definition.To]
	local offset = definition.ToOffset or Vec3()
	return Vec3(
		to.m30 - from.m30 + offset.x,
		to.m31 - from.m31 + offset.y,
		to.m32 - from.m32 + offset.z
	)
end

local get_segment_distance

do
	local d1, d2, r = Vec3(), Vec3(), Vec3()

	function get_segment_distance(p1, axis_1, half_1, p2, axis_2, half_2)
		local ax, ay, az = axis_1.x * half_1, axis_1.y * half_1, axis_1.z * half_1
		local bx, by, bz = axis_2.x * half_2, axis_2.y * half_2, axis_2.z * half_2
		d1:Set(ax * 2, ay * 2, az * 2)
		d2:Set(bx * 2, by * 2, bz * 2)
		r:Set(p1.x - ax - (p2.x - bx), p1.y - ay - (p2.y - by), p1.z - az - (p2.z - bz))
		local a, e, f = d1:Dot(d1), d2:Dot(d2), d2:Dot(r)
		local c, b = d1:Dot(r), d1:Dot(d2)
		local denominator = a * e - b * b
		local s = denominator > 1e-9 and math.clamp((b * f - c * e) / denominator, 0, 1) or 0
		local t = (b * s + f) / e

		if t < 0 then
			t = 0
			s = math.clamp(-c / a, 0, 1)
		elseif t > 1 then
			t = 1
			s = math.clamp((b - c) / a, 0, 1)
		end

		local dx = r.x + d1.x * s - d2.x * t
		local dy = r.y + d1.y * s - d2.y * t
		local dz = r.z + d1.z * s - d2.z * t
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end
end

-- limits are measured from the pose a joint is built in, which is why a part that joins a parent that has moved off its pose
-- is placed where that parent now has it (attach_rotation turns what the pose says into what the parent does)
function META:BuildJoint(part, attach_rotation)
	local definition = part.joint_definition
	local parent = part.parent
	local owner_transform = self.Owner.transform
	local entity_rotation = owner_transform:GetRotation()
	local bone = self.bones[definition.Anchor]
	local anchor_pose = owner_transform:GetPosition() + entity_rotation:VecMul(Vec3(bone.m30, bone.m31, bone.m32))
	local anchor = parent.body.Position + attach_rotation:VecMul(anchor_pose - parent.target_position)

	if definition.Hinge then
		local a, b = get_direction(self, parent.definition), get_direction(self, part.definition)
		local bend = math.acos(math.clamp(a:Dot(b) / (a:GetLength() * b:GetLength()), -1, 1))
		local pose_angle = definition.Hinge[2] > 0 and bend or -bend
		return constraints.Hinge(
			parent.body,
			part.body,
			anchor,
			attach_rotation:VecMul(entity_rotation:VecMul(Vec3(1, 0, 0))),
			{
				LowerAngle = definition.Hinge[1] - pose_angle,
				UpperAngle = definition.Hinge[2] - pose_angle,
				Friction = JOINT_FRICTION,
			}
		)
	end

	return constraints.Ragdoll(
		parent.body,
		part.body,
		anchor,
		attach_rotation:VecMul(entity_rotation:VecMul(get_direction(self, part.definition))):GetNormalized(),
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

function META:MakeDynamic(part, keep_pose, jitter)
	local body = part.body
	local parent = part.parent

	if not keep_pose then
		if parent then
			local conjugate = parent.target_rotation:GetConjugated()
			self:DrivePart(
				part,
				true,
				parent.body.Position + parent.body.Rotation:VecMul(conjugate:VecMul(part.target_position - parent.target_position)),
				parent.body.Rotation * conjugate * part.target_rotation
			)
		else
			self:DrivePart(part, true)
		end
	end

	if parent then
		part.joint = self:BuildJoint(part, parent.body.Rotation * parent.target_rotation:GetConjugated())
		local axis = body.Rotation:VecMul(UP)

		for _, other in ipairs(self.parts) do
			if
				other ~= part and
				not (
					body.IgnoredBodies and
					body.IgnoredBodies[other.body]
				)
				and
				get_segment_distance(
					body.Position,
					axis,
					part.half,
					other.body.Position,
					other.body.Rotation:VecMul(UP),
					other.half
				) < part.definition.Radius + other.definition.Radius
			then
				body:IgnoreCollisionWith(other.body)
				part.ignored[#part.ignored + 1] = other.body
			end
		end
	end

	body:SetCollisionEnabled(true)
	body:SetCollisionMask(-1)
	body:SetCCD(true)
	body:SetMaxLinearSpeed(PART_MAX_SPEED)
	body:SetFrictionCombineMode("max")
	body:SetRollingFriction(PART_ROLLING_FRICTION)
	body:SetRollingFrictionCombineMode("max")
	body:SetMotionType("dynamic")
	local velocity = part.pose_velocity
	local jitter_x, jitter_z, spin_x, spin_z = 0, 0, 0, 0

	if jitter then
		jitter_x, jitter_z = math.randomf(-RELEASE_JITTER, RELEASE_JITTER),
		math.randomf(-RELEASE_JITTER, RELEASE_JITTER)
		spin_x, spin_z = math.randomf(-RELEASE_SPIN, RELEASE_SPIN), math.randomf(-RELEASE_SPIN, RELEASE_SPIN)
	end

	body:SetVelocity(Vec3(velocity.x + jitter_x, velocity.y, velocity.z + jitter_z))
	body:SetAngularVelocity(Vec3(spin_x, 0, spin_z))
	body:Wake()
	part.dynamic = true
	part.exit_time = nil
	part.network_until = nil
	self.dynamic_count = self.dynamic_count + 1
	part.entity.ragdoll_part:SetLimp(true)
	local character_id = self.Owner.network and self.Owner.network.NetworkId or -1

	if character_id ~= -1 then
		part.entity.ragdoll_part:SetCharacterId(character_id)

		if not part.entity.network then part.entity:AddComponent("network") end
	end
end

function META:RemoveJoint(part)
	if part.joint then
		part.joint:Remove()
		part.joint = nil
	end

	for _, other in ipairs(part.ignored) do
		part.body:RestoreCollisionWith(other)
	end

	part.ignored = {}
end

function META:MakeKinematic(part)
	self:RemoveJoint(part)
	part.body:SetMotionType("kinematic")
	part.body:SetCollisionMask(0)
	self:DrivePart(part, true)
	part.dynamic = false
	self.dynamic_count = self.dynamic_count - 1
	part.entity.ragdoll_part:SetLimp(false)
	part.network_until = self.time + NETWORK_LINGER
end

function META:IsSettled()
	for _, part in ipairs(self.parts) do
		local body = part.body

		if
			body.Velocity:GetLength() > SETTLE_SPEED or
			body.AngularVelocity:GetLength() > SETTLE_SPIN
		then
			return false
		end
	end

	return true
end

function META:GetLimp(name)
	local part = self.part_by_name[name]
	return part and part.limp or 0
end

function META:GetJoints()
	local joints = {}

	for _, part in ipairs(self.parts) do
		if part.joint then joints[#joints + 1] = part.joint end
	end

	return joints
end

function META:Capture()
	if not self.parts[1] then return end

	self.sources = {}
	self.impulses = {}

	for body, mass in pairs(self.held) do
		body:SetMass(mass)
	end

	self.held = {}
	self.grabs = 0
	self.hold = nil
	self.blend = nil
	self.global_active = false
	self.previous_velocities = {}
	self.dead_time = 0
	self:SetLimp(false)
	self:UpdateTargets(0)

	for _, part in ipairs(self.parts) do
		self:RemoveJoint(part)

		if part.dynamic then
			part.dynamic = false
			self.dynamic_count = self.dynamic_count - 1
		end

		part.limp = 0
		part.entity.ragdoll_part:SetLimp(false)

		if part.entity.network then part.entity:RemoveComponent("network") end

		part.network_until = nil
		part.body:SetMotionType("kinematic")
		part.body:SetCollisionMask(0)
		self:DrivePart(part, true)
	end
end

function META:EnterGlobal(dead)
	local owner = self.Owner
	self.global_active = true
	self.limp_mode = owner.character_movement.mode
	owner.rigid_body:SetCollisionEnabled(false)
	owner.rigid_body:SetMotionType("kinematic")
	self:SetLimp(true)
	self.previous_velocities = {}

	if not dead then owner:CallLocalEvent("OnCharacterModeChanged", "limp") end
end

-- a held limb pulls the rest of the body along, and how much the rest of the body resists is the hold strength
function META:Grab(body)
	self.grabs = self.grabs + 1
	self.held[body] = body:GetMass()
	body:SetMass(self.total_mass)
	local hold = self.hold or {value = ROOT_LIMP}
	self.hold = hold
	hold.held = true
	hold.timer = 0
	hold.target = HOLD_LIMP

	if network.HasAuthority() then self:UpdateLimp(0) end
end

function META:Ungrab(body)
	self.grabs = math.max(self.grabs - 1, 0)
	body:SetMass(self.held[body])
	self.held[body] = nil

	if self.grabs > 0 or not self.hold then return end

	self.hold.held = false
	self.hold.timer = 0
	self.hold.target = SETTLE_LIMP
end

function META:AddSource(part, policy)
	self.sources[#self.sources + 1] = {
		part = part,
		value = policy.Amount,
		amount = policy.Amount,
		hold = policy.Hold,
		recover = policy.Recover,
		timer = 0,
	}
end

function META:OnTakeDamage(info)
	if
		not network.HasAuthority() or
		not info.Part or
		not self.parts[1] or
		self.global_active or
		self.blend
	then
		return
	end

	local policy = biped.Profiles[self.Profile].Hits[info.Part]
	local part = self.part_by_name[info.Part]

	if not policy or not part then return end

	for _, target in ipairs(part.parent and {part} or part.children) do
		self:AddSource(target, policy)
	end

	if info.Force and info.Position then
		self.impulses[part] = {force = info.Force * policy.Impulse, position = info.Position:Copy()}
	end
end

function META:OnDeath()
	if not network.HasAuthority() then return end

	if not self.parts[1] then self:Build() end

	self.keep_pose = self.blend ~= nil
	self.blend = nil
	self:UpdateLimp(0)
	self.keep_pose = false
end

function META:OnCharacterReset()
	if network.HasAuthority() and not self.resetting then self:Capture() end
end

function META:FollowHead()
	local owner = self.Owner
	local head = self.part_by_name.head.body
	local rotation = head.Rotation
	local view = owner.character_movement:GetViewOffset()
	Quat.SetVecMul(world_offset, rotation, view)
	owner.transform:SetPosition(
		Vec3(
			head.Position.x - world_offset.x,
			head.Position.y - world_offset.y,
			head.Position.z - world_offset.z
		)
	)
	owner.transform:SetRotation(rotation:Copy())
end

function META:BeginBlend()
	local owner = self.Owner
	local position = owner.transform:GetPosition():Copy()
	local root = self.parts[1].body.Position
	local hit = physics.RayCast(Vec3(root.x, root.y + 0.3, root.z), Vec3(0, -1, 0), GROUND_PROBE, owner)

	if hit then position.y = hit.position.y + STAND_HEIGHT end

	self.previous_velocities = {}
	self.sources = {}
	self.impulses = {}
	self.global_active = false
	self:SetLimp(false)
	self.blend = 0
	self.blend_from = {}

	for i, part in ipairs(self.parts) do
		local body = part.body
		self.blend_from[i] = {position = body.Position:Copy(), rotation = body.Rotation:Copy()}
		self:RemoveJoint(part)

		if part.dynamic then
			part.dynamic = false
			self.dynamic_count = self.dynamic_count - 1
		end

		body:SetMotionType("kinematic")
		body:SetCollisionMask(0)
		body:SetVelocity(Vec3())
		body:SetAngularVelocity(Vec3())
		part.limp = 0
	end

	local movement = owner.character_movement
	self.resetting = true
	movement:Reset(self.limp_mode)
	self.resetting = false
	movement:TeleportTo(position)
	self:UpdateTargets(0)
end

function META:BlendParts(dt)
	self.blend = self.blend + dt / BLEND_TIME
	local t = math.min(self.blend, 1)
	t = t * t * (3 - 2 * t)

	for i, part in ipairs(self.parts) do
		local from = self.blend_from[i]
		local position, rotation = part.target_position, part.target_rotation
		blend_position:Set(
			from.position.x + (position.x - from.position.x) * t,
			from.position.y + (position.y - from.position.y) * t,
			from.position.z + (position.z - from.position.z) * t
		)
		local target = rotation

		if
			from.rotation.x * rotation.x + from.rotation.y * rotation.y + from.rotation.z * rotation.z + from.rotation.w * rotation.w < 0
		then
			target = Quat(-rotation.x, -rotation.y, -rotation.z, -rotation.w)
		end

		self:DrivePart(part, false, blend_position, from.rotation:GetLerped(t, target):Normalize())
	end

	if self.blend < 1 then return end

	self.blend = nil
	self.blend_from = nil

	for _, part in ipairs(self.parts) do
		part.entity.ragdoll_part:SetLimp(false)
		part.network_until = self.time + NETWORK_LINGER
	end
end

function META:CheckImpact()
	local previous = self.previous_velocities
	local worst = 0

	for i, part in ipairs(self.parts) do
		local body = part.body
		local velocity = body.Velocity
		local last = previous[i]

		if last then
			if not self.held[body] then
				local lost_x = math.max((last.x - velocity.x) * math.sign(last.x), 0)
				local lost_y = math.max((last.y - velocity.y) * math.sign(last.y), 0)
				local lost_z = math.max((last.z - velocity.z) * math.sign(last.z), 0)
				worst = math.max(worst, math.sqrt(lost_x * lost_x + lost_y * lost_y + lost_z * lost_z))
			end

			last:Set(velocity.x, velocity.y, velocity.z)
		else
			previous[i] = velocity:Copy()
		end
	end

	if worst > 0 then self.Owner.character_movement:Impact(worst) end
end

-- turns a dynamic part towards the pose through its angular velocity only, relative to its parent as it is now
function META:DrivePose(part, dt)
	local body = part.body
	local strength = math.max(1 - part.limp, 0)

	if strength <= 0 or self.held[body] then return end

	local target = part.target_rotation
	local parent = part.parent

	if parent then
		target = parent.body.Rotation * parent.target_rotation:GetConjugated() * target
	end

	local rate = 1 - math.exp(-POSE_RATE * strength * strength * dt)
	local delta = (target * body.Rotation:GetConjugated()):GetNormalized()

	if delta.w < 0 then delta = delta * -1 end

	local w = math.min(delta.w, 1)
	local axis_scale = math.sqrt(math.max(0, 1 - w * w))

	if axis_scale <= 0.0001 then return end

	local spin = body.AngularVelocity
	local angle = 2 * math.acos(w) * POSE_GAIN / axis_scale
	body:SetAngularVelocity(
		Vec3(
			spin.x + (delta.x * angle - spin.x) * rate,
			spin.y + (delta.y * angle - spin.y) * rate,
			spin.z + (delta.z * angle - spin.z) * rate
		)
	)
	body:Wake()
end

function META:GetTrackingError(part)
	local parent = part.parent
	local position, rotation = part.target_position, part.target_rotation

	if parent then
		local conjugate = parent.target_rotation:GetConjugated()
		position = parent.body.Position + parent.body.Rotation:VecMul(conjugate:VecMul(position - parent.target_position))
		rotation = parent.body.Rotation * conjugate * rotation
	end

	local body = part.body
	local dot = math.abs(
		body.Rotation.x * rotation.x + body.Rotation.y * rotation.y + body.Rotation.z * rotation.z + body.Rotation.w * rotation.w
	)
	return body.Position:Distance(position), 2 * math.acos(math.min(dot, 1))
end

-- each part ends up with a limpness from 0 to 1 and is dynamic while it has any
function META:UpdateLimp(dt)
	self.time = self.time + dt
	local owner = self.Owner
	local dead = owner.health:IsDead()
	local global = dead and 1 or 0
	local hold = self.hold

	if hold then
		local step = HOLD_RATE * dt
		hold.value = hold.value + math.clamp(hold.target - hold.value, -step, step)

		if not hold.held then
			hold.timer = hold.timer + dt

			if
				hold.timer >= SETTLE_MAX_TIME or
				(
					hold.timer >= SETTLE_MIN_TIME and
					self:IsSettled()
				)
			then
				self.hold = nil
				hold = nil
			end
		end

		if hold then global = math.max(global, hold.value) end
	end

	if global >= ROOT_LIMP and not self.global_active then
		self:EnterGlobal(dead)
	elseif global < ROOT_LIMP and self.global_active then
		self:BeginBlend()
		return
	end

	local sources = self.sources
	local parts = self.parts

	for _, part in ipairs(parts) do
		part.limp = 0
	end

	for i = #sources, 1, -1 do
		local source = sources[i]
		source.timer = source.timer + dt

		if source.timer > source.hold then
			source.value = source.amount * (1 - (source.timer - source.hold) / source.recover)
		end

		if source.value <= 0 then
			table.remove(sources, i)
		elseif source.value > source.part.limp then
			source.part.limp = source.value
		end
	end

	parts[1].limp = math.max(parts[1].limp, global)

	for _, part in ipairs(parts) do
		local parent = part.parent

		if parent and parent.limp > part.limp then part.limp = parent.limp end
	end

	local now = self.time

	for i, part in ipairs(parts) do
		local want = part.limp > ENTER_LIMP

		if i == 1 then want = global >= ROOT_LIMP end

		if want and not part.dynamic then
			self:MakeDynamic(part, self.keep_pose, self.global_active)
		elseif not want and part.dynamic then
			part.exit_time = part.exit_time or now
			local distance, angle = self:GetTrackingError(part)

			if
				(
					distance < EXIT_DISTANCE and
					angle < EXIT_ANGLE
				)
				or
				now - part.exit_time > EXIT_FORCE_TIME
			then
				self:MakeKinematic(part)
			end
		elseif want then
			part.exit_time = nil
		end

		if
			part.network_until and
			not part.dynamic and
			now >= part.network_until and
			not self.blend
		then
			if part.entity.network then part.entity:RemoveComponent("network") end

			part.network_until = nil
		end
	end

	for part, impulse in pairs(self.impulses) do
		if part.dynamic then
			part.body:ApplyImpulse(impulse.force, impulse.position)
			self.impulses[part] = nil
		end
	end
end

function META:OnPhysicsUpdate(dt)
	if not network.HasAuthority() then return end

	local owner = self.Owner
	local movement = owner.character_movement

	if not movement or not owner.rigid_body then return end

	if not self.parts[1] then self:Build() end

	if self.blend then
		self:UpdateTargets(dt)
		self:BlendParts(dt)
		return
	end

	local walking = movement.mode == "walk"

	if walking ~= self.walking then
		self.walking = walking
		self:SetPartsCollidable(walking)
	end

	if not walking and not self.global_active then return end

	self:UpdateTargets(dt)

	if self.global_active then
		if owner.health:IsDead() then
			self:UpdateLimp(dt)

			if self.global_active then
				self:FollowHead()

				if self.CorpseTime > 0 then
					self.dead_time = self.dead_time + dt

					if self.dead_time >= self.CorpseTime then owner:Remove() end
				end
			end

			return
		end

		local root = self.parts[1]
		local target = root.target_position
		local position = owner.transform:GetPosition()
		local dx, dy, dz = root.body.Position.x - target.x, root.body.Position.y - target.y, root.body.Position.z - target.z
		owner.transform:SetPosition(Vec3(position.x + dx, position.y + dy, position.z + dz))

		for _, part in ipairs(self.parts) do
			part.target_position:Set(part.target_position.x + dx, part.target_position.y + dy, part.target_position.z + dz)
		end

		self:CheckImpact()
	end

	self:UpdateLimp(dt)

	for _, part in ipairs(self.parts) do
		if part.dynamic then self:DrivePose(part, dt) else self:DrivePart(part) end
	end
end

-- parts a client has been told about, and which of them are limp
function META:GetPresentParts()
	if network.HasAuthority() then return self.parts end

	local frame = system.GetFrameNumber()

	if self.present_frame == frame then return self.present end

	self.present_frame = frame
	self.present = {}
	local owner = self.Owner

	if not owner.network then return self.present end

	local by_group = {}

	for _, component in ipairs(RagdollPart.Instances or {}) do
		if component.CharacterId == owner.network.NetworkId then
			by_group[component.Group] = component
		end
	end

	for _, definition in ipairs(biped.Profiles[self.Profile].Parts) do
		local component = by_group[definition.Name]

		if component then
			self.present[#self.present + 1] = {
				definition = definition,
				entity = component.Owner,
				limp = component:IsLimp(),
			}
		end
	end

	return self.present
end

function META:IsDriven(part)
	if network.HasAuthority() then return part.dynamic or self.blend ~= nil end

	return part.limp
end

function META:HasLimp()
	if network.HasAuthority() then
		return self.dynamic_count > 0 or self.blend ~= nil
	end

	for _, part in ipairs(self:GetPresentParts()) do
		if part.limp then return true end
	end

	return false
end

function META:IsPartLimp(name)
	for _, part in ipairs(self:GetPresentParts()) do
		if part.definition.Name == name then return self:IsDriven(part) end
	end

	return false
end

function META:ClearRig()
	local rig = self.driven_rig

	if rig then
		for _, name in ipairs(aim_pose.Bones) do
			rig:ClearBone(biped.SourceBones[name])
		end

		for _, part in ipairs(biped.Profiles[self.Profile].Parts) do
			rig:ClearBone(biped.SourceBones[part.Bone])
		end
	end

	self.driven_rig = nil
end

do
	local entity_position = Vec3()

	local function get_entity_frame(self)
		local owner_transform = self.Owner.transform
		local position, rotation = owner_transform:GetRenderPositionRotation()
		entity_position = position or owner_transform:GetPosition()
		return rotation or owner_transform:GetRotation()
	end

	local function get_part_bone(self, part, entity_rotation, out)
		local transform = part.entity.transform
		local position, rotation = transform:GetRenderPositionRotation()
		position = position or transform:GetPosition()
		rotation = rotation or transform:GetRotation()
		local frame = self.frames[part.definition.Name]
		local inverse = entity_rotation:GetConjugated()
		local bone_rotation = inverse * rotation * frame.rotation:GetConjugated()
		local local_position = inverse:VecMul(position - entity_position) - bone_rotation:VecMul(frame.center)
		out:Identity()
		out:SetRotation(bone_rotation)
		out:SetTranslation(local_position.x, local_position.y, local_position.z)
		return out
	end

	-- puts the bones of the limp parts, and of what hangs on them, over the bones in out
	function META:ReadBones(out)
		if not self.frames then
			self:ComputePose()
			self:BuildFrames()
		end

		local entity_rotation = get_entity_frame(self)
		local limp = {}

		for _, part in ipairs(self:GetPresentParts()) do
			if self:IsDriven(part) then
				limp[part.definition.Name] = true
				get_part_bone(self, part, entity_rotation, out[part.definition.Bone])
			end
		end

		for _, attached in ipairs(self.attached) do
			if limp[self.owner_of[attached.name]] then
				attached.matrix:GetMultiplied(out[attached.parent], out[attached.name])
			end
		end
	end

	-- sets the rig bones of the limp parts on top of the animation and frees what hangs on them from the aim overrides
	function META:DriveRig(rig, armature)
		local entity_rotation = get_entity_frame(self)

		if not self.frames then
			for name, source in pairs(biped.SourceBones) do
				self.bones[name] = rig:GetBone(source)
			end

			self:BuildFrames()
		end

		local limp = {}

		for _, part in ipairs(self:GetPresentParts()) do
			if self:IsDriven(part) then
				limp[part.definition.Name] = true
				rig:SetBone(
					biped.SourceBones[part.definition.Bone],
					get_part_bone(self, part, entity_rotation, part_matrix),
					"model"
				)
			end
		end

		for _, name in ipairs(aim_pose.Bones) do
			if limp[self.owner_of[name]] and not self.part_bones[name] then
				rig:ClearBone(biped.SourceBones[name])
			end
		end

		rig:Compute()
		self.driven_rig = rig

		if armature then
			for name, source in pairs(biped.SourceBones) do
				if limp[self.owner_of[name]] then
					armature:SetBone(name, rig:GetBone(source), "model")
				end
			end
		end
	end
end

function META:OnRemove()
	for _, part in ipairs(self.parts) do
		if part.joint then part.joint:Remove() end

		if part.entity:IsValid() then part.entity:Remove() end
	end
end

return META:Register()
