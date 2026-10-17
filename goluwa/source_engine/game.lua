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

do
	local owners

	-- which game ships a map as a loose file, so a map can be loaded without knowing what to mount
	local function get_map_owner(name)
		if not owners then
			owners = {}

			for _, info in ipairs(game.GetMountableGames()) do
				for _, map_name in ipairs(game.ListLooseMaps(info)) do
					owners[map_name] = owners[map_name] or info
				end
			end
		end

		return owners[name]
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

		if not games then
			local owner = get_map_owner(name)

			if owner then steam.MountSourceGame(owner) end
		end
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

-- source 1 games installed through steam. source 2 games ship no bsp and a source mod has no appid to mount it by
function game.GetMountableGames()
	local games = {}

	for _, info in ipairs(steam.GetSourceGames()) do
		if info.filesystem.steamappid and not info.gameinfo_path:ends_with(".gi") then
			games[#games + 1] = info
		end
	end

	return games
end

function game.GetGameName(info)
	if info.appid == info.filesystem.steamappid then
		for _, installed in ipairs(steam.GetGames()) do
			if installed.appid == info.appid then return installed.name end
		end
	end

	return info.game
end

function game.GetGameImage(info)
	return steam.GetGameImage(info.filesystem.steamappid, "header") or
		steam.GetGameImage(info.appid, "header")
end

-- the maps a game ships as loose files in its own folders. packed maps and the ones in addons and workshop content are only found by mounting, which is the part that costs
function game.ListLooseMaps(info)
	local names = {}
	local seen = {}

	for _, path in ipairs(info.filesystem.searchpaths) do
		if not path:ends_with("*") and not path:ends_with(".vpk/") then
			for _, file in ipairs(vfs.Find("os:" .. path .. "maps/%.bsp$")) do
				local name = file:sub(1, -5)

				if not seen[name] then
					seen[name] = true
					names[#names + 1] = name
				end
			end
		end
	end

	return names
end

do
	local function find_owner(path, mounted_games)
		for _, info in ipairs(mounted_games) do
			if path:starts_with(info.vdf_directory) then return info end
		end

		for _, info in ipairs(mounted_games) do
			if path:find("/workshop/content/" .. info.filesystem.steamappid .. "/", nil, true) then
				return info
			end

			for _, search_path in ipairs(info.filesystem.searchpaths) do
				if not search_path:ends_with("*") and path:starts_with(search_path) then
					return info
				end
			end
		end
	end

	-- {name, game = appid, mounted} for every map that can be listed right now, the maps of mounted games included
	function game.GetMaps()
		local maps = {}
		local seen = {}
		local mounted_games = {}

		for _, info in ipairs(game.GetMountableGames()) do
			local mounted = steam.IsSourceGameMounted(info)

			if mounted then mounted_games[#mounted_games + 1] = info end

			for _, name in ipairs(game.ListLooseMaps(info)) do
				if not seen[name] then
					seen[name] = true
					maps[#maps + 1] = {name = name, game = info.filesystem.steamappid, mounted = mounted}
				end
			end
		end

		if mounted_games[1] then
			for _, file in ipairs(vfs.Find("maps/%.bsp$")) do
				local name = file:sub(1, -5)

				if not seen[name] then
					seen[name] = true
					local path = vfs.GetAbsolutePath("maps/" .. file)
					local owner = path and find_owner(path, mounted_games)
					maps[#maps + 1] = {
						name = name,
						game = owner and owner.filesystem.steamappid,
						mounted = true,
					}
				end
			end
		end

		table.sort(maps, function(a, b)
			return a.name < b.name
		end)

		return maps
	end
end

do
	local candidates = {"maps/thumb/%s.png", "materials/vgui/maps/menu_thumb_%s.vtf"}

	-- a vfs path to the menu picture of a map, nil if the game ships none. an unmounted game is only searched in its loose folders
	function game.GetMapThumbnail(name, info)
		if info and not steam.IsSourceGameMounted(info) then
			for _, path in ipairs(info.filesystem.searchpaths) do
				if not path:ends_with("*") and not path:ends_with(".vpk/") then
					for _, candidate in ipairs(candidates) do
						local full = path .. candidate:format(name)

						if vfs.IsFile("os:" .. full) then return "os:" .. full end
					end
				end
			end

			return
		end

		for _, candidate in ipairs(candidates) do
			local path = candidate:format(name)

			if vfs.IsFile(path) then return path end
		end
	end
end

function game.FindMap(name)
	local path = game.GetMapPath(name)
	game.EnsureMounted(path)

	if vfs.IsFile(path) then return name end

	return nil, "could not find " .. path
end

return game
