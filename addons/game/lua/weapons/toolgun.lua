local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local METAL = {Color = Color(0.55, 0.57, 0.6, 1), Roughness = 0.35, Metallic = 0.85}
local DARK = {Color = Color(0.1, 0.1, 0.12, 1), Roughness = 0.6, Metallic = 0.2}
local SCREEN = {Color = Color(0.2, 0.6, 1, 1), Roughness = 0.2, Metallic = 0}
local box = nodes.Box
local muzzle = nodes.Muzzle
return {
	Values = {
		WorldSize = Vec3(0.08, 0.22, 0.42),
		WorldCenter = FORWARD * 0.26,
		Slot = 6,
		DisplayName = "Tool gun",
		FireRate = 0.2,
	},
	Nodes = {
		box("body", Vec3(0.07, 0.09, 0.3), FORWARD * 0.27 + Vec3(0, 0.03, 0), METAL),
		box("screen", Vec3(0.075, 0.05, 0.08), FORWARD * 0.2 + Vec3(0, 0.08, 0), SCREEN),
		box("barrel", Vec3(0.035, 0.035, 0.14), FORWARD * 0.46 + Vec3(0, 0.04, 0), DARK),
		box("grip", Vec3(0.05, 0.14, 0.07), FORWARD * 0.16 - Vec3(0, 0.08, 0), DARK),
		muzzle(0.54),
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local toolgun = import("lua/toolgun.lua")
local META = objects.CreateTemplate("weapon_toolgun")
local BUTTON = usercmd.BUTTON

function META:Initialize()
	self.context = toolgun.NewContext(self.Owner)
end

function META:GetContext()
	return self.context
end

function META:OnWeaponPrimary(cmd)
	return toolgun.Fire(self.context, cmd, "LeftClick")
end

function META:OnWeaponSecondary(cmd)
	return toolgun.Fire(self.context, cmd, "RightClick")
end

function META:OnWeaponThink(dt, cmd)
	if usercmd.HasButton(cmd, BUTTON.ACTIVE) and usercmd.WasPressed(cmd, BUTTON.RELOAD) then
		toolgun.Fire(self.context, cmd, "Reload")
	end
end

function META:OnWeaponReset()
	return true
end

function META:OnWeaponHolster()
	self.context:ClearTargets()
end

return META:Register()
]=====],
}
