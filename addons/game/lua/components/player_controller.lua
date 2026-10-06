local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local network = import("goluwa/network/network.lua")
local META = objects.CreateTemplate("player_controller")
local HISTORY_SIZE = 256
local MIN_BUFFER = 4
local START_BUFFER = 6
local MAX_BUFFER = 14
local BACKLOG_SLACK = 12
local MAX_REPEATS = 15
local SHRINK_INTERVAL = 300
local CORRECTION_DECAY = 10
META:GetSet("Source", "local")
META:GetSet("Networked", false)
META:IsSet("Holding", false)

function META:Initialize()
	self.cmd = usercmd.New()
	self.number = 0
	self.queue = {}
	self.queue_head = 1
	self.last_queued = 0
	self.starved = 0
	self.buffering = true
	self.buffer_target = START_BUFFER
	self.consumed = 0
	self.history = {}
	self.processed = {number = 0, position = Vec3(), velocity = Vec3(), grounded = false}
	self.correction_offset = Vec3()
	self.corrections = 0
	self.recent = {}
	self:AddGlobalEvent("Update", {priority = -200})
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
		entry = {number = self.number, position = Vec3(), velocity = Vec3(), grounded = false}
		self.history[self.number % HISTORY_SIZE] = entry
	end

	entry.position:CopyFrom(body:GetPosition())
	entry.velocity:CopyFrom(body:GetVelocity())
	entry.grounded = body:GetGrounded()
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
		return nil
	end

	if size > self.buffer_target + BACKLOG_SLACK then
		self.queue_head = self.queue_head + (size - self.buffer_target - BACKLOG_SLACK / 2)
	end

	local cmd = queue[self.queue_head]
	queue[self.queue_head] = false
	self.queue_head = self.queue_head + 1
	self.consumed = self.consumed + 1

	if self.consumed >= SHRINK_INTERVAL then
		self.consumed = 0
		self.buffer_target = math.max(self.buffer_target - 1, MIN_BUFFER)
	end

	if self.queue_head > #queue then
		self.queue = {}
		self.queue_head = 1
	end

	return cmd
end

local TELEPORT_DISTANCE = 4

function META:Reconcile(number, position, velocity)
	local body = self.Owner.rigid_body
	local movement = self.Owner.player_movement
	local entry = self:GetHistory(number)

	if not entry then return 0 end

	local position_error = position - entry.position
	local velocity_error = velocity - entry.velocity
	local magnitude = position_error:GetLength()

	if magnitude < 0.002 and velocity_error:GetLength() < 0.02 then return 0 end

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

function META:Start(position)
	local body = self.Owner.rigid_body
	local movement = self.Owner.player_movement
	movement:Reset("fly")
	movement:MoveBodyBy(body, position - body:GetPosition())
	body:SetVelocity(Vec3())
	self.history = {}
	self.number = 0
	self.recent = {}
	self.cmd = usercmd.New()
	self.correction_offset:Set(0, 0, 0)
	self.synced = true
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
		return cmd
	end

	self.starved = self.starved + 1
	local repeated = usercmd.Copy(previous)
	repeated.pressed = 0

	if self.starved > MAX_REPEATS then
		repeated.forward = 0
		repeated.side = 0
		repeated.up = 0
		repeated.buttons = bit.band(repeated.buttons, bit.bnot(usercmd.BUTTON.JUMP))
	end

	self.cmd = repeated
	return repeated
end

return META:Register()
