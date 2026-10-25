local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BODY = {Color = Color(0.8, 0.82, 0.85, 1), Roughness = 0.35, Metallic = 0.7}
local HANDLE = {Color = Color(0.1, 0.1, 0.12, 1), Roughness = 0.6, Metallic = 0.2}
local MUZZLE = {Color = Color(0.1, 0.8, 0.5, 1), Roughness = 0.2, Metallic = 0.3}
return {
	Values = {
		WorldSize = Vec3(0.05, 0.18, 0.32),
		WorldCenter = Vec3(0, 0.03, -0.14),
		Slot = 6,
		DisplayName = "Tool gun",
		FireRate = 0.2,
	},
	Nodes = {
		nodes.Handle("handle", 0.022, 0.12, Vec3(0, 0, 0), HANDLE),
		nodes.Box("body", Vec3(0.045, 0.06, 0.2), Vec3(0, 0.09, -0.08), BODY),
		nodes.Muzzle(0.015, 0.12, Vec3(0, 0.09, -0.3), MUZZLE),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
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

function META:OnWeaponHolster()
	self.context:ClearTargets()
end

return META:Register()
]=====],
}
