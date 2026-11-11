local assets = import("goluwa/assets.lua")
local model_families = import("lua/model_families.lua")
local spawnlists = import("lua/spawnlists.lua")
local model_catalog = {}
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

		for segment in entry.dir_path:gmatch("([^/]+)/") do
			if segment ~= "models" or node ~= game then
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
