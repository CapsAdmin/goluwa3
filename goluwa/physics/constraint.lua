local event = import("goluwa/event.lua")
local islands = import("goluwa/physics/islands.lua")
local rows = import("goluwa/physics/constraint_rows.lua")
local Quat = import("goluwa/structs/quat.lua")
local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("physics_constraint")
local CONJUGATE = Quat()
local tracked = {}
local pose_stamp = 0
local broken = {}
META.CollideConnected = false

function META.Track(constraint)
	tracked[#tracked + 1] = constraint
	return constraint
end

function META.Untrack(constraint)
	for i = 1, #tracked do
		if tracked[i] == constraint then
			table.remove(tracked, i)
			return
		end
	end
end

function META.InvalidatePoses()
	pose_stamp = pose_stamp + 1
end

function META.GetConstraints()
	return tracked
end

function META.RemoveAllConstraints()
	for i = #tracked, 1, -1 do
		tracked[i]:Remove()
	end
end

function META:SetupFrames(body_0, body_1, world_anchor_0, world_frame, world_anchor_1)
	world_frame = world_frame or Quat():Identity()
	world_anchor_1 = world_anchor_1 or world_anchor_0
	self.Body0 = body_0
	self.Body1 = body_1
	self.WorldAnchor0 = world_anchor_0:Copy()
	self.WorldAnchor1 = world_anchor_1:Copy()
	self.WorldFrame = world_frame:Copy()

	if body_0 then
		self.LocalAnchor0 = body_0:WorldToLocal(world_anchor_0)
		self.LocalFrame0 = Quat.SetMul(Quat(), Quat.SetConjugated(CONJUGATE, body_0.Rotation), world_frame)
	end

	if body_1 then
		self.LocalAnchor1 = body_1:WorldToLocal(world_anchor_1)
		self.LocalFrame1 = Quat.SetMul(Quat(), Quat.SetConjugated(CONJUGATE, body_1.Rotation), world_frame)
	end

	self.State0 = rows.NewState()
	self.State1 = rows.NewState()
	self.Enabled = true
	self.LinearX, self.LinearY, self.LinearZ = 0, 0, 0
	self.AngularX, self.AngularY, self.AngularZ = 0, 0, 0
	self.Force = 0
	self.Torque = 0

	if body_0 and body_1 and not self.CollideConnected then
		body_0:IgnoreCollisionWith(body_1)
	end

	return META.Track(self)
end

function META:SetEnabled(enabled)
	self.Enabled = enabled ~= false
	return self
end

function META:SetBreakForce(force)
	self.BreakForce = force
	return self
end

function META:SetBreakTorque(torque)
	self.BreakTorque = torque
	return self
end

function META:GetReactionForce()
	return self.Force
end

function META:GetReactionTorque()
	return self.Torque
end

function META:Break()
	self.Enabled = false
	broken[#broken + 1] = self
	event.Call("PhysicsConstraintBroken", self)
end

function META.RemoveBroken()
	for i = #broken, 1, -1 do
		broken[i]:Remove()
		broken[i] = nil
	end
end

function META:AddLinearImpulse(x, y, z)
	self.LinearX = self.LinearX + x
	self.LinearY = self.LinearY + y
	self.LinearZ = self.LinearZ + z
end

function META:AddAngularImpulse(x, y, z)
	self.AngularX = self.AngularX + x
	self.AngularY = self.AngularY + y
	self.AngularZ = self.AngularZ + z
end

function META:BeginStep(dt)
	if not self.Enabled then return end

	local lx, ly, lz = self.LinearX, self.LinearY, self.LinearZ
	local ax, ay, az = self.AngularX, self.AngularY, self.AngularZ
	self.Force = math.sqrt(lx * lx + ly * ly + lz * lz) / dt
	self.Torque = math.sqrt(ax * ax + ay * ay + az * az) / dt
	self.LinearX, self.LinearY, self.LinearZ = 0, 0, 0
	self.AngularX, self.AngularY, self.AngularZ = 0, 0, 0
	local break_force = self.BreakForce
	local break_torque = self.BreakTorque

	if
		(
			break_force and
			self.Force > break_force
		)
		or
		(
			break_torque and
			self.Torque > break_torque
		)
	then
		self:Break()
	end
end

function META:WarmStart() end

function META:Prepare()
	local body_0 = self.Body0
	local body_1 = self.Body1
	local movable_0 = body_0 and body_0:HasSolverMass()
	local movable_1 = body_1 and body_1:HasSolverMass()

	if not (movable_0 or movable_1) then return false end

	if not (movable_0 and body_0.Awake or movable_1 and body_1.Awake) then
		return false
	end

	if movable_0 then body_0:Wake() end

	if movable_1 then body_1:Wake() end

	if self.LoadedPose == pose_stamp then return true end

	self.LoadedPose = pose_stamp
	rows.Load(
		self.State0,
		body_0,
		self.LocalAnchor0,
		self.LocalFrame0,
		self.WorldAnchor0,
		self.WorldFrame
	)
	rows.Load(
		self.State1,
		body_1,
		self.LocalAnchor1,
		self.LocalFrame1,
		self.WorldAnchor1,
		self.WorldFrame
	)
	return true
end

function META:LoadStates()
	rows.Load(
		self.State0,
		self.Body0,
		self.LocalAnchor0,
		self.LocalFrame0,
		self.WorldAnchor0,
		self.WorldFrame
	)
	rows.Load(
		self.State1,
		self.Body1,
		self.LocalAnchor1,
		self.LocalFrame1,
		self.WorldAnchor1,
		self.WorldFrame
	)
	return self.State0, self.State1
end

function META:GetAnchorError()
	local s0, s1 = self:LoadStates()
	local dx, dy, dz = s1.px - s0.px, s1.py - s0.py, s1.pz - s0.pz
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function META:GetRotationError()
	local s0, s1 = self:LoadStates()
	local x, y, z = rows.GetRotationError(s0, s1)
	return math.sqrt(x * x + y * y + z * z)
end

function META:OnRemove()
	self.Enabled = false
	META.Untrack(self)
	islands.RemoveConstraint(self)

	if self.Body0 and self.Body1 and not self.CollideConnected then
		self.Body0:RestoreCollisionWith(self.Body1)
	end
end

return META:Register()
