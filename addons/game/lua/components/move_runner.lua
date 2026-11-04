local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local movesets = import("lua/movesets.lua")
local actors = import("lua/actors.lua")
local camera_modes = import("lua/camera_modes.lua")
local META = objects.CreateTemplate("move_runner")
local CRASH_GRACE = 0.4
local CRASH_SPEED = 0.35
local CRASH_TICKS = 2
local RUN_LEAD = 1.1
local LAND_DIVE_SPEED = 16
local LAND_HOLD_MAX = 4
local REWIND_TIME = 0.2
local WALL_GRACE = 0.1
local WALL_MIN_SPEED = 2
local WALL_RATIO = 0.3
local WALL_TICKS = 3

local function owner_origin(owner)
	return owner.rigid_body:GetPosition():Copy()
end

function META:Initialize()
	self.frame = {}
	self.drive = Vec3()
end

function META:IsPlaying()
	return self.move ~= nil
end

function META:Begin(move, duration, listener, authority, target)
	local pose = self.Owner.character_pose
	self.move = move
	self.listener = listener
	self.time = 0
	self.duration = duration
	self.next_event = 1
	self.slow_ticks = 0
	self.land_time = 0
	self.land_drop = 0
	self.wall_ticks = 0
	self.flinching = pose:IsPlaying("flinch")
	self.drive_speed = 0
	self.drive_x, self.drive_z = 0, 0
	self.rewind_time = nil
	self.rewind_origin = owner_origin(self.Owner)
	local frame = movesets.NewFrame(self.Owner, move, self.frame, target)
	pose:SetFocusOn(frame.target, frame.point)

	if frame.target then camera_modes.AttackTarget(self.Owner, frame.target) end

	self.predicted_focus = pose.FocusPoint

	if authority then
		self.Owner:CallLocalEvent("OnMoveBegin", move)
		pose:PlayAction(move.Action, duration)
	else
		pose:PredictAction(move.Action, duration)
	end

	return frame
end

function META:IsRewinding()
	return self.rewind_time ~= nil
end

function META:Rewind(authority, wall)
	local owner = self.Owner
	local pose = owner.character_pose
	self.rewind_time = 0
	self.rewind_from = owner_origin(owner)

	if pose:IsLandHold() then pose:SetLandHold(false) end

	pose:RewindAction(REWIND_TIME)
	local pending

	if wall and authority then
		for i = self.next_event, #self.move.Events do
			if self.move.Events[i].Type == "hit" then
				pending = self.move.Events[i]

				break
			end
		end
	end

	self.listener:OnMoveCanceled(self.move, pending)
end

function META:Cancel()
	self.rewind_time = nil
	self.move = nil
	self.listener = nil
	local pose = self.Owner.character_pose

	if pose:IsLandHold() then pose:SetLandHold(false) end
end

function META:GetStrikeForward()
	local owner = self.Owner
	local forward = movesets.GetFocus(self.frame) - actors.GetCenter(owner)
	forward.y = 0
	return forward:GetLength() > 1e-3 and
		forward:GetNormalized() or
		actors.GetForward(owner)
end

do
	local function step(self, dt, authority, early_cancel)
		local move = self.move
		local owner = self.Owner
		local pose = owner.character_pose

		if not self.listener:IsValid() then
			self:Cancel()
			return "interrupted"
		end

		if pose:IsStunned() then
			local listener = self.listener
			self:Cancel()
			listener:OnMoveInterrupted()
			return "interrupted"
		end

		local flinching = pose:IsPlaying("flinch")

		if flinching and not self.flinching then
			local listener = self.listener
			self:Cancel()
			listener:OnMoveInterrupted()
			return "interrupted"
		end

		self.flinching = flinching

		if self.rewind_time then
			self.rewind_time = self.rewind_time + dt
			local t = math.min(self.rewind_time / REWIND_TIME, 1)
			local from, origin = self.rewind_from, self.rewind_origin
			local drive = self.drive
			drive.x = math.lerp(t, from.x, origin.x)
			drive.z = math.lerp(t, from.z, origin.z)
			drive.y = move.Vertical and
				math.lerp(t, from.y, origin.y) or
				owner.rigid_body:GetPosition().y
			owner.character_movement:Drive(drive, move.Vertical)

			if t >= 1 then
				self.move = nil
				self.rewind_time = nil
				return "canceled", move
			end

			return
		end

		self.time = self.time + dt
		local frame = self.frame

		if
			not authority and
			pose.FocusPoint ~= self.predicted_focus and
			pose.Action == move.Action
		then
			self.predicted_focus = pose.FocusPoint
			movesets.Anchor(frame, pose.FocusPoint:Copy())
		end

		if not move.Crash and self.time > WALL_GRACE then
			local position = owner.rigid_body:GetPosition()
			local dx, dz = position.x - self.drive_x, position.z - self.drive_z
			local speed = math.sqrt(dx * dx + dz * dz) / dt
			local blocked = self.drive_speed > WALL_MIN_SPEED and speed < self.drive_speed * WALL_RATIO
			self.wall_ticks = blocked and self.wall_ticks + 1 or 0

			if self.wall_ticks >= WALL_TICKS then
				self:Rewind(authority, true)
				return
			end
		end

		local f = math.min(self.time / self.duration, 1)
		local landing = move.Land ~= nil and
			f >= move.Land and
			not owner.character_movement:GetGrounded()
			and
			self.land_time < LAND_HOLD_MAX

		if landing then
			self.land_time = self.land_time + dt
			self.land_drop = self.land_drop + LAND_DIVE_SPEED * dt
			self.time = move.Land * self.duration
			f = move.Land
		end

		if pose:IsLandHold() ~= landing then pose:SetLandHold(landing) end

		local _, height = movesets.SampleMotion(move, f, frame, frame.point, self.drive)
		local body = owner.rigid_body

		if move.Vertical then
			self.drive.y = body:GetPosition().y + frame.start.y + height - self.land_drop - actors.GetCenter(owner).y
		else
			self.drive.y = body:GetPosition().y
		end

		if move.Speed then
			local position = body:GetOriginPosition()
			local dx, dz = self.drive.x - position.x, self.drive.z - position.z
			local length = math.sqrt(dx * dx + dz * dz)
			local lead = move.Speed * dt * RUN_LEAD

			if length > lead then
				self.drive.x = position.x + dx / length * lead
				self.drive.z = position.z + dz / length * lead
			end
		end

		local position = body:GetPosition()
		local dx, dz = self.drive.x - position.x, self.drive.z - position.z
		self.drive_speed = math.sqrt(dx * dx + dz * dz) / dt
		self.drive_x, self.drive_z = position.x, position.z
		owner.character_movement:Drive(self.drive, move.Vertical)
		local event = move.Events[self.next_event]

		while event and f >= event.At and not (landing and event.At >= move.Land) do
			if event.Until and f < event.Until then
				if authority and self.listener:OnMoveEvent(move, event, f) == "end" then
					self.move = nil
					return "finished", move
				end

				break
			end

			self.next_event = self.next_event + 1

			if authority and self.listener:OnMoveEvent(move, event, f) == "end" then
				self.move = nil
				return "finished", move
			end

			if self.rewind_time then return end

			event = move.Events[self.next_event]
		end

		if move.Speed then
			if frame.distance - move.Speed * self.time <= movesets.MinGap then
				self.move = nil
				return "finished", move
			end

			if move.Crash and self.time > CRASH_GRACE then
				local velocity = owner.rigid_body:GetVelocity()
				local speed = math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
				self.slow_ticks = speed < move.Speed * CRASH_SPEED and self.slow_ticks + 1 or 0

				if self.slow_ticks >= CRASH_TICKS then
					self.move = nil
					return "blocked", move
				end
			end
		end

		if f >= (early_cancel and move.Cancel or 1) and not event and not landing then
			self.move = nil
			return "finished", move
		end
	end

	function META:Step(dt, authority, early_cancel)
		local state, move = step(self, dt, authority, early_cancel)
		local pose = self.Owner.character_pose

		if state and pose:IsLandHold() then pose:SetLandHold(false) end

		return state, move
	end
end

return META:Register()
