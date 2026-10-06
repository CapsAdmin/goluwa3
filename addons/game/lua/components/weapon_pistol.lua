local objects = import("goluwa/objects/objects.lua")
local physics = import("goluwa/physics.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local META = objects.CreateTemplate("weapon_pistol")
META:GetSet("Range", 50)
META:GetSet("Impulse", 6)
local TRACE_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

function META:Initialize()
	local weapon = self.Owner.weapon
	weapon:SetSlot(2)
	weapon:SetDisplayName("Pistol")
	weapon:SetMuzzleDistance(0.46)
	weapon:SetFireRate(0.25)
end

function META:WeaponCreateModel()
	local shapes = import("goluwa/render3d/shapes.lua")
	local weapon = self.Owner.weapon
	local metal = shapes.Material{Color = Color(0.12, 0.12, 0.14, 1), Roughness = 0.3, Metallic = 0.9}
	local grip = shapes.Material{Color = Color(0.3, 0.2, 0.12, 1), Roughness = 0.8, Metallic = 0}
	weapon:AddModelBox(Vec3(0.055, 0.07, 0.34), FORWARD * 0.29 + Vec3(0, 0.03, 0), metal)
	weapon:AddModelBox(Vec3(0.04, 0.04, 0.12), FORWARD * 0.4 - Vec3(0, 0.01, 0), metal)
	weapon:AddModelBox(Vec3(0.05, 0.14, 0.07), FORWARD * 0.16 - Vec3(0, 0.08, 0), grip)
end

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
