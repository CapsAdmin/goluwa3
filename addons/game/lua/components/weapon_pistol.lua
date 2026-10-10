local objects = import("goluwa/objects/objects.lua")
local physics = import("goluwa/physics.lua")
local META = objects.CreateTemplate("weapon_pistol")
META:GetSet("Range", 50)
META:GetSet("Impulse", 6)
local TRACE_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

function META:WeaponPrimary(cmd)
	local player = self.Owner:GetParent()
	local origin = player.transform:GetPosition() + player.player_movement:GetViewOffset()
	local forward = cmd.view:GetForward()
	local hit = physics.Sweep(origin, forward * self.Range, 0, player, nil, TRACE_OPTIONS)

	if not hit then return end

	local body = hit.rigid_body or (hit.entity and hit.entity.rigid_body)

	if body and body:IsDynamic() then
		body:ApplyImpulse(forward * self.Impulse, hit.point)
	end
end

return META:Register()
