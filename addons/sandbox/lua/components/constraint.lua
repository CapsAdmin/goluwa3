local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local constraints = import("goluwa/physics/constraints.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Beam = RENDER_3D and import("goluwa/render3d/beam.lua")
local Material = RENDER_3D and import("goluwa/render3d/material.lua")
local META = objects.CreateTemplate("constraint")
META.Kinds = {
	"weld",
	"ball_socket",
	"axis",
	"motor",
	"slider",
	"rope",
	"elastic",
	"no_collide",
	"keep_upright",
}
META.Network = {
	Kind = {"string", 0.5, "reliable"},
	Entity0 = {"string", 0.5, "reliable"},
	Entity1 = {"string", 0.5, "reliable"},
	Anchor0 = {"vec3", 0.5, "reliable"},
	Anchor1 = {"vec3", 0.5, "reliable"},
	Length = {"number", 0.5, "reliable"},
	Width = {"number", 0.5, "reliable"},
	Color = {"color", 0.5, "reliable"},
}
META:StartStorable()
META:GetSet("Kind", "weld", {enums = META.Kinds, callback = "Rebuild"})
META:GetSet("Entity0", "", {callback = "Rebuild"})
META:GetSet("Entity1", "", {callback = "Rebuild"})
META:GetSet("Anchor0", Vec3(), {callback = "Rebuild"})
META:GetSet("Anchor1", Vec3(), {callback = "Rebuild"})
META:GetSet("Axis", Vec3(0, 1, 0), {callback = "Rebuild"})
META:GetSet("Length", 0, {callback = "Rebuild"})
META:GetSet("Rigid", false, {callback = "Rebuild"})
META:GetSet("Stiffness", 0, {callback = "Rebuild"})
META:GetSet("Damping", 0, {callback = "Rebuild"})
META:GetSet("Friction", 0, {callback = "Rebuild"})
META:GetSet("MotorSpeed", 0, {callback = "Rebuild"})
META:GetSet("MotorTorque", 0, {callback = "Rebuild"})
META:GetSet("BreakForce", 0, {callback = "Rebuild"})
META:GetSet("CollideConnected", false, {callback = "Rebuild"})
META:GetSet("Width", 0, {callback = "RebuildVisual"})
META:GetSet("Color", Color(0.25, 0.2, 0.15, 1), {callback = "RebuildVisual"})
META:EndStorable()
local ROPE_POINTS = 16
local VISUAL_KINDS = {rope = true, elastic = true, slider = true}
local MOVE_EPSILON = 0.0005

event.AddListener("PhysicsConstraintBroken", "constraint_component", function(physics_constraint)
	local component = physics_constraint.entity_component

	if component then component.broken = true end
end)

function META:Initialize()
	self:AddGlobalEvent("Update")

	if RENDER_3D then
		self.points = Beam.NewPoints(ROPE_POINTS)
		self.last_start = Vec3()
		self.last_finish = Vec3()
		self.control = Vec3()
		self:AddGlobalEvent("LateUpdate")
	end
end

function META:GetEntities()
	local entity0 = objects.GetObjectByGUID(self.Entity0)
	local entity1 = self.Entity1 == "" and NULL or objects.GetObjectByGUID(self.Entity1)
	return entity0, entity1
end

function META:References(entity)
	local guid = entity:GetGUID()
	return self.Entity0 == guid or self.Entity1 == guid
end

function META:IsBuilt()
	return self.physics_constraint ~= nil
end

function META:GetPhysicsConstraint()
	return self.physics_constraint
end

do
	local function watch(self, entity)
		if not entity:IsValid() then return end

		entity:CallOnRemove(function()
			self.Owner:Remove()
		end, self)

		self.watched[#self.watched + 1] = entity
	end

	function META:Build()
		local entity0, entity1 = self:GetEntities()

		if not (entity0:IsValid() and entity0.rigid_body) then return false end

		if self.Entity1 ~= "" and not (entity1:IsValid() and entity1.rigid_body) then
			return false
		end

		local body0 = entity0.rigid_body
		local body1 = entity1:IsValid() and entity1.rigid_body or nil
		local kind = self.Kind
		local anchor0 = body0:LocalToWorld(self.Anchor0)
		local anchor1 = body1 and body1:LocalToWorld(self.Anchor1) or self.Anchor1
		local axis = body0.Rotation:VecMul(self.Axis):GetNormalized()
		local config = {
			CollideConnected = self.CollideConnected,
			BreakForce = self.BreakForce > 0 and self.BreakForce or nil,
			BreakTorque = self.BreakForce > 0 and self.BreakForce or nil,
		}
		local physics_constraint

		if kind == "weld" then
			physics_constraint = constraints.Weld(body0, body1, anchor0, config)
		elseif kind == "ball_socket" then
			physics_constraint = constraints.BallSocket(body0, body1, anchor0, config)
		elseif kind == "axis" then
			config.Friction = self.Friction
			physics_constraint = constraints.Hinge(body0, body1, anchor0, axis, config)
		elseif kind == "motor" then
			config.Friction = self.Friction
			physics_constraint = constraints.Motor(body0, body1, anchor0, axis, self.MotorSpeed, self.MotorTorque, config)
		elseif kind == "slider" then
			config.Friction = self.Friction
			physics_constraint = constraints.Slider(body0, body1, anchor0, axis, config)
		elseif kind == "rope" then
			config.Length = self.Length
			config.CollideConnected = true

			if self.Rigid then
				physics_constraint = constraints.Rod(body0, body1, anchor0, anchor1, config)
			else
				physics_constraint = constraints.Rope(body0, body1, anchor0, anchor1, config)
			end
		elseif kind == "elastic" then
			config.Length = self.Length
			config.Stiffness = self.Stiffness
			config.Damping = self.Damping
			config.CollideConnected = true
			physics_constraint = constraints.Spring(body0, body1, anchor0, anchor1, config)
		elseif kind == "no_collide" then
			physics_constraint = constraints.NoCollide(body0, body1)
		elseif kind == "keep_upright" then
			physics_constraint = constraints.KeepUpright(
				body0,
				{
					LocalAxis = self.Axis,
					MaxTorque = self.MotorTorque > 0 and self.MotorTorque or nil,
				}
			)
		end

		physics_constraint.entity_component = self
		self.physics_constraint = physics_constraint
		self.body0 = body0
		self.body1 = body1
		self.watched = {}
		watch(self, entity0)
		watch(self, entity1)
		body0:Wake()

		if body1 then body1:Wake() end

		self:RebuildVisual()
		return true
	end
end

function META:Unbuild()
	local physics_constraint = self.physics_constraint

	if not physics_constraint then return end

	self.physics_constraint = nil
	physics_constraint.entity_component = nil

	if physics_constraint:IsValid() then physics_constraint:Remove() end

	for _, entity in ipairs(self.watched) do
		if entity:IsValid() then entity:CallOnRemove(nil, self) end
	end

	self.watched = nil
	self.body0 = nil
	self.body1 = nil
end

function META:Rebuild()
	self:Unbuild()
end

function META:RebuildVisual()
	if self.beam then
		self.beam:Remove()
		self.beam = nil
	end

	if
		not (
			RENDER_3D and
			self.physics_constraint and
			VISUAL_KINDS[self.Kind] and
			self.Width > 0
		)
	then
		return
	end

	self.beam = Beam.New{
		Points = ROPE_POINTS,
		Radius = self.Width / 2,
		Material = Material.New{Color = self.Color:Copy(), Roughness = 0.85, Metallic = 0},
	}
	self.last_start:Set(math.huge, math.huge, math.huge)
end

function META:OnUpdate()
	if self.broken then
		self.Owner:Remove()
		return
	end

	local physics_constraint = self.physics_constraint

	if physics_constraint and not physics_constraint:IsValid() then
		self:Unbuild()
	end

	if not self.physics_constraint then self:Build() end
end

function META:GetVisualEndpoints(start, finish)
	local alpha = physics.GetInterpolationAlpha()
	local body0 = self.body0
	local body1 = self.body1
	local a = body0:LocalToWorld(
		self.Anchor0,
		body0:GetInterpolatedPosition(alpha),
		body0:GetInterpolatedRotation(alpha)
	)
	start:Set(a.x, a.y, a.z)

	if body1 then
		local b = body1:LocalToWorld(
			self.Anchor1,
			body1:GetInterpolatedPosition(alpha),
			body1:GetInterpolatedRotation(alpha)
		)
		finish:Set(b.x, b.y, b.z)
	else
		finish:Set(self.Anchor1.x, self.Anchor1.y, self.Anchor1.z)
	end
end

do
	local start = Vec3()
	local finish = Vec3()

	function META:OnLateUpdate()
		local beam = self.beam

		if not beam then return end

		self:GetVisualEndpoints(start, finish)

		if
			start:Distance(self.last_start) < MOVE_EPSILON and
			finish:Distance(self.last_finish) < MOVE_EPSILON
		then
			return
		end

		self.last_start:Set(start.x, start.y, start.z)
		self.last_finish:Set(finish.x, finish.y, finish.z)
		local distance = start:Distance(finish)
		local slack = self.Kind == "rope" and not self.Rigid and self.Length - distance or 0

		if slack > 0 then
			local sag = math.sqrt(3 * distance * slack / 8) * 2
			local control = self.control
			control:Set((start.x + finish.x) / 2, (start.y + finish.y) / 2 - sag, (start.z + finish.z) / 2)
			Beam.Quadratic(start, control, finish, self.points)
		else
			Beam.Line(start, finish, self.points)
		end

		beam:SetPoints(self.points)
	end
end

function META:OnRemove()
	self:Unbuild()

	if self.beam then
		self.beam:Remove()
		self.beam = nil
	end
end

return META:Register()
