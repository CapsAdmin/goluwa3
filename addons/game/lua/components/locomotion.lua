local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("locomotion")
META:StartStorable()
META:GetSet("IdleSequence", "")
META:GetSet("WalkSequence", "")
META:GetSet("RunSequence", "")
META:EndStorable()
local START_SPEED = 0.3
local STOP_SPEED = 0.12
local RUN_MARGIN = 1.1
local YAW_FOLLOW = 10
local MIN_RATE = 0.3
local MAX_RATE = 2.5

function META:Initialize()
	-- a locomotion in a prefab is initialized once more when the build of its entity ends
	if self.initialized then return end

	self.initialized = true
	self.state = "idle"
	self.move_yaw = 0
	self:AddGlobalEvent("Update")
end

function META:OnUpdate(dt)
	local owner = self.Owner
	local animator = owner.animator
	local skeleton = animator and animator.skeleton

	if not skeleton or dt <= 0 then return end

	local transform = owner.transform
	local velocity = transform:GetRenderVelocity()
	local _, rotation = transform:GetRenderPositionRotation()
	rotation = rotation or transform:GetRotation()
	local forward_speed = velocity:Dot(rotation:GetForward())
	local left_speed = -velocity:Dot(rotation:GetRight())
	local speed = math.sqrt(forward_speed * forward_speed + left_speed * left_speed)
	local params = animator.pose_parameters
	local state = self.state

	if speed < (state == "idle" and START_SPEED or STOP_SPEED) then
		state = "idle"
	else
		local walk = skeleton.ClipsByName[self.WalkSequence]
		local run = skeleton.ClipsByName[self.RunSequence]

		if run and run ~= walk then
			local walk_speed = walk and walk:GetGroundSpeed(params) or 0
			local middle = (walk_speed + run:GetGroundSpeed(params)) / 2
			state = speed > middle * (
					state == "run" and
					1 / RUN_MARGIN or
					RUN_MARGIN
				)
				and
				"run" or
				"walk"
		else
			state = "walk"
		end
	end

	self.state = state
	local sequence = state == "run" and
		self.RunSequence or
		state == "walk" and
		self.WalkSequence or
		self.IdleSequence

	if sequence ~= self.sequence then
		self.sequence = sequence
		animator:SetSequence(sequence)
	end

	local clip = skeleton.ClipsByName[sequence]
	local rate = 1

	if state ~= "idle" and clip then
		local ground_speed = clip:GetGroundSpeed(params)

		if ground_speed > 0 then
			rate = math.clamp(speed / ground_speed, MIN_RATE, MAX_RATE)
		end
	end

	animator:SetSpeed(rate)
	local range = skeleton.PoseParameterRanges.move_yaw

	if range and state ~= "idle" then
		local target = math.deg(math.atan2(left_speed, forward_speed))
		local difference = (target - self.move_yaw + 180) % 360 - 180
		self.move_yaw = math.clamp(self.move_yaw + difference * math.min(dt * YAW_FOLLOW, 1), range[1], range[2])
		animator:SetPoseParameterByName("move_yaw", self.move_yaw)
	end
end

return META:Register()
