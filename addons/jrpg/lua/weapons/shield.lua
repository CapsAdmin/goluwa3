local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local SILVER = {Color = Color(0.32, 0.34, 0.38, 1), Roughness = 0.35, Metallic = 1}
local TRIM = {Color = Color(0.75, 0.6, 0.3, 1), Roughness = 0.3, Metallic = 1}
local box = nodes.Box
local FACE = FORWARD * 0.06
return {
	Values = {
		WorldSize = Vec3(0.44, 0.54, 0.08),
		WorldCenter = Vec3(),
		Slot = 0,
		DisplayName = "Shield",
		Category = "defense",
		Offhand = true,
	},
	Nodes = {
		box("plate", Vec3(0.42, 0.52, 0.03), FACE, SILVER),
		box("rim_top", Vec3(0.44, 0.03, 0.045), FACE + Vec3(0, 0.26, 0), TRIM),
		box("rim_bottom", Vec3(0.44, 0.03, 0.045), FACE - Vec3(0, 0.26, 0), TRIM),
		box("rim_left", Vec3(0.03, 0.52, 0.045), FACE - Vec3(0.21, 0, 0), TRIM),
		box("rim_right", Vec3(0.03, 0.52, 0.045), FACE + Vec3(0.21, 0, 0), TRIM),
		box("boss", Vec3(0.1, 0.1, 0.05), FACE + FORWARD * 0.03, TRIM),
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local network = import("goluwa/network/network.lua")
local META = objects.CreateTemplate("weapon_shield")
local BUTTON = usercmd.BUTTON

function META:GetHolder()
	return self.Owner:GetParent()
end

function META:OnWeaponThink(dt, cmd)
	local holder = self:GetHolder()
	local rpg = holder.rpg
	local wants = usercmd.HasButton(cmd, BUTTON.WALK) and usercmd.HasButton(cmd, BUTTON.ACTIVE)
	local able = not rpg or (rpg:GetStamina() > 0 and not rpg:IsStunned() and not rpg:IsRolling())
	holder.character_pose:SetBlocking(wants and able)
end

function META:OnRemove()
	local holder = self:GetHolder()

	if network.HasAuthority() and holder:IsValid() and holder.character_pose then
		holder.character_pose:SetBlocking(false)
	end
end

return META:Register()
]=====],
}
