local T = import("test/environment.lua")
local steam = import("goluwa/steam/steam.lua")
local game = import("goluwa/source_engine/game.lua")
local engines = import("goluwa/engines.lua")
import("goluwa/render3d/model_loader.lua")

local function find_map(maps, name)
	for _, map in ipairs(maps) do
		if map.engine == "source" and map.name == name then return map end
	end
end

T.Test("source maps are listed without mounting and more once mounted", function()
	local gmod = steam.FindSourceGame("gmod")

	if not gmod then return end

	steam.UnmountSourceGame(gmod)
	local unmounted = engines.GetMaps()
	local map = find_map(unmounted, "gm_construct")
	T(map ~= nil)["=="](true)
	T(map.game)["=="](gmod.filesystem.steamappid)
	T(map.mounted)["=="](false)
	T(steam.IsSourceGameMounted(gmod))["=="](false)
	T(#engines.GetMaps() >= #unmounted)["=="](true)
	engines.MountGame("source", gmod.filesystem.steamappid)
	map = find_map(engines.GetMaps(), "gm_construct")
	T(map.mounted)["=="](true)
	T(engines.GetMapThumbnail(map))["=="]("maps/thumb/gm_construct.png")
	engines.UnmountGame("source", gmod.filesystem.steamappid)
	T(steam.IsSourceGameMounted(gmod))["=="](false)
end)

T.Test("source games that can be mounted have art and a name", function()
	for _, info in ipairs(engines.GetGames()) do
		T(info.name ~= nil)["=="](true)
		T(info.id ~= nil)["=="](true)
	end

	for _, info in ipairs(game.GetMountableGames()) do
		T(info.gameinfo_path:ends_with(".gi"))["=="](false)
	end
end)
