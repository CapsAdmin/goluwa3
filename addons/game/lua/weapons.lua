local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
Entity.RegisterComponent("tool_beam", import("lua/components/tool_beam.lua"))
Entity.RegisterComponent("weapon_switch", import("lua/components/weapon_switch.lua"))
local weapons = {}
weapons.Definitions = {}
weapons.RootComponents = {}

function weapons.AddRootComponent(name, config)
	weapons.RootComponents[name] = config

	for _, definition in pairs(weapons.Definitions) do
		definition.Entities[1].components[name] = config
	end
end

function weapons.Register(name, values, nodes, source, script_values, components)
	local entities = {
		{
			guid = "root",
			components = {
				weapon = values,
				usable = {Prompt = "take"},
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

	for component, config in pairs(weapons.RootComponents) do
		entities[1].components[component] = config
	end

	for component, config in pairs(components or {}) do
		entities[1].components[component] = config
	end

	weapons.Definitions[name] = {DisplayName = values.DisplayName, Entities = entities}

	for _, node in ipairs(nodes) do
		if node.guid then
			entities[#entities + 1] = node
		else
			for _, child in ipairs(node) do
				entities[#entities + 1] = child
			end
		end
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

weapons.Loadout = {
	"weapon_camera",
	"weapon_physgun",
	"weapon_pistol",
	"weapon_hands",
	"weapon_flashlight",
	"weapon_sword",
	"weapon_sound_test",
}

for _, name in ipairs{
	"camera",
	"physgun",
	"pistol",
	"grenade",
	"hands",
	"flashlight",
	"sword",
	"sound_test",
} do
	local definition = import("lua/weapons/" .. name .. ".lua")
	weapons.Register(
		"weapon_" .. name,
		definition.Values,
		definition.Nodes,
		definition.Source,
		definition.ScriptValues,
		definition.Components
	)
end

return weapons
