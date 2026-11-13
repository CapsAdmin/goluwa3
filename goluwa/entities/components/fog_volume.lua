local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local fog_volumes = import("goluwa/render3d/fog_volumes.lua")
local FogVolume = objects.CreateTemplate("fog_volume")
FogVolume:StartStorable()
FogVolume:GetSet("Size", Vec3(10, 4, 10))
FogVolume:GetSet("Medium", "fog")
FogVolume:GetSet("Density", 0.05, {validate = "number"})
FogVolume:GetSet("EdgeSoftness", 1, {validate = "number"})
FogVolume:GetSet("HeightFalloff", 0, {validate = "number"})
FogVolume:GetSet("Visible", true)
FogVolume:EndStorable()

function FogVolume:RefreshRegistration()
	local active = self.Visible and not self.Owner.visibility_hidden or false

	if active == (self.registered or false) then return end

	self.registered = active

	if active then
		fog_volumes.AddVolume(self)
	else
		fog_volumes.RemoveVolume(self)
	end
end

function FogVolume:OnCreate()
	if self.Visible then
		self.registered = true
		fog_volumes.AddVolume(self)
	end
end

function FogVolume:SetVisible(visible)
	if self.Visible == visible then return end

	objects.CommitProperty(self, "Visible", visible)
	self:RefreshRegistration()
end

FogVolume.OnHide = FogVolume.RefreshRegistration
FogVolume.OnShow = FogVolume.RefreshRegistration
FogVolume.OnEntityConstructed = FogVolume.RefreshRegistration

function FogVolume:OnRemove()
	self.registered = false
	fog_volumes.RemoveVolume(self)
end

return FogVolume:Register()
