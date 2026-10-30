local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local CharacterMovement = import("lua/components/character_movement.lua")
local physics = import("goluwa/physics.lua")
local constraints = import("goluwa/physics/constraints.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local Entity = import("goluwa/entities/entity.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("source_ragdoll")
META.Network = {ModelPath = {"string", 0.5, "reliable"}}
META:StartStorable()
META:GetSet("ModelPath", "", {callback = "Load"})
META:IsSet("DeathState", false)
META:GetSet("CorpseTime", 0)
META:EndStorable()
local JOINT_FRICTION = 0.2
local SPRING_HERTZ = 1
local SPRING_LIMIT_HERTZ = 12
local SPRING_DAMPING = 2
local SPRING_ZONE = 0.5
local REST_SPEED = 0.25
local REST_SPIN = 2
local REST_TIME = 1
local AXES = {
	x = Vec3(0, 0, -1),
	y = Vec3(-1, 0, 0),
	z = Vec3(0, 1, 0),
}
local AXIS_NAMES = {"x", "y", "z"}

function META:Initialize()
	self.bodies = {}
	self.joints = {}
	self.matrix = Matrix44()
	self.rest_time = 0
	self:AddGlobalEvent("Update")
	self:AddGlobalEvent("PhysicsUpdate")
	self:Load()
end

function META:Load()
	if not self.bodies then return end

	self:RemoveBodies()
	self.ragdoll = nil
	self.load_id = (self.load_id or 0) + 1
	local load_id = self.load_id

	if self.ModelPath == "" then return end

	model_loader.LoadModel(
		self.ModelPath,
		function(data)
			if not self:IsValid() or self.load_id ~= load_id then return end

			assert(data.physics and data.physics.ragdoll, self.ModelPath .. " has no ragdoll data")
			self.ragdoll = data.physics.ragdoll

			if not self.DeathState or self.dead then self:Build() end
		end,
		nil,
		function(err)
			wlog("source_ragdoll: failed to load %s: %s", self.ModelPath, tostring(err))
		end
	)
end

function META:IsDead()
	return self.dead == true
end

function META:GetRestFrame()
	local root = self.ragdoll.solids[1]
	return root.bone_rotation,
	root.bone_position + root.bone_rotation:VecMul(root.mass_center)
end

local function build_shapes(solid)
	local shapes = {}

	for i, child in ipairs(solid.children) do
		shapes[i] = {ConvexHull = child.ConvexHull, Position = child.Position - solid.mass_center}
	end

	return shapes
end

function META:GetPoseFrames()
	local owner = self.Owner
	local solids = self.ragdoll.solids
	local frames = {}

	if self.DeathState then
		local rig = owner.animator and owner.animator:GetRig()
		local owner_rotation = owner.transform:GetRotation()
		local owner_position = owner.transform:GetPosition()

		for i, solid in ipairs(solids) do
			if rig then
				local bone = rig:GetBone(solid.bone)
				frames[i] = {
					rotation = owner_rotation * bone:GetRotation(),
					position = owner_position + owner_rotation:VecMul(Vec3(bone:GetTranslation())),
				}
			else
				frames[i] = {
					rotation = owner_rotation * solid.bone_rotation,
					position = owner_position + owner_rotation:VecMul(solid.bone_position),
				}
			end
		end

		return frames
	end

	local rest_rotation, rest_position = self:GetRestFrame()
	local model_rotation = owner.transform:GetRotation() * rest_rotation:GetConjugated()
	local model_position = owner.transform:GetPosition() - model_rotation:VecMul(rest_position)

	for i, solid in ipairs(solids) do
		frames[i] = {
			rotation = model_rotation * solid.bone_rotation,
			position = model_position + model_rotation:VecMul(solid.bone_position),
		}
	end

	return frames
end

function META:Build()
	local owner = self.Owner
	local solids = self.ragdoll.solids
	local scale = 1

	if self.DeathState or import("lua/npcs.lua").GetByModel(self.ModelPath) then
		local total = 0

		for _, solid in ipairs(solids) do
			total = total + solid.weight
		end

		scale = CharacterMovement.BodyMass / total
	end

	self.visual_placed = false

	if not self.DeathState then
		local first = solids[1]
		local body = owner:EnsureComponent("rigid_body")
		body:SetShapes(build_shapes(first))
		body:SetMotionType(network.HasAuthority() and "dynamic" or "kinematic")
		body:SetAutomaticMass(false)
		body:SetMass(first.weight * scale)
		body:SetFriction(CharacterMovement.RagdollFriction)
		body:SetFrictionCombineMode("multiply")
		body:SetLinearDamping(first.damping)
		body:SetAirLinearDamping(first.damping)
		body:SetAngularDamping(first.rotation_damping)
		body:SetAirAngularDamping(first.rotation_damping)
		self.bodies[1] = body
	end

	if not network.HasAuthority() then return end

	local frames = self:GetPoseFrames()
	local velocity = self.DeathState and owner.rigid_body:GetVelocity():Copy()

	for i = self.DeathState and 1 or 2, #solids do
		local solid = solids[i]
		local frame = frames[i]
		local entity = Entity.New{
			Name = "ragdoll_" .. solid.name,
			Transient = true,
			transform = {
				Position = frame.position + frame.rotation:VecMul(solid.mass_center),
				Rotation = frame.rotation,
			},
			rigid_body = {
				Shapes = build_shapes(solid),
				Mass = solid.weight * scale,
				AutomaticMass = false,
				Friction = CharacterMovement.RagdollFriction,
				FrictionCombineMode = "multiply",
				LinearDamping = solid.damping,
				AirLinearDamping = solid.damping,
				AngularDamping = solid.rotation_damping,
				AirAngularDamping = solid.rotation_damping,
			},
		}
		entity.rigid_body.TraceOwner = owner
		self.bodies[i] = entity.rigid_body

		if velocity then entity.rigid_body:SetVelocity(velocity) end
	end

	for _, constraint in ipairs(self.ragdoll.constraints) do
		local child = frames[constraint.child]
		local anchor = child.position
		local frame = child.rotation
		local moving = {}

		for _, name in ipairs(AXIS_NAMES) do
			local axis = constraint[name]

			if axis.min ~= 0 or axis.max ~= 0 then moving[#moving + 1] = name end
		end

		if not moving[1] then
			self.joints[#self.joints + 1] = constraints.Weld(self.bodies[constraint.parent], self.bodies[constraint.child], anchor)

			goto continue
		end

		local joint = constraints.Hinge(
			self.bodies[constraint.parent],
			self.bodies[constraint.child],
			anchor,
			frame:VecMul(AXES[moving[1]]),
			{
				LowerAngle = constraint[moving[1]].min,
				UpperAngle = constraint[moving[1]].max,
				Friction = constraint[moving[1]].friction * JOINT_FRICTION,
			}
		)
		joint:SetSpring(0, SPRING_HERTZ, SPRING_LIMIT_HERTZ, SPRING_DAMPING, SPRING_ZONE)
		self.joints[#self.joints + 1] = joint

		::continue::
	end
end

function META:RemoveBodies()
	for _, joint in ipairs(self.joints) do
		joint:Remove()
	end

	for i = self.DeathState and 1 or 2, #self.bodies do
		local entity = self.bodies[i].Owner

		if entity:IsValid() then entity:Remove() end
	end

	self.joints = {}
	self.bodies = {}
end

function META:OnDeath()
	if not self.DeathState or not network.HasAuthority() then return end

	self.dead = true
	self.dead_time = 0
	self.rest_time = 0

	if self.ragdoll then
		self:Build()
	else
		self:SetModelPath(self.Owner.model.ModelPath)
	end
end

function META:OnCharacterReset()
	if not self.dead then return end

	local rig = self.Owner.animator and self.Owner.animator:GetRig()

	if rig then
		for _, solid in ipairs(self.ragdoll.solids) do
			rig:ClearBone(solid.bone)
		end
	end

	self.dead = false
	self:RemoveBodies()
end

function META:OnRemove()
	self:RemoveBodies()
end

function META:GetVisual()
	for _, child in ipairs(self.Owner:GetChildren()) do
		if child.visual then return child end
	end
end

function META:GetRig()
	if self.DeathState then
		return self.Owner.animator and self.Owner.animator:GetRig()
	end

	local visual = self:GetVisual()
	return visual and visual.animator.rig
end

function META:PlaceVisual()
	local visual = self:GetVisual()

	if not visual then return end

	local rest_rotation, rest_position = self:GetRestFrame()
	local rest_inverse = rest_rotation:GetConjugated()
	visual.transform:SetRotation(rest_inverse)
	visual.transform:SetPosition(rest_inverse:VecMul(rest_position) * -1)
	self.visual_placed = true
end

-- a jointed pile of light and heavy bodies keeps rocking a little on its hulls and never reaches the sleep thresholds of a single body
function META:OnPhysicsUpdate(dt)
	local solids = self.ragdoll and self.ragdoll.solids

	if not (solids and self.bodies[#solids]) or not network.HasAuthority() then
		return
	end

	if self.DeathState and self.CorpseTime > 0 then
		self.dead_time = self.dead_time + dt

		if self.dead_time >= self.CorpseTime then
			self.Owner:Remove()
			return
		end
	end

	local awake = false

	for _, body in ipairs(self.bodies) do
		if body.Awake then
			awake = true

			if
				body.Velocity:GetLength() > REST_SPEED or
				body.AngularVelocity:GetLength() > REST_SPIN
			then
				self.rest_time = 0
				return
			end
		end
	end

	if not awake then return end

	self.rest_time = self.rest_time + dt

	if self.rest_time < REST_TIME then return end

	self.rest_time = 0

	for _, body in ipairs(self.bodies) do
		body:Sleep()
	end
end

function META:UpdateDeadRig(solids, rig)
	local alpha = physics.instance.InterpolationAlpha
	local owner_inverse = self.Owner.transform:GetRotation():GetConjugated()
	local owner_position = self.Owner.transform:GetPosition()
	local matrix = self.matrix

	for i, solid in ipairs(solids) do
		local body = self.bodies[i]
		local rotation = body:GetInterpolatedRotation(alpha)
		local position = body:GetInterpolatedPosition(alpha) - rotation:VecMul(solid.mass_center)
		position = owner_inverse:VecMul(position - owner_position)
		matrix:Identity()
		matrix:SetRotation(owner_inverse * rotation)
		matrix:SetTranslation(position.x, position.y, position.z)
		rig:SetBone(solid.bone, matrix, "model")
	end
end

function META:OnUpdate()
	local solids = self.ragdoll and self.ragdoll.solids

	if not (solids and self.bodies[#solids]) then return end

	local rig = self:GetRig()

	if self.DeathState then
		if rig and self.dead then self:UpdateDeadRig(solids, rig) end

		return
	end

	if not self.visual_placed then self:PlaceVisual() end

	if not rig then return end

	local alpha = physics.instance.InterpolationAlpha
	local root = self.bodies[1]
	local root_position = root:GetInterpolatedPosition(alpha)
	local root_inverse = root:GetInterpolatedRotation(alpha):GetConjugated()
	local rest_rotation, rest_position = self:GetRestFrame()
	local matrix = self.matrix

	for i, solid in ipairs(solids) do
		local body = self.bodies[i]
		local relative_rotation = root_inverse * body:GetInterpolatedRotation(alpha)
		local rotation = rest_rotation * relative_rotation
		local position = rest_position + rest_rotation:VecMul(root_inverse:VecMul(body:GetInterpolatedPosition(alpha) - root_position))
		position = position - rotation:VecMul(solid.mass_center)
		matrix:Identity()
		matrix:SetRotation(rotation)
		matrix:SetTranslation(position.x, position.y, position.z)
		rig:SetBone(solid.bone, matrix, "model")
	end
end

return META:Register()
