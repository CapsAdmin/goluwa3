local prefab = import("goluwa/entities/prefab.lua")
local weapons = library()

-- the entity of a weapon is the prefab of its name, the weapon component holds what every weapon has and the weapon_* component what it does
function weapons.Register(name, values)
	prefab.Register(
		name,
		{
			inputs = {},
			entities = {{guid = "root", components = {weapon = values, [name] = {}}}},
		}
	).builtin = true
end

weapons.Register(
	"weapon_camera",
	{Slot = 3, DisplayName = "Camera", ModelPrefab = "weapon_camera_model", HiddenInFirstPerson = true}
)
weapons.Register("weapon_physgun", {Slot = 1, DisplayName = "Physgun", ModelPrefab = "weapon_physgun_model"})
weapons.Register(
	"weapon_pistol",
	{Slot = 2, DisplayName = "Pistol", ModelPrefab = "weapon_pistol_model", FireRate = 0.25}
)

weapons.Loadout = {"weapon_camera", "weapon_physgun", "weapon_pistol"}
return weapons
