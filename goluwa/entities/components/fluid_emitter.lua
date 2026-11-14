local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local fluid_volumes = import("goluwa/render3d/fluid_volumes.lua")
local FluidEmitter = objects.CreateTemplate("fluid_emitter")
FluidEmitter:StartStorable()
FluidEmitter:GetSet("Radius", 0.3, {validate = "number"})
FluidEmitter:GetSet("Smoke", 0, {validate = "number"})
FluidEmitter:GetSet("Temperature", 0, {validate = "number"})
FluidEmitter:GetSet("Fuel", 0, {validate = "number"})
FluidEmitter:GetSet("Velocity", Vec3(0, 0, 0))
FluidEmitter:GetSet("Enabled", true)
FluidEmitter:EndStorable()

function FluidEmitter:IsEmitting()
	return self.Enabled and not self.Owner.visibility_hidden
end

function FluidEmitter:OnCreate()
	fluid_volumes.AddEmitter(self)
end

function FluidEmitter:OnRemove()
	fluid_volumes.RemoveEmitter(self)
end

return FluidEmitter:Register()
