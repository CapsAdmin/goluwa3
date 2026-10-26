local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local BODY = {Color = Color(0.12, 0.12, 0.13, 1), Roughness = 0.55, Metallic = 0.6}
local STRAP = {Color = Color(0.2, 0.16, 0.12, 1), Roughness = 0.9, Metallic = 0}
local LENS = {Color = Color(0.85, 0.88, 0.9, 1), Roughness = 0.05, Metallic = 0.2}
return {
	Values = {
		WorldSize = Vec3(0.07, 0.07, 0.14),
		WorldCenter = Vec3(),
		Slot = 3,
		Category = "items",
		DisplayName = "Flashlight",
		Mount = "chest",
		PoseArms = false,
		FireRate = 0.2,
	},
	Nodes = {
		nodes.Box("strap", Vec3(0.09, 0.02, 0.012), Vec3(), STRAP),
		{
			guid = "lamp",
			parent = "model",
			properties = {Name = "lamp"},
			components = {transform = {Position = FORWARD * 0.03}},
		},
		{
			guid = "housing",
			parent = "lamp",
			properties = {Name = "housing"},
			components = {
				transform = {Position = FORWARD * 0.02},
				model = {
					ModelPath = "models/box.lua",
					ModelOptions = {size = Vec3(0.05, 0.05, 0.08)},
					MaterialConfig = BODY,
				},
			},
		},
		{
			guid = "lens",
			parent = "lamp",
			properties = {Name = "lens"},
			components = {
				transform = {Position = FORWARD * 0.065},
				model = {
					ModelPath = "models/box.lua",
					ModelOptions = {size = Vec3(0.042, 0.042, 0.01)},
					MaterialConfig = LENS,
				},
			},
		},
		{
			guid = "light",
			parent = "root",
			properties = {Name = "light"},
			components = {
				transform = {},
				light_spot = {Lumen = 0, InnerCone = 8, OuterCone = 26, OcclusionMap = false},
			},
		},
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local prefab = import("goluwa/entities/prefab.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("weapon_flashlight")
META:StartStorable()
META:GetSet("On", false)
META:GetSet("Lumen", 600)
META:EndStorable()
local SHADOW = {Size = Vec2(1024, 1024), PerspectiveFov = 60, NearPlane = 0.1, FarPlane = 250}
local EYE_FORWARD = 0.1
local aim = Matrix44()

function META:Initialize()
	self:AddGlobalEvent("Update")
end

function META:OnWeaponPrimary()
	self:SetOn(not self.On)
	return false
end

function META:OnWeaponHolster()
	self:SetOn(false)
end

function META:OnUpdate()
	if not RENDER_3D then return end

	local instance = self.Owner.prefab
	local lamp = instance:GetNode("lamp")
	local lit = self.On and self.Owner.weapon:IsEquipped()
	prefab.Suppress()

	if lit ~= self.lit then
		self.lit = lit
		local light = instance:GetNode("light")
		light.light_spot:SetLumen(lit and self.Lumen or 0)

		if lit then light:EnsureComponent("shadow_map_directional", SHADOW) end

		if light.shadow_map_directional then
			light.shadow_map_directional:SetEnabled(lit)
		end

		if not lit then lamp.transform:SetRotation(Quat():Identity()) end
	end

	-- the beam starts at the eyes, where the shadows of what the holder carries fall behind it, and not at the lamp on the chest
	if lit then
		local holder = self.Owner:GetParent()
		local rotation = holder.character_pose.aim_rotation
		aim:Identity()
		aim:SetRotation(rotation)
		lamp.transform:SetRotation(aim:GetMultiplied(lamp:GetParent().transform:GetWorldMatrixInverse()):GetRotation())
		local eye = Vec3(holder.transform:GetWorldMatrix():GetTranslation()) + holder.character_movement:GetViewOffset() + rotation:GetForward() * EYE_FORWARD
		aim:SetTranslation(eye.x, eye.y, eye.z)
		local light = aim:GetMultiplied(self.Owner.transform:GetWorldMatrixInverse())
		local light_transform = instance:GetNode("light").transform
		light_transform:SetPosition(Vec3(light:GetTranslation()))
		light_transform:SetRotation(light:GetRotation())
	end

	prefab.Unsuppress()
end

return META:Register()
]=====],
}
