local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
local weapons = {}
weapons.Definitions = {}

function weapons.Register(name, values, nodes, source)
	weapons.Definitions[name] = {DisplayName = values.DisplayName}
	local entities = {
		{guid = "root", components = {weapon = values, usable = {Prompt = "pick up"}, item_highlight = {}, script = {Source = source}}},
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

weapons.Loadout = {"weapon_camera", "weapon_physgun", "weapon_pistol"}

for _, name in ipairs{"camera", "physgun", "pistol"} do
	local definition = import("lua/weapons/" .. name .. ".lua")
	weapons.Register("weapon_" .. name, definition.Values, definition.Nodes, definition.Source)
end

return weapons
