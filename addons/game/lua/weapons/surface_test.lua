local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BODY = {Color = Color(0.85, 0.35, 0.15, 1), Roughness = 0.5, Metallic = 0}
local HANDLE = {Color = Color(0.1, 0.1, 0.1, 1), Roughness = 0.9, Metallic = 0}
local CONE = {Color = Color(0.2, 0.2, 0.22, 1), Roughness = 0.4, Metallic = 0.6}
return {
	Values = {
		WorldSize = Vec3(0.05, 0.18, 0.28),
		WorldCenter = Vec3(0, 0.03, -0.12),
		Stance = "pistol",
		Slot = 9.1,
		DisplayName = "Surface test",
		FireRate = 0.2,
		HoldOffset = Vec3(0.16, 0, 0),
	},
	Nodes = {
		nodes.Handle("handle", 0.022, 0.12, Vec3(0, 0, 0), HANDLE),
		nodes.Box("body", Vec3(0.05, 0.06, 0.16), Vec3(0, 0.09, -0.06), BODY),
		nodes.Muzzle(0.03, 0.06, Vec3(0, 0.09, -0.17), CONE),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local damage = import("lua/damage.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local META = objects.CreateTemplate("weapon_surface_test")
local RANGE = 80
local RADII = {0.5, 1, 2, 4}
local TEXT = Color(1, 1, 1, 1)
local TITLE = Color(1, 0.55, 0.2, 1)

function META:Initialize()
	self.kind_index = 1
	self.radius_index = 2
	self:AddGlobalEvent("Draw2D")
end

function META:Select(cmd)
	if not usercmd.HasButton(cmd, usercmd.BUTTON.ACTIVE) then return end

	if usercmd.WasPressed(cmd, usercmd.BUTTON.RELOAD) then
		self.kind_index = self.kind_index % math.max(#weapon_effects.GetSurfaceConditionNames(), 1) + 1
	end

	if usercmd.WasPressed(cmd, usercmd.BUTTON.ATTACK3) then
		self.radius_index = self.radius_index % #RADII + 1
	end
end

function META:OnWeaponPredictThink(dt, cmd)
	self:Select(cmd)
end

function META:OnWeaponThink(dt, cmd)
	self:Select(cmd)
end

function META:OnWeaponPrimary(cmd)
	local names = weapon_effects.GetSurfaceConditionNames()
	local holder = self.Owner:GetParent()
	local origin = holder.transform:GetPosition() + holder.character_movement:GetViewOffset()
	local trace = damage.Sweep(origin, cmd.aim:GetForward() * RANGE, holder)

	if not trace or not names[self.kind_index] then return false end

	weapon_effects.TestSurfaceCondition(names[self.kind_index], trace.point, trace.normal, RADII[self.radius_index], 1)
end

function META:OnWeaponSecondary(cmd)
	weapon_effects.ClearSurfaceConditions()
end

function META:OnDraw2D()
	local holder = self.Owner:GetParent()

	if not holder.player_input or not self.Owner.weapon:IsEquipped() then return end

	local width, height = render2d.GetSize()
	local lines = {"surface conditions", ""}

	for i, name in ipairs(weapon_effects.GetSurfaceConditionNames()) do
		lines[#lines + 1] = (i == self.kind_index and "> " or "  ") .. name
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "radius " .. RADII[self.radius_index]
	lines[#lines + 1] = "left click apply, right click clear, reload next kind, F radius"
	debug_draw.DrawTextBlock(
		lines,
		width,
		height,
		{padding = 8, line_gap = 3, background_alpha = 0.7, title_color = TITLE, text_color = TEXT}
	)
end

return META:Register()
]=====],
}
