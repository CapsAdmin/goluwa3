local steam = import("goluwa/steam/steam.lua")
local timer = import("goluwa/timer.lua")

timer.Delay(0, function()
	steam.SetCryLevel(
		"/run/media/caps/extra/SteamLibrary/steamapps/common/Crysis/Game/Levels/Multiplayer/PS/Beach/"
	)
end)
