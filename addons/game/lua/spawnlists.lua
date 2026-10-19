local vfs = import("goluwa/vfs.lua")
local steam = import("goluwa/steam/steam.lua")
local spawnlists = {}
local DEFAULT_DIRECTORY = "settings/spawnlist_default/"
local USER_DIRECTORY = "settings/spawnlist/"

-- the .txt files of the first mounted folder that has any, a game mounted later or a second copy of the folder is ignored like gmod does
local function find_files(directory)
	local files = {}
	local mount_directory

	for _, full_path in ipairs(vfs.Find(directory, true)) do
		if full_path:ends_with(".txt") then
			local this_directory = full_path:match("^(.*/)")
			mount_directory = mount_directory ?? this_directory

			if this_directory == mount_directory then files[#files + 1] = full_path end
		end
	end

	table.sort(files)
	return files
end

-- "models/props_c17/chair01a.mdl" as a browser entry, the entries of a list are made once so their previews are kept
local function make_entry(path)
	return {
		category = "models",
		path = path,
		lower_path = path:lower(),
		name = path:match("([^/]+)%.%w+$"),
		extension = ".mdl",
	}
end

-- gmod's spawnlists (settings/spawnlist_default, or the user's own once they were saved) as a tree of {Name, Icon, Entries, Children}, in the order of the files. Empty when no game with spawnlists is mounted. Headers inside a list are dropped, a grid has no rows
function spawnlists.Load()
	local files = find_files(USER_DIRECTORY)

	if #files == 0 then files = find_files(DEFAULT_DIRECTORY) end

	local nodes = {}
	local by_id = {}

	for _, file in ipairs(files) do
		local _, info = next(steam.VDFToTable(vfs.Read(file), true))
		local indices = {}

		for index in pairs(info.contents or {}) do
			indices[#indices + 1] = tonumber(index)
		end

		table.sort(indices)
		local node = {
			Name = info.name or file:match("([^/]+)%.txt$"),
			Icon = info.icon,
			Parent = info.parentid,
			Entries = {},
			Children = {},
		}

		for _, index in ipairs(indices) do
			local content = info.contents[tostring(index)]

			if content.type == "model" then
				node.Entries[#node.Entries + 1] = make_entry(content.model)
			end
		end

		nodes[#nodes + 1] = node
		by_id[info.id] = node
	end

	local roots = {}

	for _, node in ipairs(nodes) do
		local parent = by_id[node.Parent]

		if parent and parent ~= node then
			parent.Children[#parent.Children + 1] = node
		else
			roots[#roots + 1] = node
		end
	end

	return roots
end

-- every model of the lists once, for the search
function spawnlists.GetEntries(roots)
	local entries = {}
	local seen = {}

	local function add(nodes)
		for _, node in ipairs(nodes) do
			for _, entry in ipairs(node.Entries) do
				if not seen[entry.lower_path] then
					seen[entry.lower_path] = true
					entries[#entries + 1] = entry
				end
			end

			add(node.Children)
		end
	end

	add(roots)
	return entries
end

return spawnlists
