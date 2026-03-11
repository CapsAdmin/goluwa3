local chatsounds = require("chatsounds.chatsounds")
local resource = require("resource")
local crypto = require("crypto")
local codec = require("codec")
local callback = require("callback")
local tasks = require("tasks")
local vfs = require("vfs")

local function read_list(base_url, sounds, list_id, skip_list)
	local tree = {}
	local list = {}
	local count = 0

	for i = 1, #sounds do
		local realm = sounds[i][1]
		local trigger = sounds[i][2]
		local path = sounds[i][3]
		local trigger_url = sounds[i][4]

		if trigger_url then
			count = count + 1
		else
			tree[realm] = tree[realm] or {}
			list[realm] = list[realm] or {}
			tree[realm][trigger] = tree[realm][trigger] or {}
			_G.list.insert(tree[realm][trigger], {
				path = path,
				base_path = base_url,
			})
			list[realm][trigger] = path
		end
	end

	tree = chatsounds.TableToTree(tree, list_id)

	if list_id then
		chatsounds.custom = chatsounds.custom or {}
		chatsounds.custom[list_id] = {
			tree = tree,
			list = list,
		}
	else
		chatsounds.tree = chatsounds.tree or {}
		table.merge(chatsounds.tree, tree)
		chatsounds.list = chatsounds.list or {}
		table.merge(chatsounds.list, list, true)
	end

	chatsounds.GenerateAutocomplete()

	if list_id then
		llog("loaded " .. #sounds .. " unique sounds from ", base_url)
	end
end

function chatsounds.BuildFromGithub(repo, location, list_id)
	return callback.WrapTask(function(self, repo, location, list_id)
		location = location or "sounds/chatsounds"
		local base_url = "https://raw.githubusercontent.com/" .. repo .. "/master/" .. location .. "/"
		local resolve = self.callbacks.resolve
		local reject = self.callbacks.reject

		tasks.CreateTask(
			function()
				local ok, path = pcall(function()
					return resource.Download(base_url .. "list.msgpack", nil, nil, true, "msgpack"):Get()
				end)

				if ok then
					llog("found list.msgpack for ", location)
					local val = codec.ReadFile("msgpack", path)
					read_list(base_url, val, list_id)
					resolve(path)
					return
				end

				if list_id then
					llog(repo, ": unable to find list.msgpack from \"", location, "\"")
					llog(repo, ": parsing with github api instead (slower)")
				end

				local url = "https://api.github.com/repos/" .. repo .. "/git/trees/HEAD?recursive=1"
				local ok, path, etag_updated = pcall(function()
					return resource.Download(url, nil, nil, true):Get()
				end)

				if not ok then
					reject(path)
					return
				end

				local cached_path = "cache/" .. crypto.CRC32(url .. location) .. ".chatsounds_tree"
				print("cached path: " .. cached_path) --- IGNORE ---
				local sounds = codec.ReadFile("msgpack", cached_path)

				if not etag_updated and sounds then
					if sounds[1] and #sounds[1] >= 3 then
						read_list(base_url, sounds, list_id)
						resolve(path, etag_updated)
						return
					else
						llog("found cached list but format doesn't look right, regenerating.")
					end
				end

				llog("change detected ", base_url)
				local sounds = {}
				local str = assert(io.open(path, "rb"):read("*all"))
				local i = 1

				for path in str:gmatch("\"path\":%s?\"(.-)\"[\n,}]") do
					if path:starts_with(location) and path:ends_with(".ogg") then
						path = path:sub(#location + 2) -- start character after location, and another /
						local tbl = path:split("/")
						local realm = tbl[1]
						local trigger = tbl[2]

						if not tbl[3] then trigger = trigger:sub(1, -#".ogg" - 1) end

						sounds[i] = {
							realm,
							trigger,
							path,
						}

						if trigger:starts_with("-") then
							sounds[i][2] = sounds[i][2]:sub(2)
							sounds[i][4] = realm .. "/" .. trigger .. ".txt"
						end

						i = i + 1
					end
				end

				codec.WriteFile("msgpack", cached_path, sounds)
				read_list(base_url, sounds, list_id)
				resolve(path, etag_updated)
			end,
			nil,
			true,
			function(_, err)
				reject(err)
			end
		)
	end)(repo, location, list_id)
end

local autocomplete = require("autocomplete")

function chatsounds.LoadRepositories()
	local default_lists = {
		"PAC3-Server/chatsounds-valve-games/csgo",
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
		"PAC3-Server/chatsounds",
	}
	local jobs = {}

	for i, sub in ipairs(default_lists) do
		local location, directory = sub:match("^(.-/.-)/(.*)$")
		location = location or sub
		directory = directory or ""

		if location then
			local friendly = location .. "/" .. directory
			autocomplete.translate_list_id["chatsounds_custom_" .. sub] = friendly

			if directory == "" then directory = nil end

			table.insert(jobs, chatsounds.BuildFromGithub(location, directory, sub))
		end
	end

	return callback.All(jobs)
end
