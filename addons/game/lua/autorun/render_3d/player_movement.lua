local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local network = import("goluwa/network/network.lua")
local SpawnPoint = import("goluwa/entities/components/spawn_point.lua")
Entity.RegisterComponent("camera", import("lua/components/camera.lua"))
Entity.RegisterComponent("player_input", import("lua/components/player_input.lua"))
local current = Entity.World:GetKeyed("player_camera_rig")

if current and current:IsValid() then current:Remove() end

local cam = render3d.GetCamera()
local rig = Entity.New{
	Key = "player_camera_rig",
	Name = "player_camera_rig",
	ComponentSet = {
		"transform",
		"camera",
		"player_input",
		"player_controller",
		"player_movement",
		"weapon_holder",
		"player_avatar",
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
rig.weapon_holder:Give("weapon_camera")
rig.weapon_holder:Give("weapon_physgun")
rig.weapon_holder:Give("weapon_pistol")
rig.transform:SetPosition(cam:GetPosition():Copy())
rig.player_input:SyncFromCamera(cam)
system.GetWindow():SetMouseTrapped(true)
local FLASHLIGHT_LUMEN = 3
local flashlight = Entity.New{
	Name = "flashlight",
	transform = {},
	light_spot = {
		Lumen = 0,
		OcclusionMap = false,
	},
}
local flash_map = ShadowMap.New{
	mode = "directional",
	light = flashlight,
	perspective_fov = math.rad(60),
	size = Vec2() + 1024,
	max_shadow_distance = 250,
	near_plane = 0.1,
	far_plane = 250,
}
flash_map:SetEnabled(false)
local flashlight_on = false
local f_was_down = false

event.AddListener("Update", "flashlight", function()
	local view = rig.camera:GetView()
	flashlight.transform:SetPosition(view:GetPosition() + Vec3(0, -0.6, 0))
	flashlight.transform:SetRotation(view:GetRotation():Copy())
	local f_down = input.IsKeyDown("f")

	if f_down and not f_was_down then
		flashlight_on = not flashlight_on
		flashlight.light_spot:SetLumen(flashlight_on and FLASHLIGHT_LUMEN or 0)
		flash_map:SetEnabled(flashlight_on)
	end

	f_was_down = f_down
end)

-- the player exists before the map does, so it is placed once on the first spawn point that shows up, unless a server decides that
-- it starts in fly mode, where the transform is the eye
event.AddListener("Update", "player_spawn_point", function()
	local spawn = SpawnPoint.Pick("deathmatch", "start") or SpawnPoint.Pick()

	if not spawn then return end

	event.RemoveListener("Update", "player_spawn_point")

	if network.IsConnected() then return end

	rig.player_controller:Spawn(spawn:GetPlacement(rig.player_movement.EyeHeight))
end)
