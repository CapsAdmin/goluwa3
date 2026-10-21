local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("character_pose")
META.Network = {
	Crouching = {"boolean", 0.1, "reliable"},
	Holding = {"boolean", 0.1, "reliable"},
	ViewRotation = {"quat", 1 / 20, "sequenced", true},
	Shots = {"number", 0.05, "reliable"},
	Hits = {"number", 0.05, "reliable"},
}
META:IsSet("Crouching", false)
META:IsSet("Holding", false)
META:IsSet("FirstPerson", false)
META:GetSet("ViewRotation", Quat(0, 0, 0, 1))
META:GetSet("Shots", 0)
META:GetSet("Hits", 0)
local RELAY_FRESH = 0.3
local RECOIL_DECAY = 8
local FLINCH_DECAY = 4

function META:Initialize()
	self.pitch = Quat(0, 0, 0, 1)
	self.crouch_alpha = 0
	self.forward_speed = 0
	self.right_speed = 0
	self.vertical_speed = 0
	self.grounded = false
	self.recoil = 0
	self.flinch = 0
	self.seen_shots = self.Shots
	self.seen_hits = self.Hits
	self:AddGlobalEvent("Update")
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

function META:OnUpdate(dt)
	local owner = self.Owner
	local movement = owner.character_movement
	local transform = owner.transform

	if movement then
		self:SetViewRotation(movement:GetCommand().view:Copy())
		self:SetCrouching(movement:IsCrouching())

		if owner.player_controller then
			self:SetHolding(owner.player_controller:IsHolding())
		end
	end

	if self.Shots ~= self.seen_shots then
		self.seen_shots = self.Shots
		self.recoil = 1
	end

	if self.Hits ~= self.seen_hits then
		self.seen_hits = self.Hits
		self.flinch = 1
	end

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

	self.crouch_alpha = self.crouch_alpha + (
			(
				self:IsCrouching() and
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
	self.grounded = body ~= nil and body:GetGrounded()

	if movement and movement.dead then
		self.dead_pitch = self.dead_pitch or self.pitch
		self.pitch = self.dead_pitch
	else
		self.dead_pitch = nil
		self.pitch = entity_rotation:GetConjugated() * rotation
	end
end

return META:Register()
