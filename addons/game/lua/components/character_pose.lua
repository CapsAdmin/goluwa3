local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local pose_variation = import("lua/pose_variation.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local META = objects.CreateTemplate("character_pose")
META.Network = {
	Crouching = {"boolean", 0.1, "reliable"},
	Holding = {"boolean", 0.1, "reliable"},
	Blocking = {"boolean", 0.05, "reliable"},
	Roll = {"string", 0.05, "reliable"},
	ViewRotation = {"quat", 1 / 20, "sequenced", true},
	Shots = {"number", 0.05, "reliable"},
	Hits = {"number", 0.05, "reliable"},
	Action = {"string", 0.05, "reliable"},
	ActionDuration = {"number", 0.05, "reliable"},
	Actions = {"number", 0.05, "reliable"},
	LeanSide = {"number", 1 / 20, "sequenced", true},
	LeanForward = {"number", 1 / 20, "sequenced", true},
	Distance = {"number", 1 / 20, "sequenced", true},
}
META:IsSet("Crouching", false)
META:IsSet("Holding", false)
META:IsSet("Blocking", false)
META:IsSet("FirstPerson", false)
META:GetSet("ViewRotation", Quat(0, 0, 0, 1))
META:GetSet("Shots", 0)
META:GetSet("Hits", 0)
META:GetSet("Roll", "")
META:GetSet("Action", "")
META:GetSet("ActionDuration", 0)
META:GetSet("Actions", 0)
META:GetSet("LeanSide", 0)
META:GetSet("LeanForward", 0)
META:GetSet("Distance", 0)
local PIVOT = 0.4
local PIVOT_FORWARD = 0.2
local PIVOT_HEIGHT = 0.15
local TURN = math.pi * 2
local ROLL_RATE = 13
local ROLL_REFERENCE_SPEED = 220 * UNIT
local ROLL_SURGE = 0.3
local ROLL_DRIFT = 0.12
local ROLL_EASE = math.pi / 2
local ROLLS = {
	forward = {"RotatePitch", -1},
	back = {"RotatePitch", 1},
	left = {"RotateRoll", 1},
	right = {"RotateRoll", -1},
}
local pivot = Vec3(0, PIVOT, 0) + Quat(0, 0, 0, 1):GetForward() * PIVOT_FORWARD
local RELAY_FRESH = 0.3
local RECOIL_DECAY = 8
local FLINCH_DECAY = 4

function META:Initialize()
	self.pitch = Quat(0, 0, 0, 1)
	self.aim_rotation = Quat(0, 0, 0, 1)
	self.crouch_alpha = 0
	self.forward_speed = 0
	self.right_speed = 0
	self.vertical_speed = 0
	self.grounded = false
	self.recoil = 0
	self.flinch = 0
	self.seen_shots = self.Shots
	self.seen_hits = self.Hits
	self.seen_actions = self.Actions
	self.action = nil
	self.action_time = 0
	self.action_fraction = 0
	self.rolling = false
	self.roll_kind = nil
	self.roll_angle = 0
	self.roll_time = 0
	self.roll_end = nil
	self.block_alpha = 0
	self.roll_alpha = 0
	self.animation_speed = 1
	self.seed = math.random()
	self.rate_scale = pose_variation.GetRateScale(self.seed)
	self.rate_variation = self.rate_scale
	self.last_velocity = nil
	self.acceleration_forward = 0
	self.acceleration_right = 0
	self.lean_forward = 0
	self.lean_side = 0
	self.sway_pitch = 0
	self.sway_yaw = 0
	self:AddGlobalEvent("Update")
end

function META:PlayAction(name, duration)
	self:SetAction(name)
	self:SetActionDuration(duration)
	self:SetActions(self.Actions + 1)
end

function META:GetActiveAction()
	return self.action, self.action_fraction
end

function META:ApplyRollTurn(rotation)
	local roll = ROLLS[self.roll_kind]
	rotation[roll[1]](rotation, roll[2] * self.roll_angle)
end

function META:RegisterShot()
	self:SetShots(self.Shots + 1)
end

function META:OnTakeDamage()
	self:SetHits(self.Hits + 1)
end

function META:ApplyRelayedCommands(commands)
	for _, cmd in ipairs(commands) do
		if cmd.number > (self.relay_number or 0) then
			self.relay_number = cmd.number
			self.relay_cmd = cmd
			self.relay_time = system.GetTime()
		end
	end
end

function META:UpdateSeed()
	local network = self.Owner.network

	if not network then return end

	local key = network:GetNetworkOwner()

	if key == "" then key = network:GetNetworkId() end

	if key == -1 or key == self.seed_key then return end

	self.seed_key = key
	self.seed = pose_variation.HashSeed(key)
	self.rate_scale = pose_variation.GetRateScale(self.seed)
end

function META:OnUpdate(dt)
	local owner = self.Owner
	local movement = owner.character_movement
	local transform = owner.transform

	if movement then
		self:SetViewRotation(movement:GetCommand().view:Copy())
		self:SetCrouching(movement:IsCrouching())
		self:SetRoll(movement:GetRollKind())
	end

	if self.Shots ~= self.seen_shots then
		self.seen_shots = self.Shots
		self.recoil = 1
	end

	if self.Hits ~= self.seen_hits then
		self.seen_hits = self.Hits
		self.flinch = 1
	end

	if self.Actions ~= self.seen_actions then
		self.seen_actions = self.Actions
		self.action = self.Action
		self.action_time = 0
	end

	if self.action then
		self.action_time = self.action_time + dt
		self.action_fraction = math.min(self.action_time / math.max(self.ActionDuration, 0.001), 1)

		if self.action_time >= self.ActionDuration then self.action = nil end
	end

	if self.Roll ~= "" then
		if not self.roll_kind then
			self.roll_angle = 0
			self.roll_time = 0
		end

		self.roll_kind = self.Roll
		self.roll_end = nil
	elseif self.roll_kind and not self.roll_end then
		self.roll_end = math.ceil(self.roll_angle / TURN) * TURN
	end

	if self.roll_kind then
		self.roll_time = self.roll_time + dt
		local speed = math.clamp(math.sqrt(self.forward_speed ^ 2 + self.right_speed ^ 2) / ROLL_REFERENCE_SPEED, 0.4, 2)
		self.roll_angle = self.roll_angle + ROLL_RATE * speed * dt * (
				1 - ROLL_SURGE * math.cos(self.roll_angle) + ROLL_DRIFT * math.sin(self.roll_time * 3 + self.seed * TURN)
			)

		if self.roll_end and self.roll_angle >= self.roll_end then
			self.roll_kind = nil
			self.roll_end = nil
			self.roll_angle = 0
		end
	end

	self.rolling = self.roll_kind ~= nil

	if self.rolling then
		local position, rotation = transform:GetRenderPositionRotation()

		if not position then
			position, rotation = transform:GetPosition(), transform:GetRotation()
		end

		local turned = rotation:Copy()
		self:ApplyRollTurn(turned)
		local blend = math.min(self.roll_angle / ROLL_EASE, 1)

		if self.roll_end then
			blend = math.min(blend, (self.roll_end - self.roll_angle) / ROLL_EASE)
		end

		local height = math.lerp(math.clamp(blend, 0, 1), PIVOT, PIVOT_HEIGHT)
		transform:SetOverridePosition(
			position + rotation:VecMul(pivot) + Vec3(0, height - PIVOT, 0) - turned:VecMul(pivot)
		)
		transform:SetOverrideRotation(turned)
		self.roll_override = true
	elseif self.roll_override then
		self.roll_override = false
		transform:SetOverridePosition(nil)
		transform:SetOverrideRotation(nil)
	end

	self.block_alpha = self.block_alpha + (
			(
				self:IsBlocking() and
				1 or
				0
			) - self.block_alpha
		) * math.min(dt * 14, 1)
	self.roll_alpha = self.roll_alpha + (
			(
				self.rolling and
				1 or
				0
			) - self.roll_alpha
		) * math.min(dt * 10, 1)
	self.recoil = math.max(self.recoil - dt * RECOIL_DECAY, 0)
	self.flinch = math.max(self.flinch - dt * FLINCH_DECAY, 0)
	local rotation = self:GetViewRotation()
	local relay = self.relay_cmd

	if owner.player_input then
		rotation = owner.player_input:GetRotation()
	elseif relay and system.GetTime() - self.relay_time < RELAY_FRESH then
		rotation = relay.view
		self:SetCrouching(usercmd.HasButton(relay, usercmd.BUTTON.CROUCH))
	end

	if self.rolling then
		rotation = rotation:Copy()
		self:ApplyRollTurn(rotation)
	end

	self.aim_rotation = rotation
	self.crouch_alpha = self.crouch_alpha + (
			(
				(
					self:IsCrouching() or
					self.rolling
				)
				and
				1 or
				0
			) - self.crouch_alpha
		) * math.min(dt * 12, 1)
	local _, entity_rotation = transform:GetRenderPositionRotation()
	entity_rotation = entity_rotation or transform:GetRotation()
	local body = owner.rigid_body
	local velocity = movement and body:GetVelocity() or transform:GetRenderVelocity()
	self.forward_speed = velocity:Dot(entity_rotation:GetForward())
	self.right_speed = velocity:Dot(entity_rotation:GetRight())
	self.vertical_speed = velocity.y
	self.grounded = movement and movement:GetGrounded() or body ~= nil and body:GetGrounded()
	local dead = movement and movement.dead
	local speed = math.sqrt(self.forward_speed ^ 2 + self.right_speed ^ 2)

	if movement then
		self:SetDistance(movement.distance)
		local last_velocity = self.last_velocity

		if last_velocity and dt > 0 then
			local forward = entity_rotation:GetForward()
			local right = entity_rotation:GetRight()
			local ax = (velocity.x - last_velocity.x) / dt
			local az = (velocity.z - last_velocity.z) / dt
			local limit = pose_variation.MaxAcceleration
			local follow = math.min(dt * pose_variation.AccelerationFollow, 1)
			self.acceleration_forward = self.acceleration_forward + (
					math.clamp(ax * forward.x + az * forward.z, -limit, limit) - self.acceleration_forward
				) * follow
			self.acceleration_right = self.acceleration_right + (
					math.clamp(ax * right.x + az * right.z, -limit, limit) - self.acceleration_right
				) * follow
			last_velocity:Set(velocity.x, velocity.y, velocity.z)
		elseif not last_velocity then
			self.last_velocity = Vec3(velocity.x, velocity.y, velocity.z)
		end

		local target_side, target_forward = 0, 0

		if not dead and self.grounded then
			local max_lean = pose_variation.MaxLean
			target_side = math.clamp(
				math.atan(self.acceleration_right / pose_variation.Gravity) * pose_variation.LeanSideGain,
				-max_lean,
				max_lean
			)
			target_forward = math.clamp(
				math.atan(self.acceleration_forward / pose_variation.Gravity) * pose_variation.LeanForwardGain,
				-max_lean,
				max_lean
			)
		end

		self:SetLeanSide(target_side)
		self:SetLeanForward(target_forward)
	end

	local lean_follow = math.min(dt * pose_variation.LeanFollow, 1)
	self.lean_side = self.lean_side + (self.LeanSide - self.lean_side) * lean_follow
	self.lean_forward = self.lean_forward + (self.LeanForward - self.lean_forward) * lean_follow
	self:UpdateSeed()
	local time = system.GetGameTime()
	local stillness = 1 - (
			1 - pose_variation.SwayWalkAmount
		) * math.clamp(speed / pose_variation.SwaySpeed, 0, 1)
	self.sway_pitch = pose_variation.Noise(self.seed, 1, time) * pose_variation.SwayPitch * stillness
	self.sway_yaw = pose_variation.Noise(self.seed, 2, time) * pose_variation.SwayYaw * stillness
	self.rate_variation = self.rate_scale * (
			1 + pose_variation.Noise(self.seed, 3, time) * pose_variation.RateDrift
		)

	if dead then
		self.dead_pitch = self.dead_pitch or self.pitch
		self.pitch = self.dead_pitch
	else
		self.dead_pitch = nil
		self.pitch:Identity():RotatePitch(math.asin(math.clamp(rotation:GetForward().y, -1, 1)) + self.sway_pitch):RotateYaw(self.sway_yaw)
	end
end

return META:Register()
