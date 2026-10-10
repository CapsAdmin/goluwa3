local prefab = import("goluwa/entities/prefab.lua")
local weapons = library()

-- the entity of a weapon is the prefab of its name, the weapon component holds what every weapon has and the weapon_* component what it does
-- its model is an instance of a model prefab, a node of the weapon that sits on the right hand and is shown while the weapon is held
function weapons.Register(name, values, model_prefab)
	prefab.Register(
		name,
		{
			inputs = {},
			entities = {
				{guid = "root", components = {weapon = values, [name] = {}}},
				{
					guid = "model",
					parent = "root",
					properties = {Name = "model"},
					components = {
						prefab = {Path = model_prefab},
						transform = {Attachment = "hand_r"},
						visibility = {Visible = false},
					},
				},
			},
		}
	).builtin = true
end

weapons.Register(
	"weapon_camera",
	{Slot = 3, DisplayName = "Camera", HiddenInFirstPerson = true},
	"weapon_camera_model"
)
weapons.Register("weapon_physgun", {Slot = 1, DisplayName = "Physgun"}, "weapon_physgun_model")
weapons.Register("weapon_pistol", {Slot = 2, DisplayName = "Pistol", FireRate = 0.25}, "weapon_pistol_model")

weapons.Loadout = {"weapon_camera", "weapon_physgun", "weapon_pistol"}
return weapons
