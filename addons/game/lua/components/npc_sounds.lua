local objects = import("goluwa/objects/objects.lua")
local sounds = import("lua/sounds.lua")
local META = objects.CreateTemplate("npc_sounds")
local NO_SOUNDS = {}
META:GetSet("Sounds", NO_SOUNDS)
local MIN_STEP_SPEED = 0.3

function META:Initialize()
	if AUDIO and CLIENT then self:AddGlobalEvent("Update") end
end

function META:Play(role)
	local set = self.Sounds[role]

	if set then
		sounds.PlayRandom(
			set.Paths,
			self.Owner.transform:GetPosition(),
			set.Gain or 1,
			math.randomf(0.95, 1.05)
		)
	end
end

function META:OnUpdate()
	local foot = self.Sounds.Foot
	local owner = self.Owner
	local pose = owner.character_pose

	if not foot or owner.health:IsDead() then
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
