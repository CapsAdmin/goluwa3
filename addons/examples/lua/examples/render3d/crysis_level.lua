local steam = import("goluwa/steam/steam.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local timer = import("goluwa/timer.lua")
local render3d = import("goluwa/render3d/render3d.lua")
steam.cry_skip_models = false
steam.SetCryLevel(
	"/run/media/caps/extra/SteamLibrary/steamapps/common/Crysis/Game/Levels/Multiplayer/PS/Shore/"
)
PLAYER_RIG.transform:SetPosition(Vec3(2040, 232, -2475))
