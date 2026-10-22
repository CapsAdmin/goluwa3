local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local use = import("goluwa/entities/use.lua")
local META = objects.CreateTemplate("usable")
META:StartStorable()
META:GetSet("Prompt", "use")
META:IsSet("Enabled", true)
META:EndStorable()
META.last_use = -math.huge

function META:OnUse(user, hit)
	if not self.Enabled then return end

	self.last_use = system.GetElapsedTime()
	return self.Owner:CallLocalEvent("OnUsed", user, hit) == true
end

function META.Find(user)
	local movement = user.character_movement
	local hit = use.Trace(
		user,
		user.transform:GetPosition() + movement:GetViewOffset(),
		movement:GetCommand().view:GetForward()
	)

	if not hit then return end

	local current = hit.entity

	while current:IsValid() do
		local usable = current.usable

		if usable and usable.Enabled then return usable, hit end

		current = current:GetParent()
	end
end

return META:Register()
