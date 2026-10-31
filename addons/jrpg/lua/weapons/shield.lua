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
		PoseArms = false,
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
local network = import("goluwa/network/network.lua")
local META = objects.CreateTemplate("weapon_shield")
local GUARD = {Physical = 1, Magic = 0.5, Angle = 0.2, Cost = 1, Parry = 0, Raised = 0}

function META:GetHolder()
	return self.Owner:GetParent()
end

function META:SetRaised(holder, up)
	local pose = holder.character_pose
	pose:SetBlocking(up)
	pose:SetState("block", up and "" or nil)

	if holder.rpg then holder.rpg:SetGuard(up and GUARD or nil) end
end

function META:OnWeaponThink(dt, cmd)
	local holder = self:GetHolder()
	local rpg = holder.rpg
	local wants = self.Owner.weapon:IsPrimaryDown(cmd)
	local able = not rpg or (rpg:GetStamina() > 0 and not rpg:IsStunned() and not holder.character_movement:IsRolling())
	self:SetRaised(holder, wants and able)
end

function META:OnWeaponPrimary()
	return false
end

function META:Lower()
	local holder = self:GetHolder()

	if network.HasAuthority() and holder:IsValid() and holder.character_pose then
		self:SetRaised(holder, false)
	end
end

function META:OnWeaponHolster()
	self:Lower()
end

function META:OnRemove()
	self:Lower()
end

return META:Register()
]=====],
}
