local chatsounds = require("chatsounds.chatsounds")
local autocomplete = require("autocomplete")
local default_lists = {
	"PAC3-Server/chatsounds-valve-games/csgo",
--[[
	"PAC3-Server/chatsounds-valve-games/css",
	"PAC3-Server/chatsounds-valve-games/ep1",
	"PAC3-Server/chatsounds-valve-games/ep2",
	"PAC3-Server/chatsounds-valve-games/hl1",
	"PAC3-Server/chatsounds-valve-games/hl2",
	"PAC3-Server/chatsounds-valve-games/l4d",
	"PAC3-Server/chatsounds-valve-games/l4d2",
	"PAC3-Server/chatsounds-valve-games/portal",
	"PAC3-Server/chatsounds-valve-games/tf2",
	"Metastruct/garrysmod-chatsounds/sound/chatsounds/autoadd",
	"PAC3-Server/chatsounds",]]
}

for _, sub in ipairs(default_lists) do
	local location, directory = sub:match("^(.-/.-)/(.*)$")
	location = location or sub
	directory = directory or ""

	if location then
		local friendly = location .. "/" .. directory
		autocomplete.translate_list_id["chatsounds_custom_" .. sub] = friendly
		local directory = directory

		if directory == "" then directory = nil end

		chatsounds.BuildFromGithub(location, directory, sub)
	end
end