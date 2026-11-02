local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("fade_out")
META:StartStorable()
META:GetSet("Time", 5)
META:GetSet("ShrinkTime", 1)
META:EndStorable()

function META:Initialize()
	self.age = 0
	self:AddGlobalEvent("Update")
end

function META:OnUpdate(dt)
	local owner = self.Owner
	self.age = self.age + dt
	local left = self.Time - self.age

	if left <= 0 then
		if network.HasAuthority() then owner:Remove() end

		return
	end

	if left > self.ShrinkTime then return end

	local node = owner.prefab:GetNode("visual")

	if not self.base_position then
		self.base_position = node.transform:GetPosition():Copy()
	end

	local scale = left / self.ShrinkTime
	node.transform:SetScale(Vec3(scale, scale, scale))
	node.transform:SetPosition(self.base_position * scale)
end

return META:Register()
