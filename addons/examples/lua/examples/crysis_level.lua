local steam = import("goluwa/steam/steam.lua")
local timer = import("goluwa/timer.lua")
local render3d = import("goluwa/render3d/render3d.lua")

timer.Delay(0, function()
	steam.SetCryLevel(
		"/run/media/caps/extra/SteamLibrary/steamapps/common/Crysis/Game/Levels/Multiplayer/PS/Beach/"
	)
	render3d.SetOceanEnabled(true)
	render3d.SetOceanLevel(190)
end)
