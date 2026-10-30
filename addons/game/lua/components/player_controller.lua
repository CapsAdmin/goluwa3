local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local network = import("goluwa/network/network.lua")
local physics = import("goluwa/physics.lua")
local CharacterMovement = import("lua/components/character_movement.lua")
local system = import("goluwa/system.lua")
local raycast = RENDER_3D and import("goluwa/render3d/raycast.lua")
local META = objects.CreateTemplate("player_controller")
local HISTORY_SIZE = 256
local MIN_BUFFER = 2
local START_BUFFER = 6
local MAX_BUFFER = 14
local BACKLOG_SLACK = 12
local DRAIN_SLACK = 1
local DRAIN_INTERVAL = 30
local REST_SPEED = 0.05
local MAX_REPEATS = 15
local SHRINK_WINDOW = 120
local CORRECTION_DECAY = 10
local DISTANCE_TOLERANCE = 0.01
local POSITION_TOLERANCE = 0.002
local VELOCITY_TOLERANCE = 0.3
local ACK_LOG_SIZE = 64
META:GetSet("Source", "local")
META:GetSet("Networked", false)

function META:Initialize()
	self.cmd = usercmd.New()
	self.number = 0
	self.queue = {}
	self.queue_head = 1
	self.last_queued = 0
	self.starved = 0
	self.buffering = true
	self.buffer_target = START_BUFFER
	self.drain_ticks = 0
	self.skipped = 0
	self.consumed = 0
	self.window_spare = math.huge
	self.history = {}
	self.processed = {
		number = 0,
		position = Vec3(),
		velocity = Vec3(),
		grounded = false,
		distance = 0,
	}
	self.correction_offset = Vec3()
	self.corrections = 0
	self.last_ack = {
		number = 0,
		time = 0,
		error = 0,
		velocity_error = 0,
		distance_error = 0,
		corrected = false,
		server_position = Vec3(),
		predicted_position = Vec3(),
		server_velocity = Vec3(),
		predicted_velocity = Vec3(),
	}
	self.ack_log = {}
	self.ack_log_index = 0
	self.ack_missed = 0
	self.recent = {}
	self:AddGlobalEvent("Update")
end

function META:OnUpdate(dt)
	local offset = self.correction_offset

	if offset.x ~= 0 or offset.y ~= 0 or offset.z ~= 0 then
		local keep = math.exp(-CORRECTION_DECAY * dt)
		offset:Set(offset.x * keep, offset.y * keep, offset.z * keep)

		if offset:GetLength() < 0.0005 then offset:Set(0, 0, 0) end
	end
end

function META:GetCorrectionOffset()
	return self.correction_offset
end

function META:RecordState()
	local body = self.Owner.rigid_body
	local entry = self.history[self.number % HISTORY_SIZE]

	if not entry or entry.number ~= self.number then
		entry = {
			number = self.number,
			position = Vec3(),
			velocity = Vec3(),
			grounded = false,
			distance = 0,
		}
		self.history[self.number % HISTORY_SIZE] = entry
	end

	entry.position:CopyFrom(body:GetPosition())
	entry.velocity:CopyFrom(body:GetVelocity())
	entry.grounded = body:GetGrounded()
	entry.distance = self.Owner.character_movement.distance
	self.processed = entry
end

function META:GetHistory(number)
	local entry = self.history[number % HISTORY_SIZE]

	if entry and entry.number == number then return entry end
end

function META:PushCommands(commands)
	for _, cmd in ipairs(commands) do
		if cmd.number > self.last_queued then
			self.last_queued = cmd.number
			self.queue[#self.queue + 1] = cmd
		end
	end
end

function META:GetQueueSize()
	return #self.queue - self.queue_head + 1
end

local function can_skip_idle(self, cmd)
	local previous = self.cmd
	return cmd.forward == 0 and
		cmd.side == 0 and
		cmd.up == 0 and
		cmd.select == 0 and
		cmd.scroll == 0 and
		cmd.rotate_x == 0 and
		cmd.rotate_y == 0 and
		cmd.buttons == previous.buttons and
		cmd.mode == previous.mode and
		self.Owner.rigid_body:GetVelocity():GetLength() < REST_SPEED
end

local function next_queued(self)
	local queue = self.queue
	local size = #queue - self.queue_head + 1

	if self.buffering then
		if size < self.buffer_target then return nil end

		self.buffering = false
	end

	if size <= 0 then
		self.queue = {}
		self.queue_head = 1
		self.buffering = true
		self.buffer_target = math.min(self.buffer_target + 2, MAX_BUFFER)
		self.consumed = 0
		self.window_spare = math.huge
		return nil
	end

	if size > self.buffer_target + BACKLOG_SLACK then
		self.queue_head = self.queue_head + (size - self.buffer_target - BACKLOG_SLACK / 2)
	elseif size > self.buffer_target + DRAIN_SLACK then
		self.drain_ticks = self.drain_ticks + 1

		if self.drain_ticks >= DRAIN_INTERVAL or can_skip_idle(self, queue[self.queue_head]) then
			queue[self.queue_head] = false
			self.queue_head = self.queue_head + 1
			self.drain_ticks = 0
			self.skipped = self.skipped + 1
		end
	else
		self.drain_ticks = 0
	end

	local cmd = queue[self.queue_head]
	queue[self.queue_head] = false
	self.queue_head = self.queue_head + 1
	self.consumed = self.consumed + 1
	self.window_spare = math.min(self.window_spare, #queue - self.queue_head + 1)

	if self.consumed >= SHRINK_WINDOW then
		if self.window_spare > 1 then
			self.buffer_target = math.max(self.buffer_target - (self.window_spare - 1), MIN_BUFFER)
		end

		self.consumed = 0
		self.window_spare = math.huge
	end

	if self.queue_head > #queue then
		self.queue = {}
		self.queue_head = 1
	end

	return cmd
end

local TELEPORT_DISTANCE = 4
local TELEPORT_MAX_DISTANCE = 2000
local TELEPORT_TRACE_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

local function is_not_owner(entity, owner)
	return entity ~= owner and not entity:ContainsParent(owner)
end

function META:TeleportToAim(cmd)
	local owner = self.Owner
	local movement = owner.character_movement
	local origin = owner.transform:GetPosition() + movement:GetViewOffset()
	local direction = cmd.aim:GetForward()
	local hit = physics.RayCast(origin, direction, TELEPORT_MAX_DISTANCE, owner, nil, TELEPORT_TRACE_OPTIONS)

	if raycast and not network.IsStarted() then
		local visual = raycast.CastClosest(origin, direction, TELEPORT_MAX_DISTANCE, is_not_owner, owner)

		if visual and (not hit or visual.distance < hit.distance) then
			hit = visual
		end
	end

	if not hit then return end

	movement:TeleportTo(hit.position + hit.normal * movement.Radius + Vec3(0, 0.05, 0))
end

function META:Reconcile(number, position, velocity, distance)
	local body = self.Owner.rigid_body
	local movement = self.Owner.character_movement
	local entry = self:GetHistory(number)

	if not entry then
		self.ack_missed = self.ack_missed + 1
		return 0
	end

	if movement:IsSeated() then
		self.correction_offset:Set(0, 0, 0)
		return 0
	end

	local distance_error = distance - entry.distance

	if math.abs(distance_error) > DISTANCE_TOLERANCE then
		movement.distance = movement.distance + distance_error

		for n = number, self.number do
			local later = self:GetHistory(n)

			if later then later.distance = later.distance + distance_error end
		end
	end

	local position_error = position - entry.position
	local velocity_error = velocity - entry.velocity
	local magnitude = position_error:GetLength()
	local velocity_error_length = velocity_error:GetLength()
	local velocity_matters = velocity_error_length >= VELOCITY_TOLERANCE
	local corrected = magnitude >= POSITION_TOLERANCE or velocity_matters
	local ack = self.last_ack
	ack.number = number
	ack.time = system.GetTime()
	ack.error = magnitude
	ack.velocity_error = velocity_error_length
	ack.distance_error = distance_error
	ack.corrected = corrected
	ack.server_position:Set(position.x, position.y, position.z)
	ack.predicted_position:Set(entry.position.x, entry.position.y, entry.position.z)
	ack.server_velocity:Set(velocity.x, velocity.y, velocity.z)
	ack.predicted_velocity:Set(entry.velocity.x, entry.velocity.y, entry.velocity.z)
	self.ack_log_index = self.ack_log_index % ACK_LOG_SIZE + 1
	self.ack_log[self.ack_log_index] = {magnitude, velocity_error_length, corrected}

	if not corrected then return 0 end

	if not velocity_matters then velocity_error:Set(0, 0, 0) end

	movement:MoveBodyBy(body, position_error)
	body:SetVelocity(body:GetVelocity() + velocity_error)

	for n = number, self.number do
		local later = self:GetHistory(n)

		if later then
			later.position:CopyFrom(later.position + position_error)
			later.velocity:CopyFrom(later.velocity + velocity_error)
		end
	end

	if magnitude > TELEPORT_DISTANCE then
		self.correction_offset:Set(0, 0, 0)
	else
		self.correction_offset:CopyFrom(self.correction_offset - position_error)
	end

	self.corrections = self.corrections + 1
	self.last_correction = magnitude
	return magnitude
end

function META:GetAckStats()
	local count, corrected, max_error, max_velocity_error = 0, 0, 0, 0

	for _, entry in ipairs(self.ack_log) do
		count = count + 1
		max_error = math.max(max_error, entry[1])
		max_velocity_error = math.max(max_velocity_error, entry[2])

		if entry[3] then corrected = corrected + 1 end
	end

	return count, corrected, max_error, max_velocity_error
end

function META:Start(position)
	local movement = self.Owner.character_movement
	movement:Reset("fly")
	movement:TeleportTo(position)
	self.history = {}
	self.recent = {}
	self.cmd = usercmd.New()
	self.correction_offset:Set(0, 0, 0)
	self.synced = true
end

function META:Spawn(position, rotation)
	self:Start(position)
	local player_input = self.Owner.player_input

	if player_input then
		player_input:SetRotation(rotation)
		player_input.Pitch = 0
	end
end

function META:IsWaitingForServer()
	return self.Networked and CLIENT and network.IsConnected() and not self.synced
end

function META:NextCommand(dt)
	self:RecordState()
	local previous = self.cmd

	if self:IsWaitingForServer() then
		local idle = usercmd.Copy(previous)
		idle.forward = 0
		idle.side = 0
		idle.up = 0
		idle.pressed = 0
		idle.buttons = 0
		idle.select = 0
		self.cmd = idle
		return idle
	end

	if self.Source == "local" then
		local cmd = usercmd.New()
		self.number = self.number + 1
		cmd.number = self.number

		if self.Owner.player_input then self.Owner.player_input:BuildCommand(cmd) end

		event.Call("CreateMove", self.Owner, cmd)
		cmd.pressed = bit.band(cmd.buttons, bit.bnot(previous.buttons))
		self.cmd = cmd

		if usercmd.WasPressed(cmd, usercmd.BUTTON.TELEPORT) then
			self:TeleportToAim(cmd)
		end

		local recent = self.recent
		recent[#recent + 1] = cmd

		if #recent > usercmd.MAX_BATCH then table.remove(recent, 1) end

		event.Call("PlayerCommand", self.Owner, cmd)
		return cmd
	end

	local cmd = next_queued(self)

	if cmd then
		self.starved = 0
		self.number = cmd.number
		cmd.pressed = bit.band(cmd.buttons, bit.bnot(previous.buttons))
		self.cmd = cmd

		if usercmd.WasPressed(cmd, usercmd.BUTTON.TELEPORT) then
			self:TeleportToAim(cmd)
		end

		return cmd
	end

	self.starved = self.starved + 1
	local repeated = usercmd.Copy(previous)
	repeated.pressed = 0
	repeated.select = 0

	if self.starved > MAX_REPEATS then
		repeated.forward = 0
		repeated.side = 0
		repeated.up = 0
		repeated.buttons = bit.band(repeated.buttons, bit.bnot(usercmd.BUTTON.JUMP))
	end

	self.cmd = repeated
	return repeated
end

CharacterMovement.RegisterController("player_controller")
return META:Register()
