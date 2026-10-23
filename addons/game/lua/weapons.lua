local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
local weapons = {}
weapons.Definitions = {}

function weapons.Register(name, values, nodes, source, script_values)
	weapons.Definitions[name] = {DisplayName = values.DisplayName}
	local entities = {
		{
			guid = "root",
			components = {
				weapon = values,
				usable = {Prompt = "pick up"},
				item_highlight = {},
				script = {Source = source, Values = script_values},
			},
		},
		{
			guid = "model",
			parent = "root",
			properties = {Name = "model"},
			components = {transform = {Attachment = "hand_r"}, visibility = {Visible = false}},
		},
	}

	for _, node in ipairs(nodes) do
		entities[#entities + 1] = node
	end

	prefab.Register(name, {inputs = {}, entities = entities}).builtin = true
end

function weapons.Spawn(name, position, rotation)
	return Entity.New{
		Name = name,
		Transient = false,
		transform = {Position = position, Rotation = rotation},
		network = SERVER and {} or nil,
		prefab = {Path = name},
	}
end

function weapons.GetNames()
	local names = {}

	for name in pairs(weapons.Definitions) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

weapons.Loadout = {"weapon_camera", "weapon_physgun", "weapon_pistol", "weapon_toolgun"}

for _, name in ipairs{"camera", "physgun", "pistol", "sword", "shield", "grenade", "toolgun"} do
	local definition = import("lua/weapons/" .. name .. ".lua")
	weapons.Register("weapon_" .. name, definition.Values, definition.Nodes, definition.Source)
end

do
	local damage_types = import("lua/jrpg/damage_types.lua")
	local magic = import("lua/weapons/magic.lua")

	for i, name in ipairs(damage_types.Names) do
		local definition = damage_types.Get(name)
		local values = table.shallow_copy(magic.Values)
		values.Slot = magic.Values.Slot + i - 1
		values.DisplayName = definition.DisplayName
		weapons.Register(
			"weapon_magic_" .. name,
			values,
			magic.CreateNodes(definition.Color),
			magic.Source,
			{Element = name}
		)
	end

	local potion = import("lua/weapons/potion.lua")

	for i, kind in ipairs(potion.Kinds) do
		local values = table.shallow_copy(potion.Values)
		values.Slot = potion.Values.Slot + i - 1
		values.DisplayName = kind.DisplayName
		weapons.Register(
			"weapon_potion_" .. kind.Name,
			values,
			potion.CreateNodes(kind.Color),
			potion.Source,
			{Kind = kind.Name}
		)
	end
end

return weapons
