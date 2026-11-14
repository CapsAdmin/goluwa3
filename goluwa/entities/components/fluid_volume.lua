local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local fluid_volumes = import("goluwa/render3d/fluid_volumes.lua")
local FluidVolume = objects.CreateTemplate("fluid_volume")
FluidVolume:StartStorable()
FluidVolume:GetSet("Size", Vec3(4, 6, 4))
FluidVolume:GetSet("Resolution", 64, {validate = "number"})
FluidVolume:GetSet("Medium", "smoke")
FluidVolume:GetSet("Density", 1, {validate = "number"})
FluidVolume:GetSet("Simulation", "fluid", {enums = {"fluid", "procedural"}})
FluidVolume:GetSet("Space", "local", {enums = {"local", "world"}})
FluidVolume:GetSet("Raymarch", true)
FluidVolume:GetSet("Fill", 0, {validate = "number"})
FluidVolume:GetSet("NoiseScale", 4, {validate = "number"})
FluidVolume:GetSet("NoiseAmount", 0, {validate = "number"})
FluidVolume:GetSet("Buoyancy", 0.3, {validate = "number"})
FluidVolume:GetSet("Weight", 0, {validate = "number"})
FluidVolume:GetSet("Vorticity", 2, {validate = "number"})
FluidVolume:GetSet("Turbulence", 3, {validate = "number"})
FluidVolume:GetSet("TurbulenceScale", 0.5, {validate = "number"})
FluidVolume:GetSet("Dissipation", 0.15, {validate = "number"})
FluidVolume:GetSet("Cooling", 2, {validate = "number"})
FluidVolume:GetSet("IgnitionTemperature", 600, {validate = "number"})
FluidVolume:GetSet("BurnRate", 2, {validate = "number"})
FluidVolume:GetSet("HeatRelease", 2500, {validate = "number"})
FluidVolume:GetSet("FlameTemperature", 1900, {validate = "number"})
FluidVolume:GetSet("FlameLife", 0.5, {validate = "number"})
FluidVolume:GetSet("SootYield", 1, {validate = "number"})
FluidVolume:GetSet("Floor", true)
FluidVolume:GetSet("Obstacles", true)
FluidVolume:GetSet("Pushers", true)
FluidVolume:GetSet("EmitLight", true)
FluidVolume:GetSet("Visible", true)
FluidVolume:EndStorable()

function FluidVolume:RefreshRegistration()
	local active = self.Visible and not self.Owner.visibility_hidden or false

	if active == (self.registered or false) then return end

	self.registered = active

	if active then
		fluid_volumes.AddVolume(self)
	else
		fluid_volumes.RemoveVolume(self)
	end
end

function FluidVolume:OnCreate()
	if self.Visible then
		self.registered = true
		fluid_volumes.AddVolume(self)
	end
end

function FluidVolume:SetVisible(visible)
	if self.Visible == visible then return end

	objects.CommitProperty(self, "Visible", visible)
	self:RefreshRegistration()
end

function FluidVolume:Reset()
	fluid_volumes.Reset(self)
end

FluidVolume.OnHide = FluidVolume.RefreshRegistration
FluidVolume.OnShow = FluidVolume.RefreshRegistration
FluidVolume.OnEntityConstructed = FluidVolume.RefreshRegistration

function FluidVolume:OnRemove()
	self.registered = false
	fluid_volumes.RemoveVolume(self)
end

return FluidVolume:Register()
