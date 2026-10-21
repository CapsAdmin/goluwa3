local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local weapons = import("lua/weapons.lua")
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))

T.Test("Weapons are built in prefabs with a model, a muzzle and a loaded script", function()
	for _, name in ipairs(weapons.GetNames()) do
		T(prefab.Get(name).builtin)["=="](true)
		local instance = Entity.New{prefab = {Path = name}}
		local model = instance.weapon:GetModel()
		T(model:GetParent())["=="](instance)
		T(model.transform:GetAttachment())["=="]("root")
		local muzzle = instance.weapon:GetMuzzle()
		T(muzzle:GetParent())["=="](model)
		T(muzzle.transform:GetPosition():GetLength())[">"](0.3)
		T(instance.script.Error == nil)["=="](true)
		T(instance[name] ~= nil)["=="](true)
		T(model.visibility:GetVisible())["=="](true)
		instance.weapon:UpdateModel(false)
		T(model.visibility:GetVisible())["=="](false)
		instance:Remove()
	end
end)

T.Test("A weapon holds its values in the weapon component", function()
	local instance = Entity.New{prefab = {Path = "weapon_pistol"}}
	T(instance.weapon:GetDisplayName())["=="]("Pistol")
	T(instance.weapon:GetSlot())["=="](2)
	T(instance.weapon:GetFireRate())["=="](0.25)
	instance:Remove()
end)
