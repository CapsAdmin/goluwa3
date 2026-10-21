local prefab = import("goluwa/entities/prefab.lua")
local weapons = {}
weapons.Definitions = {}

function weapons.Register(name, values, model_prefab)
	weapons.Definitions[name] = {DisplayName = values.DisplayName, Model = model_prefab}
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
weapons.Register(
	"weapon_pistol",
	{Slot = 2, DisplayName = "Pistol", FireRate = 0.25},
	"weapon_pistol_model"
)

function weapons.GetNames()
	local names = {}

	for name in pairs(weapons.Definitions) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

weapons.Loadout = {"weapon_camera", "weapon_physgun", "weapon_pistol"}
return weapons
