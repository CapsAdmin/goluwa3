local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local default_skin = (
		import.loaded["goluwa/physics.lua"] and
		import.loaded["goluwa/physics.lua"].DefaultSkin
	)
	or
	0.02
local META = prototype.CreateTemplate("rigid_body")
META:GetSet("Enabled", true)
META:GetSet("Shape", "box", {callback = "OnGeometryChanged"})
META:GetSet("Size", Vec3(1, 1, 1), {callback = "OnGeometryChanged"})
META:GetSet("Radius", 0.5, {callback = "OnGeometryChanged"})
META:GetSet("Density", 1, {callback = "RefreshMassProperties"})
META:GetSet("Mass", 1, {callback = "RefreshMassProperties"})
META:GetSet("AutomaticMass", true, {callback = "RefreshMassProperties"})
META:GetSet("Static", false, {callback = "RefreshMassProperties"})
META:GetSet("GravityScale", 1)
META:GetSet("LinearDamping", 0)
META:GetSet("AngularDamping", 0)
META:GetSet("AirLinearDamping", 0)
META:GetSet("AirAngularDamping", 0)
META:GetSet("CollisionEnabled", true)
META:GetSet("CollisionGroup", 1)
META:GetSet("CollisionMask", -1)
META:GetSet("CollisionMargin", default_skin)
META:GetSet("CollisionProbeDistance", 0.125)
META:GetSet("Friction", 0)
META:GetSet("Restitution", 0)
META:GetSet("Awake", true)
META:GetSet("CanSleep", true)
META:GetSet("SleepLinearThreshold", 0.15)
META:GetSet("SleepAngularThreshold", 0.15)
META:GetSet("SleepDelay", 0.5)
META:GetSet("MaxLinearSpeed", 240)
META:GetSet("MaxAngularSpeed", 60)
META:GetSet("MinGroundNormalY", 0.2)
META:GetSet("FilterFunction", nil)
META:GetSet("Grounded", false)

local function component_mul(a, b)
	return Vec3(a.x * b.x, a.y * b.y, a.z * b.z)
end

local function zero_vec3()
	return Vec3(0, 0, 0)
end

local function clamp_vec_length(vec, max_length)
	local length = vec:GetLength()

	if not max_length or max_length <= 0 or length <= max_length then return vec end

	return vec / length * max_length
end

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

function META:Initialize()
	self.Velocity = self.Velocity or Vec3(0, 0, 0)
	self.AngularVelocity = self.AngularVelocity or Vec3(0, 0, 0)
	self.Position = self.Position or Vec3(0, 0, 0)
	self.PreviousPosition = self.PreviousPosition or Vec3(0, 0, 0)
	self.Rotation = self.Rotation or Quat(0, 0, 0, 1)
	self.PreviousRotation = self.PreviousRotation or Quat(0, 0, 0, 1)
	self.GroundNormal = self.GroundNormal or Vec3(0, 1, 0)
	self.InverseMass = self.InverseMass or 0
	self.InverseInertia = self.InverseInertia or Vec3(0, 0, 0)
	self.StepDt = self.StepDt or 0
	self.SleepTimer = self.SleepTimer or 0
	self.AccumulatedForce = self.AccumulatedForce or zero_vec3()
	self.AccumulatedTorque = self.AccumulatedTorque or zero_vec3()
	self:RefreshMassProperties()

	if self.Owner and self.Owner.transform then
		self:SynchronizeFromTransform()
	end
end

function META:OnAdd(entity)
	self.Owner = entity

	if entity.transform then self:SynchronizeFromTransform() end
end

function META:OnGeometryChanged()
	self.CollisionLocalPoints = nil
	self.SupportLocalPoints = nil
	self:RefreshMassProperties()
end

function META:RefreshMassProperties()
	local mass = self.Mass or 0

	if self.Static then
		mass = 0
	elseif self.AutomaticMass then
		if self.Shape == "sphere" then
			mass = (4 / 3) * math.pi * self.Radius * self.Radius * self.Radius * self.Density
		else
			mass = self.Size.x * self.Size.y * self.Size.z * self.Density
		end
	end

	self.ComputedMass = mass

	if mass <= 0 then
		self.InverseMass = 0
		self.InverseInertia = Vec3(0, 0, 0)
		return
	end

	self.InverseMass = 1 / mass

	if self.Shape == "sphere" then
		local inertia = (2 / 5) * mass * self.Radius * self.Radius
		local inv = inertia > 0 and 1 / inertia or 0
		self.InverseInertia = Vec3(inv, inv, inv)
		return
	end

	local sx, sy, sz = self.Size.x, self.Size.y, self.Size.z
	local ix = (1 / 12) * mass * (sy * sy + sz * sz)
	local iy = (1 / 12) * mass * (sx * sx + sz * sz)
	local iz = (1 / 12) * mass * (sx * sx + sy * sy)
	self.InverseInertia = Vec3(ix > 0 and 1 / ix or 0, iy > 0 and 1 / iy or 0, iz > 0 and 1 / iz or 0)
end

function META:GetBody()
	return self
end

function META:GetVelocity()
	return self.Velocity
end

function META:SetVelocity(vec)
	self.Velocity = vec:Copy()

	if
		self.InverseMass ~= 0 and
		vec:GetLength() > math.max(self.SleepLinearThreshold or 0, 0)
	then
		self:Wake()
	end
end

function META:GetAngularVelocity()
	return self.AngularVelocity
end

function META:SetAngularVelocity(vec)
	self.AngularVelocity = vec:Copy()

	if
		self.InverseMass ~= 0 and
		vec:GetLength() > math.max(self.SleepAngularThreshold or 0, 0)
	then
		self:Wake()
	end
end

function META:GetPosition()
	return self.Position
end

function META:SetPosition(vec)
	self.Position = vec:Copy()

	if self.InverseMass ~= 0 then self:Wake() end
end

function META:GetPreviousPosition()
	return self.PreviousPosition
end

function META:GetRotation()
	return self.Rotation
end

function META:SetRotation(quat)
	self.Rotation = quat:Copy()

	if self.InverseMass ~= 0 then self:Wake() end
end

function META:GetPreviousRotation()
	return self.PreviousRotation
end

function META:GetGroundNormal()
	return self.GroundNormal
end

function META:SetGroundNormal(vec)
	self.GroundNormal = vec:Copy()
end

function META:SetGrounded(grounded)
	self.Grounded = grounded
end

function META:GetGrounded()
	return self.Grounded
end

function META:GetAccumulatedForce()
	return self.AccumulatedForce
end

function META:GetAccumulatedTorque()
	return self.AccumulatedTorque
end

function META:ClearAccumulators()
	self.AccumulatedForce = zero_vec3()
	self.AccumulatedTorque = zero_vec3()
end

function META:GetAngularVelocityDelta(world_impulse)
	local local_impulse = self.Rotation:GetConjugated():VecMul(world_impulse)
	local local_delta = component_mul(local_impulse, self.InverseInertia)
	return self.Rotation:VecMul(local_delta)
end

function META:ApplyAngularImpulse(world_impulse)
	if self.InverseMass == 0 then return self end

	self:Wake()
	self.AngularVelocity = self.AngularVelocity + self:GetAngularVelocityDelta(world_impulse)
	return self
end

function META:ApplyImpulse(impulse, world_pos)
	if self.InverseMass == 0 then return self end

	self:Wake()
	self.Velocity = self.Velocity + impulse * self.InverseMass

	if world_pos then
		self:ApplyAngularImpulse((world_pos - self.Position):GetCross(impulse))
	end

	return self
end

function META:ApplyTorque(torque)
	if self.InverseMass == 0 then return self end

	self:Wake()
	self.AccumulatedTorque = self.AccumulatedTorque + torque
	return self
end

function META:ApplyForce(force, world_pos)
	if self.InverseMass == 0 then return self end

	self:Wake()
	self.AccumulatedForce = self.AccumulatedForce + force

	if world_pos then
		self:ApplyTorque((world_pos - self.Position):GetCross(force))
	end

	return self
end

META.AddForce = META.ApplyForce
META.AddTorque = META.ApplyTorque
META.AddImpulse = META.ApplyImpulse

function META:Wake()
	if self.InverseMass == 0 then return end

	self.Awake = true
	self.SleepTimer = 0
end

function META:Sleep()
	if self.InverseMass == 0 then return end

	self.Awake = false
	self.SleepTimer = 0
	self.Velocity = Vec3(0, 0, 0)
	self.AngularVelocity = Vec3(0, 0, 0)
	self.PreviousPosition = self.Position:Copy()
	self.PreviousRotation = self.Rotation:Copy()
end

function META:UpdateSleepState(dt)
	if self.InverseMass == 0 or not self.CanSleep then return end

	if not self.Awake then
		self.Velocity = Vec3(0, 0, 0)
		self.AngularVelocity = Vec3(0, 0, 0)
		self.PreviousPosition = self.Position:Copy()
		self.PreviousRotation = self.Rotation:Copy()
		return
	end

	if
		self.Velocity:GetLength() <= self.SleepLinearThreshold and
		self.AngularVelocity:GetLength() <= self.SleepAngularThreshold
	then
		self.SleepTimer = self.SleepTimer + dt

		if self.SleepTimer >= self.SleepDelay then self:Sleep() end
	else
		self.SleepTimer = 0
	end
end

function META:GetHalfExtents()
	if self.Shape == "sphere" then
		return Vec3(self.Radius, self.Radius, self.Radius)
	end

	return self.Size * 0.5
end

function META:IsStatic()
	return self.InverseMass == 0
end

function META:SynchronizeFromTransform()
	if not (self.Owner and self.Owner.transform) then return end

	self.Position = self.Owner.transform:GetPosition():Copy()
	self.Rotation = self.Owner.transform:GetRotation():Copy()
	self.PreviousPosition = self.Position:Copy()
	self.PreviousRotation = self.Rotation:Copy()
end

function META:WriteToTransform()
	if not (self.Owner and self.Owner.transform) then return end

	self.Owner.transform:SetPosition(self.Position:Copy())
	self.Owner.transform:SetRotation(self.Rotation:Copy())
end

function META:LocalToWorld(local_pos, position, rotation)
	position = position or self.Position
	rotation = rotation or self.Rotation
	return position + rotation:VecMul(local_pos)
end

function META:GeometryLocalToWorld(local_pos, position, rotation)
	position = position or self.Position

	if self.Shape == "sphere" then return position + local_pos end

	rotation = rotation or self.Rotation
	return position + rotation:VecMul(local_pos)
end

function META:WorldToLocal(world_pos, position, rotation)
	position = position or self.Position
	rotation = rotation or self.Rotation
	return rotation:GetConjugated():VecMul(world_pos - position)
end

function META:GetBroadphaseAABB(position, rotation)
	position = position or self.Position
	rotation = rotation or self.Rotation

	if self.Shape == "sphere" then
		local r = self.Radius
		return AABB(
			position.x - r,
			position.y - r,
			position.z - r,
			position.x + r,
			position.y + r,
			position.z + r
		)
	end

	if self.Shape == "box" then
		local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)
		local ex = self.Size.x * 0.5
		local ey = self.Size.y * 0.5
		local ez = self.Size.z * 0.5
		local corners = {
			Vec3(-ex, -ey, -ez),
			Vec3(ex, -ey, -ez),
			Vec3(ex, ey, -ez),
			Vec3(-ex, ey, -ez),
			Vec3(-ex, -ey, ez),
			Vec3(ex, -ey, ez),
			Vec3(ex, ey, ez),
			Vec3(-ex, ey, ez),
		}

		for _, corner in ipairs(corners) do
			bounds:ExpandVec3(position + rotation:VecMul(corner))
		end

		return bounds
	end

	if self.Owner and self.Owner.model and self.Owner.model.GetWorldAABB then
		return self.Owner.model:GetWorldAABB()
	end

	local points = self:GetCollisionLocalPoints()

	if not points or not points[1] then
		local half = self:GetHalfExtents()
		return AABB(
			position.x - half.x,
			position.y - half.y,
			position.z - half.z,
			position.x + half.x,
			position.y + half.y,
			position.z + half.z
		)
	end

	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, point in ipairs(points) do
		bounds:ExpandVec3(self:GeometryLocalToWorld(point, position, rotation))
	end

	return bounds
end

function META:Integrate(dt, gravity)
	self.StepDt = dt
	self.PreviousPosition = self.Position:Copy()
	self.PreviousRotation = self.Rotation:Copy()

	if self.InverseMass == 0 or not self.Awake then return end

	local velocity = self.Velocity + gravity * (
			self.GravityScale * dt
		) + self.AccumulatedForce * (
			self.InverseMass * dt
		)
	local angular_velocity = self.AngularVelocity + self:GetAngularVelocityDelta(self.AccumulatedTorque * dt)
	self.Velocity = clamp_vec_length(velocity, self.MaxLinearSpeed)
	self.AngularVelocity = clamp_vec_length(angular_velocity, self.MaxAngularSpeed)
	self.Position = self.Position + self.Velocity * dt
	self.Rotation = integrate_rotation(self.Rotation, self.AngularVelocity, dt)
end

function META:UpdateVelocities(dt)
	if self.InverseMass == 0 then
		self.Velocity = Vec3(0, 0, 0)
		self.AngularVelocity = Vec3(0, 0, 0)
		return
	end

	if not self.Awake then
		self.Velocity = Vec3(0, 0, 0)
		self.AngularVelocity = Vec3(0, 0, 0)
		self.PreviousPosition = self.Position:Copy()
		self.PreviousRotation = self.Rotation:Copy()
		return
	end

	self.Velocity = (self.Position - self.PreviousPosition) / dt
	local delta = (self.Rotation * self.PreviousRotation:GetConjugated()):GetNormalized()
	self.AngularVelocity = Vec3(delta.x * 2 / dt, delta.y * 2 / dt, delta.z * 2 / dt)

	if delta.w < 0 then self.AngularVelocity = self.AngularVelocity * -1 end

	if self.Grounded then
		local normal_speed = self.Velocity:Dot(self.GroundNormal)

		if normal_speed < 0 then
			self.Velocity = self.Velocity - self.GroundNormal * normal_speed
		end

		if self.Shape == "sphere" and self.Radius > 0 then
			local tangent_velocity = self.Velocity - self.GroundNormal * self.Velocity:Dot(self.GroundNormal)
			local tangent_speed = tangent_velocity:GetLength()

			if tangent_speed > 0.0001 then
				local rolling_angular = self.GroundNormal:GetCross(tangent_velocity) / self.Radius
				local normal_angular = self.GroundNormal * self.AngularVelocity:Dot(self.GroundNormal)
				self.AngularVelocity = rolling_angular + normal_angular
			end
		end
	end

	local linear_damping_value = self.Grounded and self.LinearDamping or self.AirLinearDamping
	local angular_damping_value = self.Grounded and self.AngularDamping or self.AirAngularDamping
	local linear_damping = math.max(1 - linear_damping_value * dt, 0)
	local angular_damping = math.max(1 - angular_damping_value * dt, 0)
	self.Velocity = clamp_vec_length(self.Velocity * linear_damping, self.MaxLinearSpeed)
	self.AngularVelocity = clamp_vec_length(self.AngularVelocity * angular_damping, self.MaxAngularSpeed)
end

function META:GetInverseMassAlong(normal, pos)
	if self.InverseMass == 0 then return 0 end

	local tangent = normal:Copy()

	if pos then tangent = (pos - self.Position):GetCross(normal) end

	tangent = self.Rotation:GetConjugated():VecMul(tangent)
	local angular = tangent.x * tangent.x * self.InverseInertia.x + tangent.y * tangent.y * self.InverseInertia.y + tangent.z * tangent.z * self.InverseInertia.z

	if pos then angular = angular + self.InverseMass end

	return angular
end

function META:_ApplyCorrection(correction, pos)
	if self.InverseMass == 0 then return end

	self.Position = self.Position + correction * self.InverseMass

	if not pos then return end

	local angular = (pos - self.Position):GetCross(correction)
	angular = self.Rotation:GetConjugated():VecMul(angular)
	angular = component_mul(angular, self.InverseInertia)
	angular = self.Rotation:VecMul(angular)
	local delta = Quat(angular.x, angular.y, angular.z, 0) * self.Rotation
	self.Rotation = Quat(
		self.Rotation.x + 0.5 * delta.x,
		self.Rotation.y + 0.5 * delta.y,
		self.Rotation.z + 0.5 * delta.z,
		self.Rotation.w + 0.5 * delta.w
	):GetNormalized()
end

function META:ApplyCorrection(compliance, correction, pos, other_body, other_pos, dt)
	local length = correction:GetLength()

	if length == 0 then return 0 end

	dt = dt or self.StepDt

	if not dt or dt <= 0 then dt = 1 / 60 end

	local normal = correction / length
	local inverse_mass = self:GetInverseMassAlong(normal, pos)

	if other_body then
		inverse_mass = inverse_mass + other_body:GetInverseMassAlong(normal, other_pos)
	end

	if inverse_mass == 0 then return 0 end

	local alpha = (compliance or 0) / (dt * dt)
	local lambda = -length / (inverse_mass + alpha)
	local impulse = normal * -lambda
	self:_ApplyCorrection(impulse, pos)

	if other_body then other_body:_ApplyCorrection(impulse * -1, other_pos) end

	return lambda / (dt * dt)
end

function META:BuildCollisionLocalPoints()
	if self.Shape == "sphere" then
		local r = self.Radius
		return {
			Vec3(0, -r, 0),
			Vec3(0, r, 0),
			Vec3(r, 0, 0),
			Vec3(-r, 0, 0),
			Vec3(0, 0, r),
			Vec3(0, 0, -r),
		}
	end

	local ex = self.Size.x * 0.5
	local ey = self.Size.y * 0.5
	local ez = self.Size.z * 0.5
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, ey, -ez),
		Vec3(-ex, ey, -ez),
		Vec3(-ex, -ey, ez),
		Vec3(ex, -ey, ez),
		Vec3(ex, ey, ez),
		Vec3(-ex, ey, ez),
		Vec3(0, -ey, 0),
		Vec3(0, ey, 0),
		Vec3(ex, 0, 0),
		Vec3(-ex, 0, 0),
		Vec3(0, 0, ez),
		Vec3(0, 0, -ez),
	}
end

function META:GetCollisionLocalPoints()
	if not self.CollisionLocalPoints then
		self.CollisionLocalPoints = self:BuildCollisionLocalPoints()
	end

	return self.CollisionLocalPoints
end

function META:BuildSupportLocalPoints()
	if self.Shape == "sphere" then
		local r = self.Radius
		return {
			Vec3(0, -r, 0),
			Vec3(r * 0.7, -r * 0.7, 0),
			Vec3(-r * 0.7, -r * 0.7, 0),
			Vec3(0, -r * 0.7, r * 0.7),
			Vec3(0, -r * 0.7, -r * 0.7),
		}
	end

	local ex = self.Size.x * 0.5
	local ey = self.Size.y * 0.5
	local ez = self.Size.z * 0.5
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, -ey, ez),
		Vec3(-ex, -ey, ez),
		Vec3(0, -ey, 0),
	}
end

function META:GetSupportLocalPoints()
	if not self.SupportLocalPoints then
		self.SupportLocalPoints = self:BuildSupportLocalPoints()
	end

	return self.SupportLocalPoints
end

return META:Register()