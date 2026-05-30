local commands = import("goluwa/commands.lua")
local pvars = import("goluwa/pvars.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/helpers/file_path.lua")
local codec = import("goluwa/codec.lua")
local utility = import("goluwa/utility.lua")
local Entity = import("goluwa/ecs/entity.lua")
return function(steam)
	commands.Add("mount=string", function(game)
		local game_info = assert(steam.MountSourceGame(game))
		llog("mounted %s", game_info.name)
	end)

	commands.Add("unmount=string", function(game)
		local game_info = assert(steam.UnmountSourceGame(game))
		llog("unmounted %s", game_info.name)
	end)

	commands.Add("mount_all=string", function(game)
		steam.MountAllSourceGames()
	end)

	commands.Add("unmount_all", function()
		steam.UnmountAllSourceGames()
	end)

	commands.Add("mount_clear", function()
		local ok = false

		for i, v in ipairs(vfs.Find("cache/archive/", true)) do
			vfs.Delete(v)
			ok = true
		end

		if not ok and vfs.Delete("cache/source_games") then ok = true end

		if vfs.Delete("cache/steam_games") then ok = true end

		steam.library_folders_cache = nil
		steam.games_cache = nil
		steam.source_games_cache = nil

		if ok then
			logn("removed cache/archive/*, data/source_games, and data/steam_games")
		else
			logn("nothing to remove")
		end
	end)

	pvars.Setup2{
		key = "steam_mount",
		default = {},
		get_list = function()
			local lst = {}

			for _, info in pairs(steam.GetSourceGames()) do
				lst[info.filesystem.steamappid] = {friendly = info.name}
			end

			return lst
		end,
		callback = function(lst)
			-- TODO
			do
				return
			end

			for appid, v in pairs(steam.GetMountedSourceGames()) do
				steam.UnmountSourceGame(appid)
			end

			for i, v in ipairs(lst) do
				steam.MountSourceGame(v)
			end
		end,
	}

	commands.Add("list_games", function()
		if not next(steam.GetSourceGames()) then
			logn("no source games found")
			table.print(steam.GetGameFolders())
			table.print(steam.GetLibraryFolders())
		end

		for _, info in pairs(steam.GetSourceGames()) do
			logn(info.game)
			logn("\tgame_dir = ", info.game_dir)
			logn("\tappid = ", info.filesystem.steamappid)
			logn()
		end
	end)

	commands.Add("list_maps", function(search)
		for _, name in ipairs(vfs.Find("maps/%.bsp$")) do
			if not search or name:find(search) then logn(name:sub(0, -5)) end
		end
	end)

	commands.Add("game_info=string", function(game)
		local info = steam.FindSourceGame(game)
		print(vfs.Read(info.gameinfo_path))
		table.print(info)
	end)

	local tries = {
		{path = "__MAPNAME__"},
		{path = "maps/__MAPNAME__.obj"},
		{
			path = "__MAPNAME__/__MAPNAME__.obj",
			callback = function(ent)
				ent:SetSize(0.01)
				ent:SetRotation(Quat(-1, 0, 0, 1))
			end,
		},
	}

	commands.Add("map=string_trim|nil", function(name)
		if not name then
			for _, path in ipairs(vfs.Find("maps/.-%.bsp")) do
				print(file_path.RemoveExtensionFromPath(path))
			end

			return
		end

		utility.PushTimeWarning()

		for _, info in pairs(tries) do
			local path = info.path:gsub("__MAPNAME__", name)

			if vfs.IsFile(path) then
				OBJ_WORLD = OBJ_WORLD or Entity.New({Name = "visual"})
				OBJ_WORLD:SetName(name)
				OBJ_WORLD:SetModelPath(path)
				OBJ_WORLD.world = OBJ_WORLD.world or Entity.New({Name = "world"})

				if info.callback then info.callback(OBJ_WORLD) end

				return
			end
		end

		steam.SetMap(name)
		utility.PopTimeWarning("map " .. name, nil, "cmd")
	end)

	function steam.GetInstallPath()
		local path

		if WINDOWS then
			path = system.GetRegistryValue("CurrentUser/Software/Valve/Steam/SteamPath") or
				(
					X64 and
					"C:\\Program Files (x86)\\Steam" or
					"C:\\Program Files\\Steam"
				)
		elseif OSX then
			path = os.getenv("HOME") .. "/Library/Application Support/Steam"
		else
			path = os.getenv("HOME") .. "/.steam/steam"

			if not vfs.IsDirectory(path) then
				path = os.getenv("HOME") .. "/.local/share/Steam"
			end

			if not vfs.IsDirectory(path) then
				path = os.getenv("HOME") .. "/.wine/drive_c/Program Files (x86)/Steam"
			end

			if not vfs.IsDirectory(path) then
				path = os.getenv("HOME") .. "/.var/app/com.valvesoftware.Steam/.local/share/Steam"
			end
		end

		return path --lfs.symlinkattributes(path, "mode") and path or nil
	end

	function steam.GetLibraryFolders()
		local base = steam.GetInstallPath()

		if steam.library_folders_cache and steam.library_folders_cache.base == base then
			return steam.library_folders_cache.folders
		end

		local tbl = {}
		local done = {}

		local function add_library(path)
			path = file_path.FixPathSlashes(path)

			if not path:ends_with("/steamapps") then path = path .. "/steamapps" end

			if not path:ends_with("/") then path = path .. "/" end

			if not done[path] then
				list.insert(tbl, path)
				done[path] = true
			end
		end

		add_library(base)

		do
			local str = vfs.Read(base .. "/steamapps/libraryfolders.vdf", "r")

			if str then
				local config = steam.VDFToTable(str, true)
				local folders = config and config.libraryfolders

				if folders then
					for _, info in pairs(folders) do
						if type(info) == "table" and info.path then add_library(info.path) end
					end
				end
			end
		end

		do
			local str = vfs.Read(base .. "/config/config.vdf", "r")

			if str then
				local config = steam.VDFToTable(str, true)
				local steam_config = config and
					config.installconfigstore and
					config.installconfigstore.software and
					config.installconfigstore.software.valve and
					config.installconfigstore.software.valve.steam

				if steam_config then
					for key, path in pairs(steam_config) do
						if key:find("baseinstallfolder_") then add_library(path) end
					end
				end
			end
		end

		steam.library_folders_cache = {base = base, folders = tbl}
		return tbl
	end

	function steam.GetGamePath(game)
		for _, dir in pairs(steam.GetLibraryFolders()) do
			local path = dir .. "common/" .. game .. "/"

			if vfs.IsDirectory(path) then return path end
		end

		return ""
	end

	function steam.GetGameFolders(skip_mods)
		local games = {}

		for _, library in ipairs(steam.GetLibraryFolders()) do
			for _, game in ipairs(vfs.Find(library .. "common/", true)) do
				list.insert(games, game .. "/")
			end

			if not skip_mods then
				for _, mod in ipairs(vfs.Find(library .. "sourcemods/", true)) do
					list.insert(games, mod .. "/")
				end
			end
		end

		return games
	end

	local function are_cached_library_folders_valid(cached_library_folders, current_libraries)
		local expected = {}
		local count = 0

		for _, path in ipairs(current_libraries) do
			expected[path] = (expected[path] or 0) + 1
			count = count + 1
		end

		local cached_count = 0

		for _, path in ipairs(cached_library_folders or {}) do
			if not expected[path] then return false end

			expected[path] = expected[path] - 1
			cached_count = cached_count + 1
		end

		if cached_count ~= count then return false end

		for _, remaining in pairs(expected) do
			if remaining ~= 0 then return false end
		end

		return true
	end

	function steam.GetGames()
		local function get_games_cache()
			local current_libraries = steam.GetLibraryFolders()

			if
				steam.games_cache and
				are_cached_library_folders_valid(steam.games_cache.library_folders, current_libraries)
			then
				return steam.games_cache.games, current_libraries
			end

			local cached = codec.ReadFile("msgpack", "cache/steam_games")

			if not cached then return nil, current_libraries end

			if
				cached.games and
				are_cached_library_folders_valid(cached.library_folders, current_libraries)
			then
				steam.games_cache = cached
				return cached.games, current_libraries
			end

			return nil, current_libraries
		end

		local found, current_libraries = get_games_cache()

		if found and found[1] then
			for _, game_info in ipairs(found) do
				if not game_info.game_dir or not vfs.IsDirectory(game_info.game_dir) then
					logn(
						"unable to find ",
						tostring(game_info.game_dir),
						", rebuilding steam.GetGames cache"
					)
					found = nil

					break
				end
			end

			if found then return found end
		end

		found = {}
		local done = {}

		local function add_game(game_info)
			local key = game_info.appid and
				(
					"appid:" .. tostring(game_info.appid)
				)
				or
				(
					"dir:" .. game_info.game_dir:lower()
				)

			if done[key] then return end

			done[key] = true
			list.insert(found, game_info)
		end

		for _, library in ipairs(current_libraries) do
			for _, manifest_name in ipairs(vfs.Find(library .. "appmanifest_.-%.acf$")) do
				local manifest_path = manifest_name

				if not file_path.IsPathAbsolutePath(manifest_path) then
					manifest_path = library .. manifest_path
				end

				local str = vfs.Read(manifest_path, "r")

				if not str then goto continue_manifest end

				local manifest = steam.VDFToTable(str, true)
				local appstate = manifest and manifest.appstate

				if not appstate or not appstate.installdir then goto continue_manifest end

				local appid = tonumber(appstate.appid) or appstate.appid
				local name = appstate.name or (appid and steam.appids[appid]) or appstate.installdir
				local game_dir = library .. "common/" .. appstate.installdir .. "/"

				if vfs.IsDirectory(game_dir) then
					add_game{
						appid = appid,
						name = name,
						game = name,
						installdir = appstate.installdir,
						game_dir = game_dir,
						library_dir = library,
						manifest_path = manifest_path,
					}
				end

				::continue_manifest::
			end

			for _, mod_dir in ipairs(vfs.Find(library .. "sourcemods/", true)) do
				local game_dir = mod_dir .. "/"
				local folder_name = game_dir:match("([^/]+)/$") or game_dir

				if vfs.IsDirectory(game_dir) then
					add_game{
						name = folder_name,
						game = folder_name,
						installdir = folder_name,
						game_dir = game_dir,
						library_dir = library,
						is_sourcemod = true,
					}
				end
			end
		end

		list.sort(found, function(a, b)
			return (a.name or a.game_dir) < (b.name or b.game_dir)
		end)

		codec.WriteFile(
			"msgpack",
			"cache/steam_games",
			{
				library_folders = current_libraries,
				games = found,
			}
		)
		steam.games_cache = {
			library_folders = current_libraries,
			games = found,
		}
		return found
	end

	function steam.GetSourceGames()
		local function sort_searchpaths(paths)
			local sorted = {}

			for _, path in ipairs(paths) do
				if path:ends_with(".vpk/") then list.insert(sorted, path) end
			end

			for _, path in ipairs(paths) do
				if not path:ends_with(".vpk/") then list.insert(sorted, path) end
			end

			return sorted
		end

		local function apply_gmod_mountdepots(game_info)
			if game_info.game ~= "Garry's Mod" or not game_info.vdf_directory then
				return false
			end

			local str = vfs.Read(game_info.vdf_directory .. "cfg/mountdepots.txt", "r")

			if not str then return false end

			local tbl = steam.VDFToTable(str, true)
			local depots = tbl and tbl.gamedepotsystem

			if not depots then return false end

			local paths = {}
			local done = {}
			local changed = false

			for _, path in ipairs(game_info.filesystem.searchpaths) do
				if not done[path] then
					list.insert(paths, path)
					done[path] = true
				end
			end

			local function add_path(path)
				path = file_path.FixPathSlashes(path)

				if path:ends_with(".vpk") then
					path = path:gsub("%.vpk$", "_dir.vpk") .. "/"
				elseif not path:ends_with("/") then
					path = path .. "/"
				end

				if not done[path] and vfs.IsDirectory(path) then
					list.insert(paths, path)
					done[path] = true
					changed = true
				end
			end

			for depot_name, enabled in pairs(depots) do
				if enabled ~= false and enabled ~= 0 and enabled ~= "0" then
					add_path(game_info.game_dir .. depot_name)
					add_path(game_info.game_dir .. "sourceengine/content_" .. depot_name .. ".vpk")
				end
			end

			if changed then game_info.filesystem.searchpaths = sort_searchpaths(paths) end

			return changed
		end

		local function get_source_games_cache()
			local current_libraries = steam.GetLibraryFolders()

			if
				steam.source_games_cache and
				are_cached_library_folders_valid(steam.source_games_cache.library_folders, current_libraries)
			then
				return steam.source_games_cache.games, current_libraries
			end

			local cached = codec.ReadFile("msgpack", "cache/source_games")

			if not cached then return nil, current_libraries end

			if
				cached.games and
				are_cached_library_folders_valid(cached.library_folders, current_libraries)
			then
				steam.source_games_cache = cached
				return cached.games, current_libraries
			end

			return nil, current_libraries
		end

		local found, current_libraries = get_source_games_cache()

		if found and found[1] then
			for i, v in ipairs(found) do
				if not vfs.IsFile(v.gameinfo_path) then
					logn("unable to find ", v.gameinfo_path, ", rebuilding steam.GetSourceGames cache")
					found = nil

					break
				end
			end

			if found then
				local changed = false

				for _, game_info in ipairs(found) do
					if apply_gmod_mountdepots(game_info) then changed = true end
				end

				if changed then
					codec.WriteFile(
						"msgpack",
						"cache/source_games",
						{
							library_folders = current_libraries,
							games = found,
						}
					)
				end

				return found
			end
		end

		found = {}
		local done = {}

		local function collect_gameinfos()
			local gameinfos = {}

			for _, game in ipairs(steam.GetGames()) do
				local game_dir = game.game_dir

				if vfs.IsDirectory("os:" .. game_dir .. "/game") then
					for _, dir in ipairs(vfs.Find("os:" .. game_dir .. "game/", true)) do
						if not dir:ends_with("/core") then
							dir = dir .. "/"
							local path = "os:" .. dir .. "gameinfo.gi"
							local str = vfs.Read(path)
							local game_info_dir = dir
							dir = file_path.GetParentFolderFromPath(dir)

							if str then
								local tbl = steam.VDFToTable(str, true)

								if tbl and tbl.gameinfo and tbl.gameinfo.game and tbl.gameinfo.filesystem then
									local core = steam.VDFToTable(vfs.Read("os:" .. game_dir .. "game/core/gameinfo.gi"), true)
									tbl = tbl.gameinfo
									tbl = table.merge(core.gameinfo, tbl)
									tbl.gameinfo_path = path
									tbl.game_dir = game_dir
									tbl.vdf_directory = game_info_dir
									tbl.appid = game.appid
									tbl.library_dir = game.library_dir
									tbl.manifest_path = game.manifest_path
									tbl.installdir = game.installdir
									list.insert(gameinfos, tbl)
								end
							end
						end
					end
				end

				for _, dir in ipairs(vfs.Find("os:" .. game_dir, true)) do
					dir = dir .. "/"
					local path = "os:" .. dir .. "gameinfo.txt"
					local str = vfs.Read(path)

					if not str then
						path = "os:" .. dir .. "GameInfo.txt"
						str = vfs.Read(path)
					end

					local game_info_dir = dir
					dir = file_path.GetParentFolderFromPath(dir)

					if str then
						local tbl = steam.VDFToTable(str, true)

						if tbl and tbl.gameinfo and tbl.gameinfo.game and tbl.gameinfo.filesystem then
							tbl = tbl.gameinfo
							tbl.gameinfo_path = path
							tbl.game_dir = game_dir
							tbl.vdf_directory = game_info_dir
							tbl.appid = game.appid
							tbl.library_dir = game.library_dir
							tbl.manifest_path = game.manifest_path
							tbl.installdir = game.installdir
							list.insert(gameinfos, tbl)
						end
					end
				end
			end

			return gameinfos
		end

		for _, tbl in ipairs(collect_gameinfos()) do
			if not tbl.filesystem.steamappid or not done[tbl.filesystem.steamappid] then
				if tbl.filesystem.steamappid then
					done[tbl.filesystem.steamappid] = true
				end

				local name = tbl.game

				if tbl.title and tbl.title ~= name then
					name = name .. " - " .. tbl.title
				end

				if tbl.title and tbl.title2 and tbl.title2 ~= tbl.title then
					name = name .. " - " .. tbl.title2
				end

				tbl.name = name
				local gameinfo = tbl

				if tbl.filesystem then
					local fixed = {}
					local done = {}

					for _, v in pairs(tbl.filesystem.searchpaths) do
						local vdf_directory = tbl.vdf_directory
						local tbl = type(v) == "string" and {v} or v

						for _, path in pairs(tbl) do
							-- First, resolve any path variables
							if path:find("|", nil, true) then
								path = path:replace("|gameinfo_path|", vdf_directory)
								path = path:replace("|all_source_engine_paths|", dir)
							end

							-- Make ALL relative paths absolute by prepending vdf_directory
							if not file_path.IsPathAbsolutePath(path) then
								path = gameinfo.game_dir .. path
							end

							path = file_path.FixPathSlashes(path)

							if path:ends_with("*") then
								if not done[path] then
									list.insert(fixed, path)
									done[path] = true
								end
							else
								if path:ends_with(".") then path = path:sub(0, -2) end

								if path:ends_with("/") then
									local test = path

									if vfs.IsDirectory(test) then
										if not done[test] then
											list.insert(fixed, test)
											done[test] = true
										end
									end
								else
									local test = path .. "/"

									if vfs.IsDirectory(test) then
										if not done[test] then
											list.insert(fixed, test)
											done[test] = true
										end
									end

									test = path .. "/pak01_dir.vpk/"

									if vfs.IsDirectory(test) then
										if not done[test] then
											list.insert(fixed, test)
											done[test] = true
										end
									end

									-- Only prepend game_dir if path is not already an absolute path
									if path:sub(1, 1) ~= "/" then
										test = gameinfo.game_dir .. path

										if not vfs.IsDirectory(path) and vfs.IsDirectory(test) then
											if not done[test] then
												list.insert(fixed, test)
												done[test] = true
											end
										end

										if test:ends_with(".vpk") and not vfs.IsFile("os:" .. test) then
											local vpk_path = test:gsub("%.vpk$", "_dir.vpk") .. "/"

											if not done[vpk_path] then
												list.insert(fixed, vpk_path)
												done[vpk_path] = true
											end
										end
									end
								end

								if path:ends_with(".vpk") and not vfs.IsFile("os:" .. path) then
									local vpk_path = path:gsub("%.vpk$", "_dir.vpk") .. "/"

									if not done[vpk_path] then
										list.insert(fixed, vpk_path)
										done[vpk_path] = true
									end
								end
							end
						end
					end

					tbl.filesystem.searchpaths = sort_searchpaths(fixed)
					apply_gmod_mountdepots(tbl)
					list.insert(found, tbl)
				end
			end
		end

		codec.WriteFile(
			"msgpack",
			"cache/source_games",
			{
				library_folders = current_libraries,
				games = found,
			}
		)
		steam.source_games_cache = {
			library_folders = current_libraries,
			games = found,
		}
		return found
	end

	do
		local cache_mounted = {}

		function steam.IsSourceGameMounted(var)
			local game_info, err = steam.FindSourceGame(var)

			if not game_info then return nil, err end

			if cache_mounted[game_info.filesystem.steamappid] then return true end

			return false
		end

		function steam.MountSourceGame(var, skip_addons)
			local game_info, err = steam.FindSourceGame(var)

			if not game_info then return nil, err end

			if cache_mounted[game_info.filesystem.steamappid] then
				llog("already mounted")
				return cache_mounted[game_info.filesystem.steamappid]
			end

			local function skip_gmod_extra_path(path)
				if game_info.game ~= "Garry's Mod" or not skip_addons then return false end

				local lower_path = path:lower()
				return lower_path:find("/garrysmod/addons/", nil, true) or
					lower_path:find("/garrysmod/download/", nil, true) or
					lower_path:find("/maps/workshop/", nil, true) or
					lower_path:find("/workshop/content/", nil, true)
			end

			steam.UnmountSourceGame(game_info)

			for _, path in ipairs(game_info.filesystem.searchpaths) do
				if skip_gmod_extra_path(path) then goto continue end

				if path:ends_with("*") then
					for _, path in ipairs(vfs.Find(path:sub(0, -2), true)) do
						if skip_gmod_extra_path(path) then goto continue_inner end

						if vfs.IsDirectory(path) then
							if
								game_info.game == "Garry's Mod" and
								not pvars.Get("gine_local_addons_only")
								and
								not skip_addons
							then
								llog("mounting %s", path)
								vfs.Mount(path, nil, game_info)
							else
								llog("%s is not a directory, deleting source game cache", path)
								vfs.Delete("cache/source_games")
							end
						end

						::continue_inner::
					end
				else
					if not path:ends_with(".vpk/") then
						for _, v in ipairs(vfs.Find(path .. "/maps/workshop/")) do
							if skip_gmod_extra_path(path .. "/maps/workshop/" .. v) then
								goto continue_workshop_map
							end

							llog("mounting workshop map %s", v)
							vfs.Mount(path .. "/maps/workshop/" .. v, "maps/", game_info)

							::continue_workshop_map::
						end
					end

					if vfs.IsDirectory(path) then
						llog("mounting %s", path)
						vfs.Mount(path, nil, game_info)
					else
						llog("%s is not a directory, deleting source game cache", path)
						vfs.Delete("cache/source_games")
					end
				end

				::continue::
			end

			if not (game_info.game == "Garry's Mod" and skip_addons) then
				for _, lib_folder in ipairs(steam.GetLibraryFolders()) do
					for _, path in ipairs(
						vfs.Find(lib_folder .. "workshop/content/" .. game_info.filesystem.steamappid .. "/", true)
					) do
						for _, file_name in ipairs(vfs.Find(path .. "/")) do
							vfs.Mount(path .. "/" .. file_name, nil, game_info)
						end
					end
				end
			end

			cache_mounted[game_info.filesystem.steamappid] = game_info
			return game_info
		end

		function steam.UnmountSourceGame(var)
			local game_info, err = steam.FindSourceGame(var)

			if not game_info then return nil, err end

			cache_mounted[game_info.filesystem.steamappid] = nil

			for _, v in pairs(vfs.GetMounts()) do
				if
					v.userdata and
					v.userdata.filesystem.steamappid == game_info.filesystem.steamappid
				then
					vfs.Unmount(v.full_where, v.full_to)
				end
			end

			return game_info
		end

		function steam.GetMountedSourceGames()
			return cache_mounted
		end

		function steam.GetMountedSourceGames2()
			local out = {}
			local done = {}

			for k, v in pairs(vfs.GetMounts()) do
				if v.userdata and v.userdata.filesystem and v.userdata.filesystem.steamappid then
					if not done[v.userdata] then
						list.insert(out, v.userdata)
						done[v.userdata] = true
					end
				end
			end

			return out
		end
	end

	function steam.FindSourceGame(var)
		local appid

		if type(var) == "number" then
			appid = var
		elseif type(var) == "table" then
			if var.filesystem and var.filesystem.steamappid then
				appid = var.filesystem.steamappid
			end
		else
			appid = steam.GetAppIdFromName(var)
		end

		if appid and tonumber(appid) then
			for _, game_info in ipairs(steam.GetSourceGames()) do
				if game_info.filesystem.steamappid == tonumber(appid) then
					return game_info
				end
			end
		end

		return nil, "could not find " .. tostring(var)
	end

	function steam.MountSourceGames()
		for _, game_info in ipairs(steam.GetSourceGames()) do
			steam.MountSourceGame(game_info)
		end
	end

	function steam.UnmountAllSourceGames()
		for _, game_info in ipairs(steam.GetSourceGames()) do
			steam.UnmountSourceGame(game_info)
		end
	end

	local mount_info = {
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
	}

	function steam.MountGamesFromMapPath(path)
		local name = path:match("maps/(.+)%.bsp")

		if name == "gm_old_flatgrass" then return end

		if name then
			local mounts = mount_info[name]

			if not mounts then
				for k, v in pairs(mount_info) do
					if name:find(k) then
						mounts = v

						break
					end
				end
			end

			if mounts then
				for _, mount in ipairs(mounts) do
					steam.MountSourceGame(mount)
				end
			end
		end
	end
end
