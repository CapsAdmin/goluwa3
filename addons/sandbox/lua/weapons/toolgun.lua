local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local model_replacements = import("lua/model_replacements.lua")
local PLACEHOLDER = {Color = Color(0.8, 0.82, 0.85, 1), Roughness = 0.35, Metallic = 0.7}
model_replacements.Register(
	"toolgun",
	{
		Game = 546560,
		Path = "models/weapons/vr_alyxtool/alyx_tool_lhand.vmdl_c",
		Position = Vec3(0, 0, -0.085),
		Rotation = Quat(0, 0, 0, 1),
		Scale = Vec3(1.7, 1.7, 1.7),
	}
)
return {
	Values = {
		WorldSize = Vec3(0.05, 0.18, 0.32),
		WorldCenter = Vec3(0, 0.03, -0.14),
		Slot = 6,
		DisplayName = "Tool gun",
		FireRate = 0.2,
		Replacement = "toolgun",
	},
	Nodes = {
		nodes.Replacement(Vec3(0.07, 0.045, 0.31), Vec3(0, 0, -0.1), PLACEHOLDER),
		nodes.Marker("muzzle", Vec3(0, 0, -0.26)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local toolgun = import("lua/toolgun.lua")
local weapon_effects = import("lua/weapon_effects.lua")
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

function META:PredictTrace(cmd)
	local trace = toolgun.Trace(self.Owner:GetParent(), cmd.aim)

	if trace then
		weapon_effects.ToolTrace(self.Owner, trace.position, trace.normal)
	end
end

function META:OnWeaponPredictPrimary(cmd)
	self:PredictTrace(cmd)
end

function META:OnWeaponPredictSecondary(cmd)
	self:PredictTrace(cmd)
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
