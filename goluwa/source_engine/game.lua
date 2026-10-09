local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local game = {}
local map_games = {
	["gm_.+"] = {"garry's mod", "tf2", "css"},
	["rp_.+"] = {"garry's mod", "tf2", "css"},
	["ep1_.+"] = {"half-life 2: episode one"},
	["ep2_.+"] = {"half-life 2: episode two"},
	["trade_.+"] = {"half-life 2", "team fortress 2"},
	["d%d_.+"] = {"half-life 2"},
	["dm_.*"] = {"half-life 2: deathmatch"},
	["c%dm%d_.+"] = {"left 4 dead 2"},
	["esther"] = {"dear esther"},
	["jakobson"] = {"dear esther"},
	["donnelley"] = {"dear esther"},
	["paul"] = {"dear esther"},
	["aramaki_4d"] = {"team fortress 2", "garry's mod"},
	["de_overpass"] = {"counter-strike: global offensive"},
	["de_bank"] = {"counter-strike: global offensive"},
	["sp_a4_finale1"] = {"portal 2"},
	["c3m1_plankcountry"] = {"left 4 dead 2"},
	["achievement_apg_r11b"] = {"half-life 2", "team fortress 2"},
	["lostcoast"] = {"gmod"},
}

function game.GetMapPath(name)
	return "maps/" .. name .. ".bsp"
end

function game.EnsureMounted(path)
	local name = path:match("maps/(.+)%.bsp")

	if not name or name == "gm_old_flatgrass" then return end

	local games = map_games[name]

	if not games then
		for pattern, candidates in pairs(map_games) do
			if name:find(pattern) then
				games = candidates

				break
			end
		end
	end

	for _, game_name in ipairs(games or {}) do
		steam.MountSourceGame(game_name)
	end
end

do
	local mounted = {}

	-- mounts the pakfile embedded in a bsp so the materials, textures and models it ships with can be found
	function game.MountMapPak(path)
		game.EnsureMounted(path)
		local full = vfs.GetAbsolutePath(path)

		if not full then return false end

		if mounted[full] then return true end

		if not vfs.IsDirectory(full) then return false end

		vfs.Mount(full)
		mounted[full] = true
		return true
	end

	function game.UnmountMapPak(path)
		local full = vfs.GetAbsolutePath(path)

		if not full or not mounted[full] then return end

		mounted[full] = nil
		vfs.Unmount("bsp pakfile:" .. full)
	end
end

function game.FindMap(name)
	local path = game.GetMapPath(name)
	game.EnsureMounted(path)

	if vfs.IsFile(path) then return name end

	return nil, "could not find " .. path
end

return game
