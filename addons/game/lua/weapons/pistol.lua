local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BODY = {Color = Color(0.16, 0.17, 0.2, 1), Roughness = 0.3, Metallic = 0.9}
local HANDLE = {Color = Color(0.36, 0.22, 0.12, 1), Roughness = 0.8, Metallic = 0}
local MUZZLE = {Color = Color(0.04, 0.04, 0.05, 1), Roughness = 0.25, Metallic = 0.9}
return {
	Values = {
		WorldSize = Vec3(0.05, 0.18, 0.32),
		WorldCenter = Vec3(0, 0.03, -0.14),
		Stance = "pistol",
		Slot = 2,
		DisplayName = "Pistol",
		FireRate = 0.25,
		HoldOffset = Vec3(0.16, 0, 0),
		Holster = true,
		Rollable = true,
	},
	Nodes = {
		nodes.Handle("handle", 0.022, 0.12, Vec3(0, 0, 0), HANDLE),
		nodes.Box("body", Vec3(0.045, 0.06, 0.2), Vec3(0, 0.09, -0.08), BODY),
		nodes.Muzzle(0.015, 0.12, Vec3(0, 0.09, -0.3), MUZZLE),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local damage = import("lua/damage.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local GENERIC = {"generic"}
local META = objects.CreateTemplate("weapon_pistol")
META:GetSet("Range", 50)
META:GetSet("Damage", 20)
META:GetSet("Impulse", 6)
META:GetSet("LimpSpread", 0.3)

function META:Aim(cmd)
	local player = self.Owner:GetParent()
	local origin = player.transform:GetPosition() + player.character_movement:GetViewOffset()
	local forward = cmd.aim:GetForward()
	local ragdoll = player.ragdoll
	local limp = ragdoll and math.max(ragdoll:GetPartLimp("upperarm_r"), ragdoll:GetPartLimp("forearm_r")) or 0

	if limp > 0 then
		local spread = self.LimpSpread * limp
		forward = (forward + Vec3(math.randomf(-spread, spread), math.randomf(-spread, spread), math.randomf(-spread, spread))):GetNormalized()
	end

	return damage.Sweep(origin, forward * self.Range, player), forward
end

function META:OnWeaponPredictPrimary(cmd)
	local hit, forward = self:Aim(cmd)
	weapon_effects.MuzzleFlash(self.Owner, forward)

	if hit then
		weapon_effects.Hit(self.Owner, hit.point, hit.normal, forward * self.Impulse)
	end
end

function META:OnWeaponPrimary(cmd)
	local player = self.Owner:GetParent()
	local hit, forward = self:Aim(cmd)

	weapon_effects.MuzzleFlash(self.Owner, forward)

	if not hit then return end

	weapon_effects.Hit(self.Owner, hit.point, hit.normal, forward * self.Impulse)

	local victim, multiplier

	if hit.entity then victim, multiplier = damage.GetVictim(hit.entity) end

	if victim and victim.health then
		local scale = self.Owner.weapon:GetDamageScale()

		for i, type_name in ipairs(self.Owner.weapon:GetDamageTypes(GENERIC)) do
			if victim.health:IsDead() then break end

			damage.Deal(
				victim,
				{
					Attacker = player,
					Inflictor = self.Owner,
					Damage = self.Damage * multiplier * scale,
					Type = type_name,
					Secondary = i > 1,
					Position = hit.point,
					Normal = hit.normal,
					Force = forward * self.Impulse,
					Part = hit.entity.ragdoll_part and hit.entity.ragdoll_part.Group,
				}
			)
		end
	end

	local body = hit.rigid_body or (hit.entity and hit.entity.rigid_body)

	if body and body:IsDynamic() then
		body:ApplyImpulse(forward * self.Impulse, hit.point)
	end
end

return META:Register()
]=====],
}
