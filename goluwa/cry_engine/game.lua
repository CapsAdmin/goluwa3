local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local steam = import("goluwa/steam/steam.lua")
local game = {
	CRYSIS_APPID = 17300,
}
local mounts = {}
local mount_root
local cached_game

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

function game.FindCryGame()
	if cached_game then return cached_game end

	for _, candidate in ipairs(steam.GetGames()) do
		if candidate.appid == game.CRYSIS_APPID then
			cached_game = candidate
			return candidate
		end
	end

	return nil, "Crysis 1 not found"
end

function game.ListLevels()
	local cry_game = game.FindCryGame()
	local levels = {}

	if not cry_game then return levels end

	local root = cry_game.game_dir .. "Game/Levels/"

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

function game.ResolveLevelDirectory(level)
	if type(level) ~= "string" or level == "" then
		return nil, "missing Crysis level path"
	end

	local normalized = ensure_trailing_slash(level)

	if vfs.IsDirectory(normalized) then return normalized end

	if not file_path.IsPathAbsolutePath(normalized) then
		local cry_game, err = game.FindCryGame()

		if not cry_game then return nil, err end

		local candidate = ensure_trailing_slash(cry_game.game_dir .. "Game/Levels/" .. normalized)

		if vfs.IsDirectory(candidate) then return candidate end
	end

	return nil, "could not resolve Crysis level directory " .. tostring(level)
end

local function resolve_model_path_impl(level_dir, model_path)
	local normalized = file_path.FixPathSlashes(model_path)
	local candidates = {normalized}
	local cry_game = select(1, game.FindCryGame())
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
		candidates[#candidates + 1] = level_dir .. file_path.GetFileNameFromPath(level_dir:sub(1, -2)) .. ".cry/" .. normalized
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
	local cache_key = (level_dir or "") .. "\0" .. model_path
	local cached = resolved_model_path_cache[cache_key]

	if cached then return cached end

	local result = resolve_model_path_impl(level_dir, model_path)
	resolved_model_path_cache[cache_key] = result
	return result
end

function game.ResolveMaterialPath(level_dir, material_path)
	return game.ResolveModelPath(
		level_dir,
		file_path.FixPathSlashes(material_path):gsub("%.[mM][tT][lL]$", "") .. ".mtl"
	)
end

function game.EnsureLevelMounts(level_dir)
	local cry_game, err = game.FindCryGame()

	if not cry_game then error(err) end

	if mount_root == level_dir then return end

	mounts = clear_mounts(mounts)
	mount_root = level_dir

	local function mount(where, to)
		where = ensure_trailing_slash(where)

		if vfs.IsDirectory(where) then
			vfs.Mount(where, to or "")
			mounts[#mounts + 1] = {where = where, to = to or ""}
		end
	end

	mount(cry_game.game_dir .. "Game/Objects.pak/")
	mount(cry_game.game_dir .. "Game/Textures.pak/")
	mount(cry_game.game_dir .. "Game/GameData.pak/")
	mount(cry_game.game_dir .. "Game/Localized/english.pak/")
	mount(level_dir .. "level.pak/")
	mount(level_dir .. "terraintexture.pak/")
	mount(level_dir .. (level_dir:match("/([^/]+)/$") or "") .. ".cry/")
end

return game
