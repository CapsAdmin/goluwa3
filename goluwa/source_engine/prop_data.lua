local vdf = import("goluwa/codecs/vdf.lua")
local vfs = import("goluwa/vfs.lua")
local surface_properties = import("goluwa/source_engine/surface_properties.lua")
local prop_data = {}
local entries
local chunks
local cache = {}
local script_cache = {}
local DEFAULT_COUNT = 3

local function lower_keys(tbl)
	local out = {}

	for key, value in pairs(tbl) do
		out[type(key) == "string" and key:lower() or key] = type(value) == "table" and lower_keys(value) or value
	end

	return out
end

local function load_entries()
	local root = vdf.Decode(vfs.Read("scripts/propdata.txt"))
	root = lower_keys(select(2, next(root)))
	chunks = {}

	for name, models in pairs(root.breakablemodels) do
		chunks[name] = {}

		for path in pairs(models) do
			table.insert(chunks[name], (path:gsub("\\", "/")))
		end

		table.sort(chunks[name])
	end

	root.breakablemodels = nil
	entries = root
end

local function resolve(base, overrides)
	local chain = {overrides}
	local current = base and entries[base:lower()]

	while current do
		table.insert(chain, 1, current)
		current = current.base and entries[current.base:lower()]
		assert(#chain < 32, "prop data base loop for " .. base)
	end

	local out = {}

	for _, entry in ipairs(chain) do
		for key, value in pairs(entry) do
			out[key] = value
		end
	end

	return out
end

local function read_sounds(name)
	local key = name:lower()

	if script_cache[key] ~= nil then return script_cache[key] end

	local manifest = vfs.Read("scripts/game_sounds_manifest.txt")
	local found = false

	for path in manifest:gmatch("\"precache_file\"%s*\"([^\"]+)\"") do
		local text = vfs.IsFile(path) and vfs.Read(path)
		local start = text and text:lower():find("\"" .. key .. "\"%s*{")

		if start then
			local block = text:match("%b{}", start)
			local volume = tonumber(block:match("\"volume\"%s*\"([^\",]+)")) or 1
			local low, high = block:match("\"pitch\"%s*\"(%d+),(%d+)\"")
			local waves = {}

			for wave in block:gmatch("\"wave\"%s*\"([^\"]+)\"") do
				table.insert(waves, (wave:gsub("^[%*%^%)<>%?#@%(%$]+", "")))
			end

			found = {
				Waves = waves,
				Volume = volume,
				Pitch = {(low or 100) / 100, (high or 100) / 100},
			}

			break
		end
	end

	script_cache[key] = found
	return found
end

function prop_data.GetSounds(name)
	return read_sounds(name)
end

function prop_data.Get(model_path)
	local key = model_path:lower()

	if cache[key] ~= nil then return cache[key] or nil end

	if not entries then load_entries() end

	cache[key] = false
	local mdl = vfs.Read(model_path)
	local block = mdl and mdl:match("prop_data%s*(%b{})")

	if not block then return nil end

	local overrides = {}

	for name, value in block:gmatch("\"([^\"]+)\"%s*\"([^\"]*)\"") do
		overrides[name:lower()] = value
	end

	local resolved = resolve(overrides.base, overrides)
	local health = tonumber(resolved.health)

	if not health or health <= 0 then return nil end

	local phy = vfs.Read((model_path:gsub("%.mdl$", ".phy"))) or ""
	local gibs = {}

	for gib in phy:gmatch("break%s*{%s*\"model\"%s*\"([^\"]+)\"") do
		table.insert(gibs, "models/" .. gib:gsub("\\", "/") .. ".mdl")
	end

	local chunk_models = chunks[(resolved.breakable_model or ""):lower()]
	local surface = phy:match("\"surfaceprop\"%s*\"([^\"]*)\"")
	local sound = surface and surface_properties.Get(surface)["break"]
	cache[key] = {
		Health = health,
		Gibs = gibs,
		Chunks = #gibs == 0 and chunk_models or nil,
		ChunkCount = tonumber(resolved.breakable_count) or DEFAULT_COUNT,
		Sounds = sound and read_sounds(sound) or nil,
	}
	return cache[key]
end

return prop_data
