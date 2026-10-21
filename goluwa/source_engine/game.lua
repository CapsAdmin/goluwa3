local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local vtf = import("goluwa/codecs/vtf.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local pvars = import("goluwa/cli/pvars.lua")
local game = {}
pvars.StartGroup("Engine", "Source maps", {prefix = "source_"})
game.chain_levels_pvar = pvars.Setup2{
	key = "source_chain_levels",
	default = false,
	help = "load the neighbouring levels of a chapter together, joined at their landmarks",
}
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
	for _, installed in ipairs(steam.GetGames()) do
		if installed.appid == info.filesystem.steamappid then return installed.name end
	end

	return info.game
end

function game.GetGameImage(info)
	return steam.GetGameImage(info.filesystem.steamappid, "header") or
		steam.GetGameImage(info.appid, "header")
end

function game.ListLooseMaps(info)
	local names = {}
	local seen = {}

	for _, path in ipairs(info.filesystem.searchpaths) do
		if
			path:starts_with(info.vdf_directory) and
			not path:ends_with("*") and
			not path:ends_with(".vpk/")
		then
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
	local cache = {}

	function game.GetChapters(info)
		local appid = info.filesystem.steamappid

		if cache[appid] then return cache[appid] end

		local chapters = {}

		for _, file in ipairs(vfs.Find("os:" .. info.vdf_directory .. "cfg/chapter.-%.cfg$")) do
			local id = file:sub(1, -5)
			local map = vfs.Read("os:" .. info.vdf_directory .. "cfg/" .. file):match("map%s+(%S+)%s*$")

			if map then
				local number, suffix = id:match("chapter(%d+)(%a*)")
				local thumbnail

				for _, path in ipairs(info.filesystem.searchpaths) do
					if path:starts_with(info.vdf_directory) and not path:ends_with("*") then
						local full = path .. "materials/vgui/chapters/" .. id .. ".vtf"
						local os_full = path:ends_with(".vpk/") and full or "os:" .. full

						if vfs.IsFile(os_full) then
							thumbnail = os_full

							break
						end
					end
				end

				local crop

				if thumbnail then
					local data = vfs.Read(thumbnail)
					local meta, pixels = vtf.DecodeBuffer(Buffer.New(data, #data))
					local min_x, min_y, max_x, max_y = vtf.GetOpaqueBounds(meta, pixels)

					if
						max_x and
						min_x <= 1 and
						min_y <= 1 and
						max_x < meta.width * 0.9 and
						max_y < meta.height * 0.9
					then
						crop = {0, 0, (max_x - 1) / meta.width, (max_y - 1) / meta.height}
					end
				end

				chapters[#chapters + 1] = {
					id = id,
					map = map,
					thumbnail = thumbnail,
					crop = crop,
					order = tonumber(number) * 256 + (suffix:byte() or 0),
				}
			end
		end

		table.sort(chapters, function(a, b)
			return a.order < b.order
		end)

		cache[appid] = chapters
		return chapters
	end
end

do
	local TAIL_ORDER = 1e6

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

	function game.GetMaps()
		local maps = {}
		local seen = {}
		local mounted_games = {}

		local ranks = {}

		for rank, info in ipairs(game.GetMountableGames()) do
			local mounted = steam.IsSourceGameMounted(info)
			ranks[info.filesystem.steamappid] = rank

			if mounted then mounted_games[#mounted_games + 1] = info end

			local names = game.ListLooseMaps(info)
			table.sort(names)
			local chapters_by_map = {}

			for _, chapter in ipairs(game.GetChapters(info)) do
				chapters_by_map[chapter.map] = chapter
			end

			local current

			for _, name in ipairs(names) do
				local chapter = chapters_by_map[name]

				if chapter then
					current = chapter
				elseif current and name:match("^[^_]+") ~= current.map:match("^[^_]+") then
					current = nil
				end

				if not seen[name] then
					seen[name] = true
					maps[#maps + 1] = {
						name = name,
						game = info.filesystem.steamappid,
						mounted = mounted,
						order = current and current.order or TAIL_ORDER,
						chapter_thumbnail = current and current.thumbnail,
						chapter_thumbnail_crop = current and current.crop,
					}
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
			local rank_a = ranks[a.game] or math.huge
			local rank_b = ranks[b.game] or math.huge

			if rank_a ~= rank_b then return rank_a < rank_b end

			local order_a = a.order or TAIL_ORDER
			local order_b = b.order or TAIL_ORDER

			if order_a ~= order_b then return order_a < order_b end

			return a.name < b.name
		end)

		return maps
	end
end

do
	local candidates = {"maps/thumb/%s.png", "materials/vgui/maps/menu_thumb_%s.vtf"}

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
