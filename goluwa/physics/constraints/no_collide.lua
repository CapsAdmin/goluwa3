local Constraint = import("goluwa/physics/constraint.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("physics_no_collide_constraint")
META.Base = Constraint

function META.New(body_0, body_1)
	local self = META:CreateObject{CollideConnected = false}
	return self:SetupFrames(body_0, body_1, Vec3())
end

function META:Solve() end

return META:Register()
