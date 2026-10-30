local objects = import("goluwa/objects/objects.lua")
local new_event = import("goluwa/network/replicated_event.lua")
local system = import("goluwa/system.lua")
local sounds = import("lua/sounds.lua")
local META = objects.CreateTemplate("npc_sounds")
local NO_SOUNDS = {}
META:GetSet("Sounds", NO_SOUNDS)
local MIN_STEP_SPEED = 0.3
local PAIN_INTERVAL = 0.6

META.Broadcast = new_event(
	"npc_sound",
	function(entity, role, position)
		if entity:IsValid() then entity.npc_sounds:Play(role, position) end
	end,
	function()
		return AUDIO and CLIENT
	end
)

function META:Initialize()
	self.next_pain = 0

	if AUDIO and CLIENT then self:AddGlobalEvent("Update") end
end

function META:Play(role, position, scale)
	local set = self.Sounds[role]

	if set then
		sounds.PlayRandom(
			set.Paths,
			position or self.Owner.transform:GetPosition(),
			(set.Gain or 1) * (scale or 1),
			(set.Pitch or 1) * math.randomf(0.95, 1.05)
		)
	end
end

function META:Say(role, position)
	if self.Sounds[role] then META.Broadcast(self.Owner, role, position) end
end

function META:OnTakeDamage()
	local now = system.GetElapsedTime()

	if self.Owner.health:IsDead() or now < self.next_pain then return end

	self.next_pain = now + PAIN_INTERVAL
	self:Say("Pain")
end

function META:OnDeath()
	self:Say("Death")
end

function META:OnNPCAlert()
	self:Say("Alert")
end

function META:OnNPCIdle()
	self:Say("Idle")
end

function META:OnNPCStrike(target)
	self:Say("Hit", target.transform:GetPosition():Copy())
end

function META:OnMoveBegin(move)
	if move.Sound then self:Say(move.Sound) end
end

function META:OnUpdate()
	local foot = self.Sounds.Foot
	local owner = self.Owner
	local pose = owner.character_pose

	if not foot or not foot.Length or owner.health:IsDead() then
		self.step = nil
		return
	end

	local step = math.floor(pose.Distance / foot.Length)

	if self.step and step ~= self.step and pose.grounded then
		local speed = math.sqrt(pose.forward_speed * pose.forward_speed + pose.right_speed * pose.right_speed)

		if speed > MIN_STEP_SPEED then self:Play("Foot") end
	end

	self.step = step
end

return META:Register()
