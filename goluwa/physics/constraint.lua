local physics = import("goluwa/physics/shared.lua")
local DistanceConstraint = {}
DistanceConstraint.__index = DistanceConstraint

local function remove_distance_constraint(target)
	for i = #physics.DistanceConstraints, 1, -1 do
		if physics.DistanceConstraints[i] == target then
			table.remove(physics.DistanceConstraints, i)
			return
		end
	end
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

function DistanceConstraint:Solve(dt)
	if not self.Enabled then return 0 end

	local world_pos0 = self:GetWorldPosition0()
	local world_pos1 = self:GetWorldPosition1()

	if not (world_pos0 and world_pos1 and self.Body0) then return 0 end

	local correction = world_pos1 - world_pos0
	local length = correction:GetLength()

	if length == 0 then return 0 end

	if self.Unilateral and length < self.Distance then return 0 end

	correction = correction / length * (length - self.Distance)
	return self.Body0:ApplyCorrection(self.Compliance or 0, correction, world_pos0, self.Body1, world_pos1, dt)
end

function DistanceConstraint:Destroy()
	remove_distance_constraint(self)
end

function physics.CreateDistanceConstraint(body0, body1, pos0, pos1, distance, compliance, unilateral)
	local constraint = setmetatable(
		{
			Body0 = body0,
			Body1 = body1,
			Distance = distance or ((pos1 - pos0):GetLength()),
			Compliance = compliance or 0,
			Unilateral = unilateral or false,
			Enabled = true,
		},
		DistanceConstraint
	)

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

	table.insert(physics.DistanceConstraints, constraint)
	return constraint
end

physics.AddDistanceConstraint = physics.CreateDistanceConstraint
physics.DistanceConstraint = DistanceConstraint
return physics