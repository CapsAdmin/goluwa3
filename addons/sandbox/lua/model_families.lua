local assets = import("goluwa/assets.lua")
local codec = import("goluwa/codec.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
local ffi = require("ffi")
local model_families = {}
local HULL_CACHE = "cache/model_hulls"
local HEADER_SIZE = 152
local HULL_OFFSET = 104
local VIEW_OFFSET = 128
local FRAME_BUDGET = 0.004
local NOTIFY_INTERVAL = 0.5
local SIZE_LIMITS = {
	{"Tiny", 6},
	{"Small", 24},
	{"Medium", 72},
	{"Large", 200},
	{"Huge", math.huge},
}
local EXCLUDED_PREFIXES = {
	"models/player/",
	"models/weapons/",
	"models/humans/",
	"models/characters/",
	"models/gibs/",
	"models/bots/",
	"models/workshop/",
	"models/workshop_partner/",
	"models/effects/",
	"models/editor/",
	"models/shadertest/",
	"models/hl1bugs/",
	"models/error",
	"models/v_",
	"models/c_",
	"models/zombie",
	"models/headcrab",
	"models/antlion",
	"models/vortigaunt",
	"models/alyx",
	"models/barney",
	"models/breen",
	"models/eli",
	"models/kleiner",
	"models/mossman",
	"models/monk",
	"models/odessa",
	"models/gman",
	"models/police",
	"models/manhack",
	"models/crow",
	"models/pigeon",
	"models/seagull",
	"models/combine_soldier",
	"models/combine_super_soldier",
	"models/combine_scanner",
	"models/combine_strider",
	"models/combine_helicopter",
}
local EXCLUDED_NAME_PATTERNS = {
	"_lod%d*$",
	"lod%d+$",
	"_phys[%a]*$",
	"_collide",
	"_reference$",
	"_ref$",
	"_anim[%a]*$",
	"_skeleton",
	"_dx%d+$",
	"gib%d*$",
	"_ragdoll$",
	"_template$",
	"_destruct",
	"_hands$",
	"chunk",
	"shard",
	"skybox",
	"damage",
	"broken",
	"debris",
}
local RULES = {
	{
		"Material",
		{
			{
				"Wood",
				{
					"wood",
					"plank",
					"pallet",
					"lumber",
					"crate",
				},
			},
			{
				"Metal",
				{
					"metal",
					"steel",
					"iron",
					"girder",
					"beam",
					"pipe",
					"canister",
					"gear",
					"chain",
					"grate",
					"sheetmetal",
				},
			},
			{
				"Concrete and Stone",
				{
					"concrete",
					"brick",
					"cinder",
					"cement",
					"stone",
					"rubble",
					"curb",
					"asphalt",
					"rock",
					"boulder",
				},
			},
			{"Plastic", {"plastic", "tarp", "bucket", "jug", "cone"}},
			{"Glass", {"glass", "window", "jar", "lightbulb"}},
			{
				"Fabric",
				{
					"cloth",
					"rug",
					"carpet",
					"curtain",
					"pillow",
					"sack",
					"tent",
					"cushion",
					"mattress",
				},
			},
		},
	},
	{
		"Theme",
		{
			{"Combine", {"combine", "citadel", "breen", "overwatch"}},
			{
				"Industrial",
				{
					"industrial",
					"factory",
					"trainyard",
					"silo",
					"refinery",
					"lathe",
					"crane",
					"forklift",
					"generator",
					"tank",
				},
			},
			{
				"Wasteland",
				{"wasteland", "junkyard", "junk", "rubbish", "trash", "dumpster", "garbage"},
			},
			{
				"Military",
				{
					"military",
					"ammo",
					"sandbag",
					"barricade",
					"bunker",
					"mortar",
					"missile",
					"cannon",
					"turret",
				},
			},
			{"Medical", {"medical", "medkit", "hospital", "gurney", "stretcher", "syringe"}},
			{"Office", {"office", "cardboard", "paper", "printer", "filing", "clipboard"}},
		},
	},
	{
		"Kind",
		{
			{
				"Furniture",
				{
					"chair",
					"couch",
					"sofa",
					"table",
					"desk",
					"bed",
					"shelf",
					"shelves",
					"cabinet",
					"dresser",
					"stool",
					"bench",
					"drawer",
					"wardrobe",
					"bookcase",
					"nightstand",
					"armchair",
				},
			},
			{
				"Appliances",
				{
					"fridge",
					"oven",
					"stove",
					"sink",
					"toilet",
					"bathtub",
					"washer",
					"microwave",
					"radiator",
					"faucet",
					"shower",
				},
			},
			{
				"Electronics",
				{
					"computer",
					"monitor",
					"television",
					"radio",
					"camera",
					"keyboard",
					"phone",
					"speaker",
					"terminal",
					"console",
					"battery",
					"generator",
					"antenna",
					"tv",
				},
			},
			{
				"Lighting",
				{"light", "lamp", "lantern", "floodlight", "streetlight", "spotlight", "bulb"},
			},
			{
				"Containers",
				{
					"crate",
					"box",
					"barrel",
					"drum",
					"dumpster",
					"locker",
					"chest",
					"trashcan",
					"bin",
					"basket",
					"suitcase",
					"crates",
					"oildrum",
					"container",
				},
			},
			{
				"Food and Drink",
				{
					"food",
					"melon",
					"pizza",
					"popcorn",
					"banana",
					"orange",
					"bottle",
					"milk",
					"cup",
					"mug",
					"cola",
					"beer",
					"pot",
					"pan",
					"cooking",
				},
			},
			{
				"Vehicles",
				{
					"car",
					"truck",
					"vehicle",
					"tire",
					"wheel",
					"trailer",
					"engine",
					"bus",
					"train",
					"boat",
					"airboat",
					"helicopter",
					"plane",
					"jeep",
					"bike",
					"tractor",
				},
			},
			{
				"Architecture",
				{
					"door",
					"stairs",
					"ladder",
					"fence",
					"gate",
					"railing",
					"pillar",
					"column",
					"wall",
					"floor",
					"roof",
					"ceiling",
					"doorway",
					"arch",
					"bridge",
					"scaffold",
					"tower",
				},
			},
			{
				"Nature",
				{
					"tree",
					"bush",
					"plant",
					"flower",
					"grass",
					"foliage",
					"palm",
					"leaf",
					"branch",
					"stump",
					"shrub",
					"vine",
				},
			},
			{
				"Tools and Junk",
				{
					"hammer",
					"wrench",
					"saw",
					"shovel",
					"axe",
					"ladder",
					"tool",
					"toolbox",
					"paint",
					"brush",
					"broom",
					"bucket",
					"cable",
					"rope",
					"wire",
					"tire",
					"cinder",
				},
			},
			{
				"Shapes",
				{
					"cube",
					"sphere",
					"cylinder",
					"cone",
					"pyramid",
					"tube",
					"plate",
					"panel",
					"hunter",
					"mechanics",
					"phx",
					"xqm",
					"squad",
					"cheeze",
					"sprops",
					"wedge",
					"ramp",
				},
			},
			{
				"Toys and Decor",
				{
					"toy",
					"doll",
					"teddy",
					"bear",
					"clock",
					"vase",
					"statue",
					"painting",
					"poster",
					"plushie",
					"trophy",
					"flag",
					"mirror",
					"pottery",
					"frame",
				},
			},
		},
	},
}
local SUBSTRING_WORDS = {glass = true, plank = true, crate = true, stone = true}
local state = {}
local listeners = {}
local hulls

do
	local function get_words(token)
		local words = {token}
		local stripped = token:gsub("%d+%a?$", "")

		if stripped ~= token and #stripped > 0 then words[2] = stripped end

		return words
	end

	local token_keys = {}

	function model_families.GetTokenKeys(token)
		local keys = token_keys[token]

		if keys then return keys end

		keys = {}
		local words = get_words(token)

		for group_index, group in ipairs(RULES) do
			for family_index, family in ipairs(group[2]) do
				for _, word in ipairs(family[2]) do
					local long = #word >= 6 or SUBSTRING_WORDS[word]
					local hit = false

					for _, candidate in ipairs(words) do
						if candidate == word or (long and candidate:find(word, 1, true)) then
							hit = true

							break
						end
					end

					if hit then
						keys[#keys + 1] = group_index * 100 + family_index

						break
					end
				end
			end
		end

		token_keys[token] = keys
		return keys
	end

	function model_families.IsUseful(entry)
		if entry.extension ~= ".mdl" then return false end

		local lower = entry.lower_path

		if lower:find("/gibs/", 1, true) then return false end

		for _, prefix in ipairs(EXCLUDED_PREFIXES) do
			if lower:starts_with(prefix) then return false end
		end

		local name = entry.name:lower()

		for _, pattern in ipairs(EXCLUDED_NAME_PATTERNS) do
			if name:find(pattern) then return false end
		end

		return true
	end
end

do
	local float_ptr = ffi.typeof("const float*")
	local char_ptr = ffi.typeof("const char*")
	local queue
	local queue_position
	local last_notify
	local dirty

	local function notify()
		for fn in pairs(listeners) do
			fn()
		end
	end

	local function extent(base, offset)
		local f = ffi.cast(float_ptr, base + offset)
		return math.max(f[3] - f[0], f[4] - f[1], f[5] - f[2])
	end

	local function read_extent(path)
		local file = vfs.Open(path)

		if not file then return 0 end

		local header = file:ReadBytes(HEADER_SIZE)
		file:Close()

		if not header or #header < HEADER_SIZE then return 0 end

		local base = ffi.cast(char_ptr, header)
		local size = extent(base, HULL_OFFSET)

		if size < 0.1 then size = extent(base, VIEW_OFFSET) end

		return math.floor(size + 0.5)
	end

	local function assign_size(entry, size)
		if size <= 0 then return end

		for _, limit in ipairs(SIZE_LIMITS) do
			if size < limit[2] then
				local node = state.size_nodes[limit[1]]
				node.Entries[#node.Entries + 1] = entry
				return
			end
		end
	end

	local function step()
		local now = system.GetTime()
		local started = now

		while queue_position <= #queue and system.GetTime() - started < FRAME_BUDGET do
			local entry = queue[queue_position]
			queue_position = queue_position + 1
			local size = hulls[entry.lower_path]

			if not size then
				size = read_extent(entry.path)
				hulls[entry.lower_path] = size
				dirty = true
			end

			assign_size(entry, size)
		end

		local finished = queue_position > #queue

		if finished then
			event.RemoveListener("Update", "model_families_hulls")

			if dirty then codec.WriteFile("msgpack", HULL_CACHE, hulls) end

			queue = nil
			state.pending = 0
		else
			state.pending = #queue - queue_position + 1
		end

		if finished or now - last_notify > NOTIFY_INTERVAL then
			last_notify = now
			notify()
		end
	end

	function model_families.Listen(fn)
		listeners[fn] = true
		return function()
			listeners[fn] = nil
		end
	end

	function model_families.GetPending()
		return state.pending ?? 0, state.total ?? 0
	end

	function model_families.StartSizes(eligible)
		hulls = hulls or codec.ReadFile("msgpack", HULL_CACHE) or {}
		queue = eligible
		queue_position = 1
		last_notify = 0
		dirty = false
		state.total = #eligible
		state.pending = #eligible
		event.AddListener("Update", "model_families_hulls", step)
	end
end

function model_families.Get()
	local index = assets.GetIndex("models")

	if state.index == index then return state.groups end

	if state.index then event.RemoveListener("Update", "model_families_hulls") end

	state.index = index
	local groups = {}
	local lookup = {}

	for group_index, group in ipairs(RULES) do
		local node = {Name = group[1], Icon = "folder", Children = {}}

		for family_index, family in ipairs(group[2]) do
			local child = {Name = family[1], Icon = "layers", Entries = {}, Children = {}}
			node.Children[family_index] = child
			lookup[group_index * 100 + family_index] = child
		end

		groups[group_index] = node
	end

	local size_group = {Name = "Size", Icon = "folder", Children = {}, Dynamic = true}
	state.size_nodes = {}

	for _, limit in ipairs(SIZE_LIMITS) do
		local node = {Name = limit[1], Icon = "layers", Entries = {}, Children = {}}
		size_group.Children[#size_group.Children + 1] = node
		state.size_nodes[limit[1]] = node
	end

	groups[#groups + 1] = size_group
	local eligible = {}
	local marks = {}

	for _, entry in ipairs(index.entries) do
		if model_families.IsUseful(entry) then
			eligible[#eligible + 1] = entry

			for token in entry.lower_path:sub(8):gmatch("[%a%d]+") do
				for _, key in ipairs(model_families.GetTokenKeys(token)) do
					if marks[key] ~= entry then
						marks[key] = entry
						local node_entries = lookup[key].Entries
						node_entries[#node_entries + 1] = entry
					end
				end
			end
		end
	end

	for _, group in ipairs(groups) do
		for i = #group.Children, 1, -1 do
			local child = group.Children[i]

			if #child.Entries == 0 and group.Name ~= "Size" then
				table.remove(group.Children, i)
			end
		end
	end

	state.groups = groups
	model_families.StartSizes(eligible)
	return groups
end

return model_families
