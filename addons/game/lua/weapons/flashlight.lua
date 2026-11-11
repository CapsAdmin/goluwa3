local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local BULB = {
	Color = Color(1, 0.92, 0.7, 1),
	Roughness = 0.3,
	Metallic = 0,
	EmissiveMultiplier = Color(8, 7, 5, 1),
}
return {
	Components = {weapon_switch = {}},
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
		{
			guid = "lamp",
			parent = "model",
			properties = {Name = "lamp"},
			components = {transform = {Position = FORWARD * 0.03}},
		},
		{
			guid = "bulb",
			parent = "lamp",
			properties = {Name = "bulb"},
			components = {
				transform = {},
				visibility = {},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = 0.04},
					MaterialConfig = BULB,
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
META:GetSet("Lumen", 600)
META:EndStorable()
local SHADOW = {Size = Vec2(1024, 1024), PerspectiveFov = 60, NearPlane = 0.1, FarPlane = 250}
local EYE_FORWARD = 0.1
local aim = Matrix44()

function META:Initialize()
	self:AddGlobalEvent("Update")
end

function META:Toggle()
	local switch = self.Owner.weapon_switch
	switch:SetOn(not switch.On)
end

function META:OnWeaponPrimary()
	self:Toggle()
	return false
end

function META:OnWeaponPredictPrimary()
	self:Toggle()
	return false
end

function META:OnWeaponEquip()
	self.Owner.prefab:GetNode("bulb").visibility:SetVisible(false)
end

function META:OnWeaponHolster()
	self.Owner.weapon_switch:SetOn(false)
	self.Owner.prefab:GetNode("bulb").visibility:SetVisible(true)
end

function META:OnUpdate()
	if not RENDER_3D then return end

	local instance = self.Owner.prefab
	local lamp = instance:GetNode("lamp")
	local lit = self.Owner.weapon_switch.On and self.Owner.weapon:IsEquipped()
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
