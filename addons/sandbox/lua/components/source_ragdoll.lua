local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local physics = import("goluwa/physics.lua")
local constraints = import("goluwa/physics/constraints.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local surface_properties = import("goluwa/source_engine/surface_properties.lua")
local Entity = import("goluwa/entities/entity.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("source_ragdoll")
META.Network = {ModelPath = {"string", 0.5, "reliable"}}
META:StartStorable()
META:GetSet("ModelPath", "", {callback = "Load"})
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
			self.surface_property = data.physics.surface_property
			self:Build()
		end,
		nil,
		function(err)
			wlog("source_ragdoll: failed to load %s: %s", self.ModelPath, tostring(err))
		end
	)
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

function META:Build()
	local owner = self.Owner
	local solids = self.ragdoll.solids
	local rest_rotation, rest_position = self:GetRestFrame()
	local rest_inverse = rest_rotation:GetConjugated()
	self.visual_placed = false
	local first = solids[1]
	local surface = surface_properties.Get(self.surface_property or "default")
	local body = owner:EnsureComponent("rigid_body")
	body:SetShapes(build_shapes(first))
	body:SetMotionType(network.HasAuthority() and "dynamic" or "kinematic")
	body:SetAutomaticMass(false)
	body:SetMass(first.weight)
	body:SetFriction(surface.friction)
	self.bodies[1] = body

	if not network.HasAuthority() then return end

	local model_rotation = owner.transform:GetRotation() * rest_inverse
	local model_position = owner.transform:GetPosition() - model_rotation:VecMul(rest_position)

	for i = 2, #solids do
		local solid = solids[i]
		local rotation = model_rotation * solid.bone_rotation
		local entity = Entity.New{
			Name = "ragdoll_" .. solid.name,
			Transient = true,
			transform = {
				Position = model_position + model_rotation:VecMul(solid.bone_position + solid.bone_rotation:VecMul(solid.mass_center)),
				Rotation = rotation,
			},
			rigid_body = {
				Shapes = build_shapes(solid),
				Mass = solid.weight,
				AutomaticMass = false,
				Friction = surface.friction,
			},
		}
		entity.rigid_body.TraceOwner = owner
		self.bodies[i] = entity.rigid_body
	end

	for _, constraint in ipairs(self.ragdoll.constraints) do
		local child = solids[constraint.child]
		local anchor = model_position + model_rotation:VecMul(child.bone_position)
		local frame = model_rotation * child.bone_rotation
		local moving = {}

		for name, axis in pairs(constraint) do
			if AXES[name] and (axis.min ~= 0 or axis.max ~= 0) then
				moving[#moving + 1] = name
			end
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
	end
end

function META:RemoveBodies()
	for _, joint in ipairs(self.joints) do
		joint:Remove()
	end

	for i = 2, #self.bodies do
		local entity = self.bodies[i].Owner

		if entity:IsValid() then entity:Remove() end
	end

	self.joints = {}
	self.bodies = {}
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

	for _, body in ipairs(self.bodies) do
		body:Sleep()
	end
end

function META:OnUpdate()
	local solids = self.ragdoll and self.ragdoll.solids

	if not (solids and self.bodies[#solids]) then return end

	if not self.visual_placed then self:PlaceVisual() end

	local rig = self:GetRig()

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
