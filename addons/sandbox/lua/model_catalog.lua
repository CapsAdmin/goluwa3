local assets = import("goluwa/assets.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
local model_families = import("lua/model_families.lua")
local spawnlists = import("lua/spawnlists.lua")
local model_catalog = {}
local MOUNT_SETTLE_TIME = 0.5

do
	local listeners = {}
	local seen = vfs.mount_generation
	local changed_at

	event.AddListener("Update", "model_catalog_mounts", function()
		if vfs.mount_generation ~= seen then
			seen = vfs.mount_generation
			changed_at = system.GetUnscaledElapsedTime()
		end

		if changed_at and system.GetUnscaledElapsedTime() - changed_at >= MOUNT_SETTLE_TIME then
			changed_at = nil

			for fn in pairs(listeners) do
				fn(seen)
			end
		end
	end)

	function model_catalog.ListenMounts(fn)
		listeners[fn] = true
		return function()
			listeners[fn] = nil
		end
	end
end

function model_catalog.Collect(node)
	if node.All then return node.All end

	if #node.Children == 0 then return node.Entries end

	local all = {}
	local seen = {}

	local function add(current)
		for _, entry in ipairs(current.Entries ?? {}) do
			if not seen[entry] then
				seen[entry] = true
				all[#all + 1] = entry
			end
		end

		for _, child in ipairs(current.Children) do
			add(child)
		end
	end

	add(node)

	if not node.Dynamic then node.All = all end

	return all
end

local function sort_children(node)
	table.sort(node.Children, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)

	for _, child in ipairs(node.Children) do
		sort_children(child)
	end
end

local function build_games(entries)
	local games = {}
	local order = {}

	for _, entry in ipairs(entries) do
		local game_name = entry.game ?? "Other"
		local game = games[game_name]

		if not game then
			game = {Name = game_name, Icon = "folder", Entries = {}, Children = {}, by_name = {}}
			games[game_name] = game
			order[#order + 1] = game
		end

		local node = game
		local first = true

		for segment in entry.dir_path:gmatch("([^/]+)/") do
			if first then
				first = false
			else
				local child = node.by_name[segment]

				if not child then
					child = {Name = segment, Icon = "folder", Entries = {}, Children = {}, by_name = {}}
					node.by_name[segment] = child
					node.Children[#node.Children + 1] = child
				end

				node = child
			end
		end

		node.Entries[#node.Entries + 1] = entry
	end

	local by_game = {Name = "By Game", Icon = "folder", Entries = {}, Children = order}
	sort_children(by_game)
	return by_game
end

function model_catalog.Build()
	local index = assets.GetIndex("models")
	local entries = {}

	for _, entry in ipairs(index.entries) do
		if entry.extension ~= ".bsp" then entries[#entries + 1] = entry end
	end

	local lists = spawnlists.Load()
	local roots = {
		{Name = "All Models", Icon = "layers", Entries = entries, Children = {}},
		{
			Name = "Families",
			Icon = "folder",
			Entries = {},
			Children = model_families.Get(),
			Dynamic = true,
		},
		build_games(entries),
	}

	if #lists > 0 then
		roots[#roots + 1] = {Name = "Garry's Mod Lists", Icon = "folder", Entries = {}, Children = lists}
	end

	return roots, entries
end

return model_catalog
