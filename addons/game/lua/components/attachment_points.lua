local objects = import("goluwa/objects/objects.lua")
local biped = import("lua/biped.lua")
local META = objects.CreateTemplate("attachment_points")
-- an empty Network table is what makes the component part of the spawn packet
META.Network = {}
META:StartStorable()
META:GetSet("Profile", "biped")
META:EndStorable()

function META:Apply(armature)
	local sockets = self.Profile == "creature" and
		biped.GetCreatureSockets(self.Owner.character_movement:GetHeight()) or
		assert(biped.SocketProfiles[self.Profile], "unknown socket profile " .. self.Profile)

	for name, socket in pairs(sockets) do
		armature:SetSocket(name, socket.Bone, socket.Offset, socket.Rotation)
	end
end

function META:SetProfile(name)
	self.Profile = name

	if self.Owner.armature then self:Apply(self.Owner.armature) end
end

function META:Initialize()
	if self.initialized then return end

	self.initialized = true

	if self.Owner.armature then self:Apply(self.Owner.armature) end
end

function META:OnEntityConstructed()
	if self.Owner.armature then self:Apply(self.Owner.armature) end
end

function META:OnArmatureRebuild(armature)
	self:Apply(armature)
end

return META:Register()
