local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local DARK_METAL = {Color = Color(0.12, 0.12, 0.14, 1), Roughness = 0.3, Metallic = 0.9}
local GRIP = {Color = Color(0.3, 0.2, 0.12, 1), Roughness = 0.8, Metallic = 0}
local box = nodes.Box
local muzzle = nodes.Muzzle
return {
	Values = {WorldSize = Vec3(0.06, 0.2, 0.36), WorldCenter = FORWARD * 0.24, Slot = 2, DisplayName = "Pistol", FireRate = 0.25},
	Nodes = {
		box("barrel", Vec3(0.055, 0.07, 0.34), FORWARD * 0.29 + Vec3(0, 0.03, 0), DARK_METAL),
		box("muzzle_block", Vec3(0.04, 0.04, 0.12), FORWARD * 0.4 - Vec3(0, 0.01, 0), DARK_METAL),
		box("grip", Vec3(0.05, 0.14, 0.07), FORWARD * 0.16 - Vec3(0, 0.08, 0), GRIP),
		muzzle(0.46),
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local damage = import("lua/damage.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local META = objects.CreateTemplate("weapon_pistol")
META:GetSet("Range", 50)
META:GetSet("Damage", 20)
META:GetSet("Impulse", 6)
META:GetSet("LimpSpread", 0.3)

function META:OnWeaponPrimary(cmd)
	local player = self.Owner:GetParent()
	local origin = player.transform:GetPosition() + player.character_movement:GetViewOffset()
	local forward = cmd.view:GetForward()
	local ragdoll = player.ragdoll
	local limp = ragdoll and math.max(ragdoll:GetLimp("upperarm_r"), ragdoll:GetLimp("forearm_r")) or 0

	if limp > 0 then
		local spread = self.LimpSpread * limp
		forward = (forward + Vec3(math.randomf(-spread, spread), math.randomf(-spread, spread), math.randomf(-spread, spread))):GetNormalized()
	end

	local hit = damage.Sweep(origin, forward * self.Range, player)

	weapon_effects.MuzzleFlash(self.Owner, forward)

	if not hit then return end

	weapon_effects.Hit(hit.point, hit.normal, forward * self.Impulse)

	local victim, multiplier

	if hit.entity then victim, multiplier = damage.GetVictim(hit.entity) end

	if victim and victim.health then
		damage.Deal(
			victim,
			{
				Attacker = player,
				Inflictor = self.Owner,
				Damage = self.Damage * multiplier,
				Position = hit.point,
				Normal = hit.normal,
				Force = forward * self.Impulse,
				Part = hit.entity.ragdoll_part and hit.entity.ragdoll_part.Group,
			}
		)
	end

	local body = hit.rigid_body or (hit.entity and hit.entity.rigid_body)

	if body and body:IsDynamic() then
		body:ApplyImpulse(forward * self.Impulse, hit.point)
	end
end

return META:Register()
]=====],
}
