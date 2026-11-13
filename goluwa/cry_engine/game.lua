local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local steam = import("goluwa/steam/steam.lua")
local event = import("goluwa/event.lua")
local game = {
	CRYSIS_APPID = 17300,
}
local GAMES = {
	{
		appid = 17300,
		key = "crysis",
		paks = {"ZPatch1", "Objects", "Textures", "GameData", "Localized/english"},
	},
	{
		appid = 17340,
		key = "wars",
		paks = {"ZPatch1", "Objects", "Textures", "GameData", "Localized/english"},
	},
	{
		appid = 17330,
		key = "warhead",
		plain_terrain_color = true,
		paks = {
			"VPatch1",
			"Objects",
			"Textures",
			"GameData",
			"Warhead_Objects",
			"Warhead_Textures",
			"Warhead_GameData",
			"Localized/english",
		},
	},
}
local mounts = {}
local content_mounts = {}
local mounted_appid
local enabled = {}
local mount_root
local installed
local current_game

local function clear_mounts(mounts)
	for _, mount in ipairs(mounts or {}) do
		vfs.Unmount(mount.where, mount.to)
	end

	return {}
end

local function ensure_trailing_slash(path)
	path = file_path.FixPathSlashes(path or "")

	if path ~= "" and not path:ends_with("/") then path = path .. "/" end

	return path
end

function game.GetInstalledGames()
	if installed then return installed end

	installed = {}
	local by_appid = {}

	for _, candidate in ipairs(steam.GetGames()) do
		by_appid[candidate.appid] = candidate
	end

	for _, info in ipairs(GAMES) do
		local steam_game = by_appid[info.appid]

		if steam_game then
			installed[#installed + 1] = {
				appid = info.appid,
				key = info.key,
				name = steam_game.name,
				game_dir = steam_game.game_dir,
				paks = info.paks,
				plain_terrain_color = info.plain_terrain_color,
			}
		end
	end

	return installed
end

function game.GetGame(appid)
	for _, info in ipairs(game.GetInstalledGames()) do
		if info.appid == appid then return info end
	end

	return nil, "Crysis game " .. tostring(appid) .. " not found"
end

function game.GetGameForLevel(level_dir)
	for _, info in ipairs(game.GetInstalledGames()) do
		if level_dir:starts_with(info.game_dir) then return info end
	end
end

function game.FindCryGame()
	if current_game then return current_game end

	local first = game.GetInstalledGames()[1]

	if first then return first end

	return nil, "Crysis not found"
end

function game.ListLevels(info)
	local levels = {}
	local root = info.game_dir .. "Game/Levels/"

	local function scan(relative)
		local entries = vfs.Find(root .. relative)

		for _, entry in ipairs(entries) do
			if entry == "level.pak" then levels[#levels + 1] = relative:sub(1, -2) end
		end

		for _, entry in ipairs(entries) do
			if vfs.IsDirectory(root .. relative .. entry) then
				scan(relative .. entry .. "/")
			end
		end
	end

	scan("")
	return levels
end

function game.GetLevelThumbnail(level)
	local level_dir = game.ResolveLevelDirectory(level)

	if not level_dir then return end

	local loading

	for _, entry in ipairs(vfs.Find(level_dir)) do
		local lower = entry:lower()

		if lower == "levelstart.bmp" then return level_dir .. entry end

		if lower:ends_with("loading.dds") then loading = level_dir .. entry end
	end

	return loading
end

function game.ResolveLevelDirectory(level)
	if type(level) ~= "string" or level == "" then
		return nil, "missing Crysis level path"
	end

	local key, rest = level:match("^(%a+):(.+)$")
	local normalized = ensure_trailing_slash(rest or level)

	if vfs.IsDirectory(normalized) then return normalized end

	if not file_path.IsPathAbsolutePath(normalized) then
		for _, info in ipairs(game.GetInstalledGames()) do
			if not key or info.key == key then
				local candidate = ensure_trailing_slash(info.game_dir .. "Game/Levels/" .. normalized)

				if vfs.IsDirectory(candidate) then return candidate end
			end
		end
	end

	return nil, "could not resolve Crysis level directory " .. tostring(level)
end

do
	local cache = {}

	function game.GetEditorDirectory(level_dir)
		local cached = cache[level_dir]

		if cached then return cached end

		for _, entry in ipairs(vfs.Find(level_dir)) do
			if entry:lower():ends_with(".cry") then
				cache[level_dir] = level_dir .. entry .. "/"
				return cache[level_dir]
			end
		end

		return level_dir .. (level_dir:match("/([^/]+)/$") or "") .. ".cry/"
	end
end

local function resolve_model_path_impl(level_dir, model_path, cry_game)
	local normalized = file_path.FixPathSlashes(model_path)
	local candidates = {normalized}
	local root, rest = normalized:match("^([^/]+)/(.+)$")
	local root_lower = root and root:lower() or nil
	local mounted_root = root_lower == "objects" and
		"Objects" or
		root_lower == "materials" and
		"Materials" or
		root_lower == "textures" and
		"Textures" or
		nil

	if mounted_root and rest then
		local mounted = vfs.FindMixedCasePath(mounted_root .. "/" .. rest)

		if mounted then return mounted end
	end

	if level_dir then
		candidates[#candidates + 1] = level_dir .. "level.pak/" .. normalized
		candidates[#candidates + 1] = level_dir .. "terraintexture.pak/" .. normalized
		candidates[#candidates + 1] = game.GetEditorDirectory(level_dir) .. normalized
	end

	if cry_game and cry_game.game_dir then
		candidates[#candidates + 1] = cry_game.game_dir .. "Game/" .. normalized
		candidates[#candidates + 1] = cry_game.game_dir .. "Game/GameData.pak/" .. normalized
		candidates[#candidates + 1] = cry_game.game_dir .. "Game/Objects.pak/" .. normalized
		candidates[#candidates + 1] = cry_game.game_dir .. "Game/Textures.pak/" .. normalized
	end

	for _, candidate in ipairs(candidates) do
		local found = vfs.FindMixedCasePath(candidate)

		if found and vfs.IsFile(found) then return found end

		if vfs.IsFile(candidate) then return candidate end
	end

	return normalized
end

local resolved_model_path_cache = {}

function game.ResolveModelPath(level_dir, model_path)
	local cry_game = level_dir and game.GetGameForLevel(level_dir) or game.FindCryGame()
	local cache_key = (
			cry_game and
			cry_game.appid or
			0
		) .. "\0" .. (
			level_dir or
			""
		) .. "\0" .. model_path
	local cached = resolved_model_path_cache[cache_key]

	if cached then return cached end

	local result = resolve_model_path_impl(level_dir, model_path, cry_game)
	resolved_model_path_cache[cache_key] = result
	return result
end

function game.ResolveMaterialPath(level_dir, material_path)
	return game.ResolveModelPath(
		level_dir,
		file_path.FixPathSlashes(material_path):gsub("%.[mM][tT][lL]$", "") .. ".mtl"
	)
end

local function mount_directory(list, where, game_info)
	where = ensure_trailing_slash(where)

	if vfs.IsDirectory(where) then
		vfs.Mount(where, "", game_info)
		list[#list + 1] = {where = where, to = ""}
	end
end

local function unmount_content()
	content_mounts = clear_mounts(content_mounts)
	mounts = clear_mounts(mounts)
	mount_root = nil
	mounted_appid = nil
end

local function mount_content(appid)
	if mounted_appid == appid then return end

	unmount_content()
	local info = assert(game.GetGame(appid))
	local game_info = {game = info.name}

	for _, pak in ipairs(info.paks) do
		local path = vfs.FindMixedCasePath(info.game_dir .. "Game/" .. pak .. ".pak")

		if path then mount_directory(content_mounts, path, game_info) end
	end

	mounted_appid = appid
	current_game = info
	event.Call("SourceGameMounted", game_info)
end

function game.IsMounted(appid)
	if appid then return enabled[appid] == true end

	return next(enabled) ~= nil
end

function game.MountContent(appid)
	enabled[appid] = true
	mount_content(appid)
end

function game.UnmountContent(appid)
	enabled[appid] = nil

	if appid ~= mounted_appid then return end

	unmount_content()

	for _, info in ipairs(game.GetInstalledGames()) do
		if enabled[info.appid] then
			mount_content(info.appid)

			break
		end
	end
end

function game.EnsureLevelMounts(level_dir)
	local info = assert(game.GetGameForLevel(level_dir), "level is not inside an installed Crysis game")
	enabled[info.appid] = true
	mount_content(info.appid)

	if mount_root == level_dir then return end

	mounts = clear_mounts(mounts)
	mount_root = level_dir
	local game_info = {game = info.name}
	mount_directory(mounts, level_dir .. "level.pak/", game_info)
	mount_directory(mounts, level_dir .. "terraintexture.pak/", game_info)
	mount_directory(mounts, game.GetEditorDirectory(level_dir), game_info)
end

return game
