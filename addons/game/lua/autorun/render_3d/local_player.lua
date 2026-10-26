local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local SpawnPoint = import("goluwa/entities/components/spawn_point.lua")
import("lua/weapons.lua")
import("lua/damage.lua")
Entity.RegisterComponent("camera", import("lua/components/camera.lua"))
Entity.RegisterComponent("player_input", import("lua/components/player_input.lua"))
local current = Entity.World:GetKeyed("player_camera_rig")

if current and current:IsValid() then current:Remove() end

local cam = render3d.GetCamera()
local rig = Entity.New{
	Key = "player_camera_rig",
	Name = import("goluwa/network/clients.lua").GetLocalClient():GetNick(),
	ComponentSet = {
		"transform",
		"camera",
		"player_input",
		"player_controller",
		"character_movement",
		"character_pose",
		"attachment_points",
		"procedural_pose",
		"ragdoll",
		"weapon_holder",
		"player_avatar",
		"health",
	},
	camera = {
		Active = true,
	},
	player_input = {
		Mode = "fly",
	},
	player_controller = {
		Networked = true,
	},
}
_G.PLAYER_RIG = rig
rig.weapon_holder:GiveLoadout()
rig.character_movement:SetEyePosition(cam:GetPosition())
rig.player_input:SyncFromCamera(cam)
system.GetWindow():SetMouseTrapped(true)

-- the player exists before the map does, so it is placed once per scene load on the first spawn point that shows up, unless a server decides that
local function place_on_first_spawn_point()
	local spawn = SpawnPoint.Pick("deathmatch", "start") or SpawnPoint.Pick()

	if not spawn then return end

	event.RemoveListener("Update", "player_spawn_point")

	if network.IsConnected() then return end

	rig.player_controller:Spawn(spawn:GetPlacement(0))
end

event.AddListener("Update", "player_spawn_point", place_on_first_spawn_point)

event.AddListener("SceneCleared", "player_spawn_point", function()
	event.AddListener("Update", "player_spawn_point", place_on_first_spawn_point)
end)
