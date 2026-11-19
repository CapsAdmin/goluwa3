local Color = import("goluwa/structs/color.lua")
local commands = import("goluwa/cli/commands.lua")
local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local weapons = import("lua/weapons.lua")
local animations = import("lua/animations.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local weapon_categories = import("lua/weapon_categories.lua")
local players = import("lua/players.lua")
weapon_categories.Register{Name = "hl2", Icon = "pistol", Label = "HL2", Color = Color(1, 0.55, 0.1, 1)}
animations.Register(
	"hl2_swing",
	{
		Kind = "action",
		AimKeys = {{0, 0, 0}, {0.2, 0.15, 0.7}, {0.5, -0.2, -0.45}, {1, 0, 0}},
	}
)
weapon_effects.RegisterMuzzle(
	"hl2_pistol",
	{
		Sounds = {"weapons/pistol/pistol_fire2.wav", "weapons/pistol/pistol_fire3.wav"},
		Size = 0.8,
	}
)
weapon_effects.RegisterMuzzle(
	"hl2_357",
	{
		Sounds = {"weapons/357/357_fire2.wav", "weapons/357/357_fire3.wav"},
		Size = 1.4,
		SPL = 150,
		Keep = 0.3,
	}
)
weapon_effects.RegisterMuzzle("hl2_smg1", {Sounds = {"weapons/smg1/smg1_fire1.wav"}, Size = 0.9})
weapon_effects.RegisterMuzzle(
	"hl2_ar2",
	{
		Sounds = {"weapons/ar2/fire1.wav"},
		Size = 1,
		Color = Color(0.45, 0.7, 1, 1),
		Brightness = 20,
	}
)
weapon_effects.RegisterMuzzle(
	"hl2_ar2_ball",
	{Size = 1.6, Color = Color(0.45, 0.7, 1, 1), Brightness = 25, Lumen = 120}
)
weapon_effects.RegisterMuzzle(
	"hl2_shotgun",
	{
		Sounds = {"weapons/shotgun/shotgun_fire6.wav", "weapons/shotgun/shotgun_fire7.wav"},
		Size = 1.25,
		SPL = 148,
		Keep = 0.25,
	}
)
weapon_effects.RegisterMuzzle(
	"hl2_shotgun_double",
	{
		Sounds = {"weapons/shotgun/shotgun_dbl_fire.wav", "weapons/shotgun/shotgun_dbl_fire7.wav"},
		Size = 1.6,
		SPL = 152,
		Keep = 0.3,
	}
)
weapon_effects.RegisterMuzzle("hl2_rpg", {Size = 2.2, Lumen = 150})
local NAMES = {
	"crowbar",
	"stunstick",
	"physcannon",
	"pistol",
	"357",
	"smg1",
	"ar2",
	"shotgun",
	"crossbow",
	"rpg",
	"frag",
	"bugbait",
}

for _, name in ipairs(NAMES) do
	local definition = import("lua/weapons/hl2_" .. name .. ".lua")
	weapons.Register(
		"weapon_hl2_" .. name,
		definition.Values,
		definition.Nodes,
		definition.Source,
		definition.ScriptValues,
		definition.Components
	)
end

local function give_all(player)
	for _, name in ipairs(NAMES) do
		if not player.weapon_holder:FindWeapon("weapon_hl2_" .. name) then
			player.weapon_holder:Give("weapon_hl2_" .. name)
		end
	end
end

if SERVER then
	message.AddListener("hl2_give_all", function(client)
		give_all(players.Get(client))
	end)
end

commands.Add("give_hl2", function()
	if network.HasAuthority() then
		give_all(players.GetLocal())
	else
		message.Send("hl2_give_all")
	end
end)
