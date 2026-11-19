local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local cry_game = import("lua/crysis_loader/game.lua")
local model_replacements = {}
local entries = {}

function model_replacements.Register(key, entry)
	entries[key] = entry
end

local function is_mounted(game)
	if type(game) == "table" then
		for _, candidate in ipairs(game) do
			if is_mounted(candidate) then return true end
		end

		return false
	end

	if game == "crysis" then return cry_game.IsMounted() end

	return steam.IsSourceGameMounted(game) == true
end

function model_replacements.Get(key)
	local entry = entries[key]

	if entry and is_mounted(entry.Game) and vfs.IsFile(entry.Path) then
		return entry
	end
end

return model_replacements
