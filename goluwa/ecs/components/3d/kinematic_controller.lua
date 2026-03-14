local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = prototype.CreateTemplate("kinematic_controller")
META:GetSet("Enabled", true)
META:GetSet("DesiredVelocity", Vec3(0, 0, 0))
META:GetSet("Velocity", Vec3(0, 0, 0))
META:GetSet("Acceleration", 40)
META:GetSet("AirAcceleration", 8)
META:GetSet("GroundSnapDistance", 0.01)
META:GetSet("MaxFallSpeed", 120)

function META:Initialize()
	self.DesiredVelocity = self.DesiredVelocity or Vec3(0, 0, 0)
	self.Velocity = self.Velocity or Vec3(0, 0, 0)
end

function META:OnAdd(entity)
	self.Owner = entity
	local body = self:GetRigidBody()

	if body and body.GetMotionType and body:GetMotionType() ~= "kinematic" then
		body:SetMotionType("kinematic")
	end
end

function META:GetRigidBody()
	return self.Owner and self.Owner.rigid_body or nil
end

function META:HasRigidBody()
	return self:GetRigidBody() ~= nil
end

function META:IsControllingKinematicBody()
	local body = self:GetRigidBody()
	return body and body.IsKinematic and body:IsKinematic() or false
end

function META:EnsureKinematicBody()
	local body = self:GetRigidBody()

	if body and body.GetMotionType and body:GetMotionType() ~= "kinematic" then
		body:SetMotionType("kinematic")
	end

	return body
end

return META:Register()