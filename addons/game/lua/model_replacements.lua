local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local cry_game = import("goluwa/cry_engine/game.lua")
local model_replacements = {}
local entries = {}

function model_replacements.Register(key, entry)
	entries[key] = entry
end

function model_replacements.Get(key)
	local entry = entries[key]

	if
		entry and
		(
			entry.Game == "crysis" and
			cry_game.IsMounted() or
			steam.IsSourceGameMounted(entry.Game) == true
		)
		and
		vfs.IsFile(entry.Path)
	then
		return entry
	end
end

return model_replacements
