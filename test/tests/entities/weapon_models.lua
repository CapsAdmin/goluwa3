local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local weapon_models = import("lua/weapon_models.lua")

T.Test("Weapon models are built in prefabs with a muzzle node", function()
	for _, name in ipairs{"weapon_camera_model", "weapon_physgun_model", "weapon_pistol_model"} do
		T(prefab.Get(name).builtin)["=="](true)
		local instance = Entity.New{prefab = {Path = name}}
		local muzzle = instance.prefab:GetNode("muzzle")
		T(muzzle ~= nil)["=="](true)
		T(muzzle:GetParent())["=="](instance)
		T(muzzle.transform:GetPosition():GetLength())[">"](0.3)
		instance:Remove()
	end
end)

T.Test("A weapon model needs only its nodes registered", function()
	weapon_models.Register("test_weapon_model", {})
	local instance = Entity.New{prefab = {Path = "test_weapon_model"}}
	T(instance.prefab:GetNode("muzzle") == nil)["=="](true)
	T(#instance:GetChildren())["=="](0)
	instance:Remove()
	prefab.definitions.test_weapon_model = nil
end)

T.Test("A weapon is a built in prefab holding its values and its weapon component", function()
	import("lua/weapons.lua")
	Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
	Entity.RegisterComponent("weapon_pistol", import("lua/components/weapon_pistol.lua"))
	local instance = Entity.New{prefab = {Path = "weapon_pistol"}}
	T(prefab.Get("weapon_pistol").builtin)["=="](true)
	T(instance.weapon:GetDisplayName())["=="]("Pistol")
	T(instance.weapon:GetSlot())["=="](2)
	T(instance.weapon:GetFireRate())["=="](0.25)
	T(instance.weapon:GetModelPrefab())["=="]("weapon_pistol_model")
	T(instance.weapon_pistol ~= nil)["=="](true)
	instance:Remove()
end)
