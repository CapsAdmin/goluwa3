local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local potion = {}
potion.Kinds = {
	{Name = "health", DisplayName = "HP Potion", Color = Color(0.25, 1, 0.45, 1)},
	{Name = "mana", DisplayName = "MP Potion", Color = Color(0.25, 0.5, 1, 1)},
	{Name = "stamina", DisplayName = "SP Potion", Color = Color(1, 0.8, 0.2, 1)},
}
potion.Values = {
	WorldSize = Vec3(0.1, 0.18, 0.1),
	WorldCenter = Vec3(),
	Slot = 15,
	Category = "items",
	FireRate = 0.2,
}

function potion.CreateNodes(color)
	local glass = {
		Color = Color(color.r, color.g, color.b, 1),
		Emissive = Color(color.r, color.g, color.b, 2),
		Roughness = 0.1,
		Metallic = 0,
	}
	return {
		{
			guid = "flask",
			parent = "model",
			properties = {Name = "flask"},
			components = {
				transform = {Position = Vec3(0, 0.02, -0.03)},
				model = {
					ModelPath = "models/sphere.lua",
					ModelOptions = {radius = 0.05, segments = 20, rings = 10},
					MaterialConfig = glass,
				},
			},
		},
		{
			guid = "neck",
			parent = "model",
			properties = {Name = "neck"},
			components = {
				transform = {Position = Vec3(0, 0.09, -0.03)},
				model = {
					ModelPath = "models/box.lua",
					ModelOptions = {size = Vec3(0.025, 0.06, 0.025)},
					MaterialConfig = {Color = Color(0.85, 0.9, 1, 1), Roughness = 0.1, Metallic = 0},
				},
			},
		},
		{
			guid = "cork",
			parent = "model",
			properties = {Name = "cork"},
			components = {
				transform = {Position = Vec3(0, 0.13, -0.03)},
				model = {
					ModelPath = "models/box.lua",
					ModelOptions = {size = Vec3(0.03, 0.025, 0.03)},
					MaterialConfig = {Color = Color(0.45, 0.28, 0.15, 1), Roughness = 0.9, Metallic = 0},
				},
			},
		},
	}
end

potion.Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local effects = import("lua/jrpg/effects.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local sounds = import("lua/sounds.lua")
local META = objects.CreateTemplate("weapon_potion")
META:StartStorable()
META:GetSet("Kind", "health")
META:GetSet("Amount", 50)
META:GetSet("DrinkTime", 0.6)
META:EndStorable()
local OVERLOAD = Color(1, 0.5, 0.9, 1)
local DRINK_SOUNDS = {
	"ambient/levels/canals/toxic_slime_gurgle2.wav",
	"ambient/levels/canals/toxic_slime_gurgle4.wav",
	"ambient/levels/canals/toxic_slime_gurgle7.wav",
}

function META:GetHolder()
	return self.Owner:GetParent()
end

local function restore(holder, kind, amount)
	local rpg = holder.rpg

	if kind == "health" then
		local health = holder.health
		health:Heal(amount)
		return health:GetHealth() >= health:GetMaxHealth()
	elseif kind == "mana" and rpg then
		rpg:SetMana(math.min(rpg:GetMana() + amount, rpg:GetMaxMana()))
		return rpg:GetMana() >= rpg:GetMaxMana()
	elseif kind == "stamina" and rpg then
		rpg:SetStamina(math.min(rpg:GetStamina() + amount, rpg:GetMaxStamina()))
		return rpg:GetStamina() >= rpg:GetMaxStamina()
	end
end

function META:OnWeaponPrimary()
	if self.drinking then return false end

	local holder = self:GetHolder()
	holder.character_pose:PlayAction("drink", self.DrinkTime)
	self.drinking = 0
	return false
end

function META:OnWeaponThink(dt)
	if not self.drinking then return end

	self.drinking = self.drinking + dt

	if self.drinking < self.DrinkTime * 0.8 then return end

	self.drinking = nil
	local holder = self:GetHolder()

	if restore(holder, self.Kind, self.Amount) then
		status_effects.Add(holder, "confused", 0.25, holder)

		if status_effects.Get(holder, "confused") > 0.6 then
			effects.Text(holder, "OVERLOAD", OVERLOAD)
		end
	end
end

function META:OnWeaponHolster()
	self.drinking = nil
end

function META:OnUpdate()
	if not effects.Visual then return end

	local holder = self:GetHolder()
	local pose = holder:IsValid() and holder.character_pose

	if not pose or self.seen_actions == pose.Actions then return end

	self.seen_actions = pose.Actions

	if pose:GetActiveAction() == "drink" and self.Owner.weapon:IsActive() then
		sounds.PlayRandom(DRINK_SOUNDS, holder.transform:GetPosition(), 0.7, 1)
	end
end

return META:Register()
]=====]
return potion
