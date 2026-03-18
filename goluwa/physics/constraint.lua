local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics.lua")
local motion = import("goluwa/physics/motion.lua")
local prototype = import("goluwa/prototype.lua")
local DistanceConstraint = prototype.CreateTemplate("physics_constraint")

local function integrate_rotation(rotation, angular_velocity, dt)
	if angular_velocity:GetLength() == 0 then return rotation:Copy() end

	local delta = Quat(angular_velocity.x, angular_velocity.y, angular_velocity.z, 0) * rotation
	return Quat(
		rotation.x + 0.5 * dt * delta.x,
		rotation.y + 0.5 * dt * delta.y,
		rotation.z + 0.5 * dt * delta.z,
		rotation.w + 0.5 * dt * delta.w
	):GetNormalized()
end

local function preserve_body_motion(body, dt)
	if not body then return end

	body.PreviousPosition = body.Position - body:GetVelocity() * dt
	body.PreviousRotation = integrate_rotation(body.Rotation, body:GetAngularVelocity(), -dt)
end

local function copy_vec(vec)
	return vec and vec:Copy() or nil
end

function DistanceConstraint:GetWorldPosition0()
	if self.Body0 then return self.Body0:LocalToWorld(self.LocalPosition0) end

	return self.WorldPosition0
end

function DistanceConstraint:GetWorldPosition1()
	if self.Body1 then return self.Body1:LocalToWorld(self.LocalPosition1) end

	return self.WorldPosition1
end

function DistanceConstraint:SetWorldPosition0(vec)
	self.WorldPosition0 = vec:Copy()

	if self.Body0 then self.LocalPosition0 = self.Body0:WorldToLocal(vec) end

	return self
end

function DistanceConstraint:SetWorldPosition1(vec)
	self.WorldPosition1 = vec:Copy()

	if self.Body1 then self.LocalPosition1 = self.Body1:WorldToLocal(vec) end

	return self
end

function DistanceConstraint:SetDistance(distance)
	distance = math.max(distance or 0, 0)
	self.Distance = distance

	if self.Unilateral then
		self.MinDistance = nil
		self.MaxDistance = distance
	else
		self.MinDistance = distance
		self.MaxDistance = distance
	end

	return self
end

function DistanceConstraint:SetCompliance(compliance)
	self.Compliance = math.max(compliance or 0, 0)
	return self
end

function DistanceConstraint:SetUnilateral(unilateral)
	self.Unilateral = unilateral and true or false
	return self:SetDistance(self.Distance)
end

function DistanceConstraint:SetEnabled(enabled)
	self.Enabled = enabled ~= false

	if self.Enabled == false then self.AccumulatedLambda = 0 end

	return self
end

function DistanceConstraint:BeginStep()
	self.AccumulatedLambda = 0
	return self
end

function DistanceConstraint:GetCurrentLength()
	local world_pos0 = self:GetWorldPosition0()
	local world_pos1 = self:GetWorldPosition1()

	if not (world_pos0 and world_pos1) then return nil end

	return (world_pos1 - world_pos0):GetLength()
end

function DistanceConstraint:GetConstraintError(length)
	length = length or self:GetCurrentLength()

	if not length then return nil end

	if self.Unilateral then
		local max_distance = self.MaxDistance or self.Distance or 0

		if length <= max_distance then return 0 end

		return length - max_distance
	end

	local min_distance = self.MinDistance
	local max_distance = self.MaxDistance

	if min_distance ~= nil and length < min_distance then
		return length - min_distance
	end

	if max_distance ~= nil and length > max_distance then
		return length - max_distance
	end

	if self.Distance ~= nil then return length - self.Distance end

	return 0
end

function DistanceConstraint:GetSolveDirection(world_pos0, world_pos1)
	local delta = world_pos1 - world_pos0
	local length = delta:GetLength()

	if length > physics.EPSILON then
		self.LastDirection = delta / length
		return self.LastDirection, length
	end

	if self.LastDirection and self.LastDirection:GetLength() > physics.EPSILON then
		return self.LastDirection, 0
	end

	if self.Body0 and self.Body1 then
		local body_delta = self.Body1.Position - self.Body0.Position
		local body_length = body_delta:GetLength()

		if body_length > physics.EPSILON then
			self.LastDirection = body_delta / body_length
			return self.LastDirection, 0
		end
	end

	self.LastDirection = Vec3(1, 0, 0)
	return self.LastDirection, 0
end

function DistanceConstraint:Solve(dt)
	if not self.Enabled then return 0 end

	local world_pos0 = self:GetWorldPosition0()
	local world_pos1 = self:GetWorldPosition1()

	if not (world_pos0 and world_pos1) then return 0 end

	local normal, length = self:GetSolveDirection(world_pos0, world_pos1)
	local error = self:GetConstraintError(length)

	if not error then return 0 end

	if math.abs(error) <= physics.EPSILON then
		if self.Unilateral then self.AccumulatedLambda = 0 end

		return 0
	end

	dt = dt or 0

	if dt <= 0 then dt = 1 / 60 end

	local inverse_mass = 0

	if self.Body0 then
		inverse_mass = inverse_mass + self.Body0:GetInverseMassAlong(normal, world_pos0)
	end

	if self.Body1 then
		inverse_mass = inverse_mass + self.Body1:GetInverseMassAlong(normal, world_pos1)
	end

	if inverse_mass == 0 then return 0 end

	local alpha = (self.Compliance or 0) / (dt * dt)
	local accumulated_lambda = self.AccumulatedLambda or 0
	local delta_lambda = -(error + alpha * accumulated_lambda) / (inverse_mass + alpha)

	if delta_lambda == 0 then return 0 end

	self.AccumulatedLambda = accumulated_lambda + delta_lambda
	local correction = normal * -delta_lambda

	if self.Body0 then
		if self.Body0.HasSolverMass and self.Body0:HasSolverMass() then
			self.Body0:Wake()
		end

		local previous_position = self.Body0.Position:Copy()
		local previous_rotation = self.Body0.Rotation:Copy()
		self.Body0:_ApplyCorrection(correction, world_pos0)

		if not self.Unilateral then
			motion.ApplyBodyMotionDelta(self.Body0, previous_position, previous_rotation, dt)
		end

		if self.Unilateral then preserve_body_motion(self.Body0, dt) end
	end

	if self.Body1 then
		if self.Body1.HasSolverMass and self.Body1:HasSolverMass() then
			self.Body1:Wake()
		end

		local previous_position = self.Body1.Position:Copy()
		local previous_rotation = self.Body1.Rotation:Copy()
		self.Body1:_ApplyCorrection(correction * -1, world_pos1)

		if not self.Unilateral then
			motion.ApplyBodyMotionDelta(self.Body1, previous_position, previous_rotation, dt)
		end

		if self.Unilateral then preserve_body_motion(self.Body1, dt) end
	end

	return delta_lambda / (dt * dt)
end

local keep_alive = {}

function DistanceConstraint.New(body0, body1, pos0, pos1, distance, compliance, unilateral)
	local constraint = DistanceConstraint:CreateObject{
		Body0 = body0,
		Body1 = body1,
		Distance = 0,
		Compliance = 0,
		Unilateral = unilateral or false,
		Enabled = true,
		AccumulatedLambda = 0,
	}

	if body0 then
		constraint.LocalPosition0 = body0:WorldToLocal(pos0)
	else
		constraint.WorldPosition0 = copy_vec(pos0)
	end

	if body1 then
		constraint.LocalPosition1 = body1:WorldToLocal(pos1)
	else
		constraint.WorldPosition1 = copy_vec(pos1)
	end

	constraint:SetCompliance(compliance)
	constraint:SetDistance(distance or ((pos1 - pos0):GetLength()))
	keep_alive[constraint] = true
	return constraint
end

function DistanceConstraint:OnRemove()
	self.Enabled = false
	self.AccumulatedLambda = 0
	keep_alive[self] = nil
end

function physics.GetConstraints()
	return DistanceConstraint.Instances
end

function physics.RemoveAllConstraints()
	for _, constraint in ipairs(DistanceConstraint.Instances) do
		constraint:Remove()
	end
end

return DistanceConstraint:Register()
