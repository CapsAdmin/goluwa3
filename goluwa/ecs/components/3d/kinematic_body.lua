local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = prototype.CreateTemplate("kinematic_body")
local physics = import("goluwa/physics.lua")
META:GetSet("Enabled", true)
META:GetSet("Radius", 0.5)
META:GetSet("GravityScale", 1)
META:GetSet("Acceleration", 40)
META:GetSet("AirAcceleration", 8)
META:GetSet("LinearDamping", 10)
META:GetSet("GroundSnapDistance", 0.01)
META:GetSet("MinGroundNormalY", 0.2)
META:GetSet("MaxFallSpeed", 120)
META:GetSet("Skin", physics.DefaultSkin)
META:GetSet("Grounded", false)
META:GetSet("FilterFunction", nil)

function META:Initialize()
	self.Velocity = self.Velocity or Vec3(0, 0, 0)
	self.DesiredVelocity = self.DesiredVelocity or Vec3(0, 0, 0)
	self.GroundNormal = self.GroundNormal or Vec3(0, 1, 0)
end

function META:OnAdd(entity)
	self.Owner = entity
end

function META:GetBody()
	return self
end

function META:GetVelocity()
	return self.Velocity
end

function META:SetVelocity(vec)
	self.Velocity = vec:Copy()
end

function META:GetDesiredVelocity()
	return self.DesiredVelocity
end

function META:SetDesiredVelocity(vec)
	self.DesiredVelocity = vec:Copy()
end

function META:GetGroundNormal()
	return self.GroundNormal
end

function META:SetGroundNormal(vec)
	self.GroundNormal = vec:Copy()
end

function META:SetGrounded(grounded)
	self.Grounded = grounded
end

function META:GetGrounded()
	return self.Grounded
end

return META:Register()