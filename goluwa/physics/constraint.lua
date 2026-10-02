local Vec3 = import("goluwa/structs/vec3.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local objects = import("goluwa/objects/objects.lua")
local DistanceConstraint = objects.CreateTemplate("physics_constraint")
local IMPULSE = Vec3()

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

	if length > physics_constants.EPSILON then
		self.LastDirection = delta / length
		return self.LastDirection, length
	end

	if self.LastDirection and self.LastDirection:GetLength() > physics_constants.EPSILON then
		return self.LastDirection, 0
	end

	if self.Body0 and self.Body1 then
		local body_delta = self.Body1.Position - self.Body0.Position
		local body_length = body_delta:GetLength()

		if body_length > physics_constants.EPSILON then
			self.LastDirection = body_delta / body_length
			return self.LastDirection, 0
		end
	end

	self.LastDirection = Vec3(1, 0, 0)
	return self.LastDirection, 0
end

-- Soft velocity constraint along the anchor axis. A rigid rod pulls its error
-- in with the solver's joint softness; a compliant one is a spring. A rope
-- only pulls: a slack rope is speculative, it may still close by its slack.
function DistanceConstraint:Solve(dt, relax, joint_bias_rate, joint_impulse_scale)
	if not self.Enabled then return 0 end

	local world_pos0 = self:GetWorldPosition0()
	local world_pos1 = self:GetWorldPosition1()

	if not (world_pos0 and world_pos1) then return 0 end

	local normal, length = self:GetSolveDirection(world_pos0, world_pos1)
	local inverse_mass = 0

	if self.Body0 then
		inverse_mass = inverse_mass + self.Body0:GetInverseMassAlong(normal, world_pos0)
	end

	if self.Body1 then
		inverse_mass = inverse_mass + self.Body1:GetInverseMassAlong(normal, world_pos1)
	end

	if inverse_mass == 0 then return 0 end

	local bias_rate = joint_bias_rate
	local impulse_scale = joint_impulse_scale

	if self.Compliance > 0 then
		-- implicit spring k = 1 / compliance on the effective mass
		local omega = math.sqrt(inverse_mass / self.Compliance)
		local a1 = dt * omega
		impulse_scale = 1 / (1 + dt * omega * a1)
		bias_rate = omega / a1
	elseif relax then
		bias_rate = 0
		impulse_scale = 0
	end

	local unilateral = self.Unilateral
	local gap = length - (unilateral and self.MaxDistance or self.Distance)
	local bias

	if unilateral and gap <= 0 then
		bias = gap / dt
		impulse_scale = 0
	else
		bias = bias_rate * gap
	end

	local speed = 0

	if self.Body0 then
		local body = self.Body0
		local rx, ry, rz = world_pos0.x - body.Position.x,
		world_pos0.y - body.Position.y,
		world_pos0.z - body.Position.z
		speed = speed - (
				normal.x * (
					body.Velocity.x + body.AngularVelocity.y * rz - body.AngularVelocity.z * ry
				) + normal.y * (
					body.Velocity.y + body.AngularVelocity.z * rx - body.AngularVelocity.x * rz
				) + normal.z * (
					body.Velocity.z + body.AngularVelocity.x * ry - body.AngularVelocity.y * rx
				)
			)
	end

	if self.Body1 then
		local body = self.Body1
		local rx, ry, rz = world_pos1.x - body.Position.x,
		world_pos1.y - body.Position.y,
		world_pos1.z - body.Position.z
		speed = speed + (
				normal.x * (
					body.Velocity.x + body.AngularVelocity.y * rz - body.AngularVelocity.z * ry
				) + normal.y * (
					body.Velocity.y + body.AngularVelocity.z * rx - body.AngularVelocity.x * rz
				) + normal.z * (
					body.Velocity.z + body.AngularVelocity.x * ry - body.AngularVelocity.y * rx
				)
			)
	end

	local accumulated_lambda = self.AccumulatedLambda
	local lambda = accumulated_lambda - (
			(
				1 - impulse_scale
			) * (
				speed + bias
			) / inverse_mass + impulse_scale * accumulated_lambda
		)

	if unilateral then lambda = math.min(lambda, 0) end

	local delta_lambda = lambda - accumulated_lambda
	self.AccumulatedLambda = lambda

	if math.abs(delta_lambda) <= physics_constants.EPSILON then return 0 end

	IMPULSE:CopyFrom(normal):Scale(delta_lambda)

	if self.Body0 then self.Body0:ApplyImpulse(IMPULSE * -1, world_pos0) end

	if self.Body1 then self.Body1:ApplyImpulse(IMPULSE, world_pos1) end

	return delta_lambda / dt
end

local tracked = {}

function DistanceConstraint.Track(constraint)
	tracked[#tracked + 1] = constraint
	return constraint
end

function DistanceConstraint.Untrack(constraint)
	for i = 1, #tracked do
		if tracked[i] == constraint then
			table.remove(tracked, i)
			return
		end
	end
end

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
	return DistanceConstraint.Track(constraint)
end

function DistanceConstraint:OnRemove()
	self.Enabled = false
	self.AccumulatedLambda = 0
	DistanceConstraint.Untrack(self)
end

function DistanceConstraint.GetConstraints()
	return tracked
end

function DistanceConstraint.RemoveAllConstraints()
	for i = #tracked, 1, -1 do
		tracked[i]:Remove()
	end
end

return DistanceConstraint:Register()
