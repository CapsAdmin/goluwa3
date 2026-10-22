local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local weapons = import("lua/weapons.lua")
local scene = import("goluwa/entities/scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))

T.Test("Weapons are built in prefabs with a model, a loaded script and a muzzle on tools", function()
	for _, name in ipairs(weapons.GetNames()) do
		T(prefab.Get(name).builtin)["=="](true)
		local instance = Entity.New{prefab = {Path = name}}
		local model = instance.weapon:GetModel()
		T(model:GetParent())["=="](instance)
		T(model.transform:GetAttachment())["=="]("root")
		if instance.weapon:GetCategory() == "tools" then
			local muzzle = instance.weapon:GetMuzzle()
			T(muzzle:GetParent())["=="](model)
			T(muzzle.transform:GetPosition():GetLength())[">"](0.3)
		end

		T(instance.script.Error == nil)["=="](true)
		T(instance.script.instance ~= nil)["=="](true)
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

T.Test("Spawned weapons serialize and come back with their script values", function()
	for _, name in ipairs(weapons.GetNames()) do
		local weapon = weapons.Spawn(name, Vec3(0, 1, 0))
		local data = scene.SerializeEntities({weapon})
		T(#data.entities)[">"](0)
		weapon:Remove()
		local copy = scene.Deserialize(data, Entity.World)[1]
		T(copy:GetName())["=="](name)
		T(copy.script.instance ~= nil)["=="](true)
		copy:Remove()
	end

	local magic = weapons.Spawn("weapon_magic_ice", Vec3())
	local copy = scene.Deserialize(scene.SerializeEntities({magic}), Entity.World)[1]
	magic:Remove()
	T(copy.weapon_magic:GetElement())["=="]("ice")
	copy:Remove()
end)
