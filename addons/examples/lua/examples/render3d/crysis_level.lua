local steam = import("goluwa/steam/steam.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local timer = import("goluwa/timer.lua")
local render3d = import("goluwa/render3d/render3d.lua")
steam.SetCryLevel(
	"/run/media/caps/extra/SteamLibrary/steamapps/common/Crysis/Game/Levels/Multiplayer/PS/Beach/"
)
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(190)
PLAYER_RIG.transform:SetPosition(Vec3(2475, 232, -2040))
