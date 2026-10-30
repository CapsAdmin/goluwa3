local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local network = import("goluwa/network/network.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local pose_variation = import("lua/pose_variation.lua")
local animations = import("lua/animations/definitions.lua")
local META = objects.CreateTemplate("character_pose")
META.Network = {
	Crouching = {"boolean", 0.1, "reliable"},
	Holding = {"boolean", 0.1, "reliable"},
	Blocking = {"boolean", 0.05, "reliable", to_owner = true},
	States = {"string", 0.05, "reliable"},
	ViewRotation = {"quat", 1 / 60, "sequenced", true},
	Shots = {"number", 0.05, "reliable"},
	Hits = {"number", 0.05, "reliable", to_owner = true},
	Reacts = {"number", 0.05, "reliable", to_owner = true},
	ReactDirection = {"vec3", 0.05, "reliable", to_owner = true},
	ReactIntensity = {"number", 0.05, "reliable", to_owner = true},
	Action = {"string", 0.05, "reliable", to_owner = true},
	ActionDuration = {"number", 0.05, "reliable", to_owner = true},
	Actions = {"number", 0.05, "reliable", to_owner = true},
	Focus = {"entity", 0.05, "reliable", to_owner = true},
	FocusPoint = {"vec3", 0.05, "reliable", to_owner = true},
	Freezes = {"number", 0.05, "reliable", to_owner = true},
	FreezeTime = {"number", 0.05, "reliable", to_owner = true},
	LeanSide = {"number", 1 / 60, "sequenced", true},
	LeanForward = {"number", 1 / 60, "sequenced", true},
	Distance = {"number", 1 / 60, "sequenced", true},
	Seat = {"entity", 0.1, "reliable", to_owner = true},
}
META:IsSet("Crouching", false)
META:IsSet("Holding", false)
META:IsSet("Blocking", false)
META:IsSet("FirstPerson", false)
META:GetSet("ViewRotation", Quat(0, 0, 0, 1))
META:GetSet("Shots", 0)
META:GetSet("Hits", 0)
META:GetSet("Reacts", 0)
META:GetSet("ReactDirection", Vec3(0, 0, -1))
META:GetSet("ReactIntensity", 1)
META:GetSet("States", "")
META:GetSet("Action", "")
META:GetSet("ActionDuration", 0)
META:GetSet("Actions", 0)
META:GetSet("Focus", NULL)
META:GetSet("FocusPoint", Vec3())
META:GetSet("Freezes", 0)
META:GetSet("FreezeTime", 0)
META:GetSet("LeanSide", 0)
META:GetSet("LeanForward", 0)
META:GetSet("Distance", 0)
META:GetSet("Seat", NULL)
local AIR_SPEED = 0.8
local READY_MIN = 2
local READY_MAX = 3
local LAND_SOFT_SPEED = 2
local LAND_HARD_SPEED = 11.5

local function find_instance(anims, def)
	for i = 1, #anims do
		if anims[i].def == def then return anims[i] end
	end
end

local body_position = Vec3()
local body_rotation = Quat()
local seat_position = Vec3()
local seat_rotation = Quat()
local seat_look = Quat()
local SEAT_LOOK_YAW = 1.4
local RELAY_FRESH = 0.3
local PREDICTED_ACTION_WINDOW = 1

function META:Initialize()
	self.pitch = Quat(0, 0, 0, 1)
	self.aim_rotation = Quat(0, 0, 0, 1)
	self.crouch_alpha = 0
	self.crouch_base = 0
	self.forward_speed = 0
	self.right_speed = 0
	self.vertical_speed = 0
	self.grounded = false
	self.seen_shots = self.Shots
	self.seen_hits = self.Hits
	self.seen_reacts = self.Reacts
	self.seen_actions = self.Actions
	self.seen_freezes = self.Freezes
	self.predicted_actions = {}
	self.freeze = 0
	self.seen_ready_shots = self.Shots
	self.anims = {}
	self.state_args = {}
	self.seen_states = ""
	self.crouch_weight = 0
	self.forced_crouch = false
	self.locomotion = true
	self.legs = true
	self.viewing = false
	self.airborne = false
	self.fall_speed = 0
	self.hold_wanted = false
	self.ready_time = 0
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

function META:GetSeatComponent()
	local seat = self.Seat

	if seat:IsValid() then return seat.seat end
end

function META:PlayAction(name, duration)
	self:SetAction(name)
	self:SetActionDuration(duration)
	self:SetActions(self.Actions + 1)
end

function META:StartAction(name, duration)
	local anims = self.anims
	local inst = animations.NewInstance(name)
	inst.duration = math.max(duration, 0.001)

	if inst.def.Group then
		for i = #anims, 1, -1 do
			if anims[i].def.Group == inst.def.Group then table.remove(anims, i) end
		end
	end

	anims[#anims + 1] = inst

	if inst.def.Init then inst.def.Init(inst, self) end
end

function META:PredictAction(name, duration)
	local predicted = self.predicted_actions
	predicted[#predicted + 1] = {name = name, time = system.GetTime()}
	self:StartAction(name, duration)
end

function META:AdoptPredictedAction(name)
	local predicted = self.predicted_actions
	local now = system.GetTime()

	for i = 1, #predicted do
		local entry = predicted[i]

		if entry.name == name and now - entry.time < PREDICTED_ACTION_WINDOW then
			for _ = 1, i do
				table.remove(predicted, 1)
			end

			return true
		end
	end

	for i = #predicted, 1, -1 do
		if now - predicted[i].time >= PREDICTED_ACTION_WINDOW then table.remove(predicted, i) end
	end

	return false
end

function META:SetFocusOn(entity, point)
	self:SetFocus(entity or NULL)
	self:SetFocusPoint(point:Copy())
end

function META:GetFacingPoint()
	local focus = self.Focus

	if focus:IsValid() then
		local body = focus.rigid_body
		return body and body:GetPosition() or focus.transform:GetPosition()
	end

	return self.FocusPoint
end

function META:Freeze(duration)
	self:SetFreezeTime(duration)
	self:SetFreezes(self.Freezes + 1)
	self.seen_freezes = self.Freezes
	self.freeze = duration
end

function META:IsFrozen()
	return self.freeze > 0
end

function META:GetTimeScale()
	return self.freeze > 0 and 0 or self.animation_speed
end

function META:IsStunned()
	local anims = self.anims

	for i = 1, #anims do
		if anims[i].def.Stun and anims[i].weight > 0.5 then return true end
	end

	return false
end

function META:GetActiveAction()
	local anims = self.anims

	for i = #anims, 1, -1 do
		if anims[i].def.Kind == "action" then
			return anims[i].def.Name, anims[i].phase
		end
	end
end

function META:IsPlaying(name)
	local anims = self.anims

	for i = 1, #anims do
		if anims[i].def.Name == name then return true end
	end

	return false
end

function META:GetWeight(name)
	return animations.GetWeight(self, name)
end

function META:SetState(name, arg)
	if self.state_args[name] == arg then return end

	self.state_args[name] = arg
	local names = {}

	for key in pairs(self.state_args) do
		names[#names + 1] = key
	end

	table.sort(names)

	for i, key in ipairs(names) do
		names[i] = key .. "=" .. self.state_args[key]
	end

	self.seen_states = table.concat(names, ";")
	self:SetStates(self.seen_states)
end

function META:Trigger(name, weight)
	local def = animations.Get(name)

	if def.Restart then
		for i = #self.anims, 1, -1 do
			if self.anims[i].def == def then table.remove(self.anims, i) end
		end
	end

	local inst = find_instance(self.anims, def)

	if inst then
		inst.weight = math.max(inst.weight, weight)
		inst.strength = math.max(inst.strength, weight)
	else
		inst = animations.NewInstance(name, weight)
		self.anims[#self.anims + 1] = inst

		if def.Init then def.Init(inst, self) end
	end
end

function META:EnableState(name, arg, weight)
	local inst = find_instance(self.anims, animations.Get(name))

	if not inst then
		inst = animations.NewInstance(name, weight or 0)
		self.anims[#self.anims + 1] = inst
	end

	inst.on = true
	inst.arg = arg
end

function META:UpdateAirborne()
	local air = not self.grounded and
		(
			self.airborne or
			math.abs(self.vertical_speed) > AIR_SPEED
		)

	if air then
		self.fall_speed = math.min(self.fall_speed, self.vertical_speed)
	elseif self.airborne then
		local strength = math.clamp((-self.fall_speed - LAND_SOFT_SPEED) / (LAND_HARD_SPEED - LAND_SOFT_SPEED), 0, 1)

		if strength > 0 then self:Trigger("land", strength) end

		self.fall_speed = 0
	end

	self.airborne = air
end

function META:ApplyView(rotation)
	local anims = self.anims

	for i = 1, #anims do
		local view = anims[i].def.View

		if view then view(anims[i], rotation) end
	end
end

function META:UpdateAnimations(dt)
	local anims = self.anims

	if self.Freezes ~= self.seen_freezes then
		self.seen_freezes = self.Freezes
		self.freeze = self.FreezeTime
	end

	if self.freeze > 0 then
		self.freeze = math.max(self.freeze - dt, 0)
		dt = 0
	end

	if self.States ~= self.seen_states then
		self.seen_states = self.States
		table.clear(self.state_args)

		for name, arg in self.States:gmatch("([^=;]+)=([^;]*)") do
			self.state_args[name] = arg
		end
	end

	if self.Actions ~= self.seen_actions then
		self.seen_actions = self.Actions

		if not self:AdoptPredictedAction(self.Action) then
			self:StartAction(self.Action, self.ActionDuration)
		end
	end

	for _, trigger in ipairs(animations.Triggers) do
		if self[trigger.Counter] ~= self[trigger.Seen] then
			self[trigger.Seen] = self[trigger.Counter]

			for _, def in ipairs(trigger.Defs) do
				self:Trigger(def.Name, 1)
			end
		end
	end

	for i = 1, #anims do
		local inst = anims[i]

		if inst.def.Kind == "state" then inst.on = false end
	end

	for name, arg in pairs(self.state_args) do
		self:EnableState(name, arg)
	end

	local seat = self:GetSeatComponent()
	local previous = self.seated_on

	if previous ~= seat then
		if previous and previous:IsValid() and previous.Occupant == self.Owner then
			previous.Occupant = NULL
		end

		self.seated_on = seat
	end

	if seat then
		seat.Occupant = self.Owner
		self:EnableState("seat", seat.Pose)
	end

	if self:IsBlocking() then self:EnableState("block") end

	if self.hold_wanted then self:EnableState("hold") end

	if self.Shots ~= self.seen_ready_shots then
		self.seen_ready_shots = self.Shots
		self.ready_time = READY_MIN + (
				math.sin(self.seed * 12.9898 + self.Shots * 78.233) * 43758.5453
			) % 1 * (
				READY_MAX - READY_MIN
			)
	end

	self.ready_time = math.max(self.ready_time - dt, 0)
	local holder = self.Owner.weapon_holder
	local right = holder and holder:GetPosedWeapon("right")
	local left = holder and holder:GetPosedWeapon("left")

	if right and not right.weapon:IsHolster() or left and not left.weapon:IsHolster() then
		self:EnableState("ready", nil, 1)
	elseif self.ready_time > 0 then
		self:EnableState("ready")
	end

	if self.airborne then self:EnableState("air") end

	local crouch_weight = 0
	local forced_crouch = false
	local locomotion = true
	local legs = true
	local viewing = false

	for i = #anims, 1, -1 do
		local inst = anims[i]
		local def = inst.def
		local kind = def.Kind
		inst.time = inst.time + dt

		if kind == "action" then
			inst.phase = math.min(inst.time / inst.duration, 1)

			if def.Exit then
				local fade = math.clamp((inst.duration - inst.time) / math.min(def.Exit, inst.duration * 0.5), 0, 1)
				inst.weight = inst.strength * fade * fade * (3 - 2 * fade)
			end

			if inst.time >= inst.duration then inst.dead = true end
		elseif kind == "impulse" then
			inst.weight = inst.weight - dt * def.Decay

			if inst.weight <= 0 then inst.dead = true end
		elseif inst.on then
			inst.end_cycle = nil
			inst.settled = false

			if def.Advance then inst.cycle = inst.cycle + def.Advance(inst, self, dt) end

			inst.raw = math.min(inst.raw + dt / def.Enter, 1)
		else
			if def.Period and not inst.settled then
				inst.end_cycle = inst.end_cycle or math.ceil(inst.cycle / def.Period) * def.Period
				inst.cycle = inst.cycle + def.Advance(inst, self, dt)

				if inst.cycle >= inst.end_cycle then
					inst.cycle = inst.end_cycle
					inst.settled = true
				end
			else
				inst.settled = true
			end

			if inst.settled then
				inst.raw = math.max(inst.raw - dt / def.Exit, 0)

				if inst.raw == 0 then inst.dead = true end
			else
				inst.raw = math.min(inst.raw + dt / def.Enter, 1)
			end
		end

		if kind == "state" then
			inst.weight = inst.raw * inst.raw * (3 - 2 * inst.raw)
		end

		if inst.dead then
			table.remove(anims, i)
		else
			if def.Crouch then
				crouch_weight = math.max(crouch_weight, inst.weight)
				forced_crouch = forced_crouch or inst.weight > 0.5
			end

			if def.Locomotion == false and inst.weight > 0.5 then locomotion = false end

			if def.Legs == false and inst.weight > 0.001 then legs = false end

			if def.View then viewing = true end
		end
	end

	self.crouch_weight = crouch_weight
	self.forced_crouch = forced_crouch
	self.locomotion = locomotion
	self.legs = legs
	self.viewing = viewing
end

function META:RegisterShot()
	self:SetShots(self.Shots + 1)
end

function META:OnTakeDamage(info)
	if not info.Reaction then
		self:SetHits(self.Hits + 1)
		return
	end

	local direction = info.Direction

	if not direction then
		direction = info.Force:GetLength() > 0.01 and info.Force or info.Normal * -1
	end

	self:SetReactDirection(direction:GetNormalized())
	self:SetReactIntensity(info.Reaction == true and 1 or info.Reaction)
	self:SetReacts(self.Reacts + 1)
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
	local link = self.Owner.network

	if not link then return end

	local key = link:GetNetworkOwner()

	if key == "" then key = link:GetNetworkId() end

	if key == -1 or key == self.seed_key then return end

	self.seed_key = key
	self.seed = pose_variation.HashSeed(key)
	self.rate_scale = pose_variation.GetRateScale(self.seed)
end

function META:OnUpdate(dt)
	local owner = self.Owner
	local link = owner.network
	local movement = not (
			link and
			link.linked and
			not network.IsPredicting()
		) and
		owner.character_movement or
		nil
	local transform = owner.transform

	if movement then
		self:SetViewRotation(movement:GetCommand().view:Copy())
		self:SetCrouching(movement:IsCrouching())
		self:SetState("roll", movement:GetRollKind())
	end

	self:UpdateAnimations(dt)
	local anims = self.anims
	local applied = false

	for i = 1, #anims do
		local body = anims[i].def.Body

		if body then
			if not applied then
				applied = true
				local position, rotation = transform:GetRenderPositionRotation()

				if not position then
					position, rotation = transform:GetPosition(), transform:GetRotation()
				end

				body_position:Set(position.x, position.y, position.z)
				body_rotation:Set(rotation.x, rotation.y, rotation.z, rotation.w)
			end

			body(anims[i], self, body_position, body_rotation)
		end
	end

	if applied then
		transform:SetOverridePosition(body_position:Copy())
		transform:SetOverrideRotation(body_rotation:Copy())
		self.body_override = true
	elseif self.body_override then
		self.body_override = false
		transform:SetOverridePosition(nil)
		transform:SetOverrideRotation(nil)
	end

	local rotation = self:GetViewRotation()
	local relay = self.relay_cmd

	if owner.player_input then
		rotation = owner.player_input:GetRotation()
	elseif relay and system.GetTime() - self.relay_time < RELAY_FRESH then
		rotation = relay.view
		self:SetCrouching(usercmd.HasButton(relay, usercmd.BUTTON.CROUCH))
	end

	if self.viewing then
		rotation = rotation:Copy()
		self:ApplyView(rotation)
	end

	self.aim_rotation = rotation
	self.crouch_base = self.crouch_base + (
			(
				self:IsCrouching() and
				1 or
				0
			) - self.crouch_base
		) * math.min(dt * 12, 1)
	self.crouch_alpha = math.max(self.crouch_base, self.crouch_weight)
	local _, entity_rotation = transform:GetRenderPositionRotation()
	entity_rotation = entity_rotation or transform:GetRotation()
	local body = owner.rigid_body
	local velocity = movement and body:GetVelocity() or transform:GetRenderVelocity()
	self.forward_speed = velocity:Dot(entity_rotation:GetForward())
	self.right_speed = velocity:Dot(entity_rotation:GetRight())
	self.vertical_speed = velocity.y
	local seat = self:GetSeatComponent()
	self.grounded = seat ~= nil or
		movement and
		movement:GetGrounded()
		or
		body ~= nil and
		body:GetGrounded()
	self:UpdateAirborne()
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

		if not dead and self.grounded and not seat then
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
	elseif seat then
		self.dead_pitch = nil
		seat:GetRenderFrame(seat_position, seat_rotation)
		seat_look:SetMul(seat_rotation:Conjugate(), rotation)
		local forward = seat_look:GetForward()
		self.pitch:Identity():RotateYaw(
			math.clamp(math.atan2(-forward.x, -forward.z), -SEAT_LOOK_YAW, SEAT_LOOK_YAW) + self.sway_yaw
		):RotatePitch(math.asin(math.clamp(forward.y, -1, 1)) + self.sway_pitch)
	else
		self.dead_pitch = nil
		self.pitch:Identity():RotatePitch(math.asin(math.clamp(rotation:GetForward().y, -1, 1)) + self.sway_pitch):RotateYaw(self.sway_yaw)
	end
end

return META:Register()
