local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local movesets = import("lua/movesets.lua")
local actors = import("lua/actors.lua")
local META = objects.CreateTemplate("move_runner")

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
	local frame = movesets.NewFrame(self.Owner, move, self.frame, target)
	pose:SetFocusOn(frame.target, frame.point)
	self.predicted_focus = pose.FocusPoint

	if authority then
		pose:PlayAction(move.Action, duration)
	else
		pose:PredictAction(move.Action, duration)
	end

	return frame
end

function META:Cancel()
	self.move = nil
	self.listener = nil
end

function META:GetStrikeForward()
	local owner = self.Owner
	local forward = movesets.GetFocus(self.frame) - actors.GetCenter(owner)
	forward.y = 0

	return forward:GetLength() > 1e-3 and forward:GetNormalized() or actors.GetForward(owner)
end

function META:Step(dt, authority, early_cancel)
	local move = self.move
	local owner = self.Owner
	local pose = owner.character_pose

	if pose:IsStunned() then
		local listener = self.listener
		self:Cancel()
		listener:OnMoveInterrupted()
		return "interrupted"
	end

	self.time = self.time + dt
	local frame = self.frame

	if not authority and pose.FocusPoint ~= self.predicted_focus and pose.Action == move.Action then
		self.predicted_focus = pose.FocusPoint
		movesets.Anchor(frame, pose.FocusPoint:Copy())
	end

	local f = math.min(self.time / self.duration, 1)
	movesets.SampleMotion(move, f, frame, frame.point, self.drive)
	self.drive.y = actors.GetCenter(owner).y
	owner.character_movement:Drive(self.drive)
	local event = move.Events[self.next_event]

	while event and f >= event.At do
		self.next_event = self.next_event + 1

		if authority then self.listener:OnMoveEvent(move, event, f) end

		event = move.Events[self.next_event]
	end

	if f >= (early_cancel and move.Cancel or 1) and not event then
		self.move = nil
		return "finished", move
	end
end

return META:Register()
