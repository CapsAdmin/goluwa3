local assets = library()
local file_path = import("goluwa/filesystem/path.lua")
local vfs = import("goluwa/vfs.lua")
assets.categories = assets.categories or {}
assets.cache = assets.cache or {}
assets.virtual_assets = assets.virtual_assets or {}
assets.indexes = assets.indexes or {}

local function normalize_path(path)
	assert(type(path) == "string", "asset path must be a string")
	assert(path ~= "", "asset path cannot be empty")
	path = path:gsub("\\", "/")
	path = path:gsub("^%./", "")
	path = path:gsub("//+", "/")
	return path
end

local function add_candidate(out, seen, candidate)
	if type(candidate) ~= "string" or candidate == "" then return end

	candidate = normalize_path(candidate)
	local key = candidate:lower()

	if seen[key] then return end

	seen[key] = true
	list.insert(out, candidate)
end

local function get_extension(path)
	local ext = path:match("(%.[^./]+)$")

	if ext then return ext:lower() end

	return nil
end

local function has_extension(path)
	return get_extension(path) ~= nil
end

local function get_file_stem(path)
	local name = file_path.GetFileNameFromPath(path)
	return (name:gsub("%.[^./]+$", ""))
end

local function starts_with_any_root(path, roots)
	local lower = path:lower()

	for _, root in ipairs(roots) do
		if lower:starts_with(root:lower()) then return root end
	end

	return nil
end

local function sort_config_keys(a, b)
	local a_type = type(a)
	local b_type = type(b)

	if a_type ~= b_type then return a_type < b_type end

	return tostring(a) < tostring(b)
end

local function serialize_config_value(value, seen)
	local value_type = type(value)

	if value_type == "nil" then return "nil" end

	if value_type == "boolean" or value_type == "number" then
		return value_type .. ":" .. tostring(value)
	end

	if value_type == "string" then return "string:" .. value end

	if value_type == "table" then
		assert(not seen[value], "asset config cannot contain cycles")
		seen[value] = true
		local keys = {}

		for key in pairs(value) do
			keys[#keys + 1] = key
		end

		table.sort(keys, sort_config_keys)
		local parts = {}

		for i, key in ipairs(keys) do
			parts[i] = "[" .. serialize_config_value(key, seen) .. "]=" .. serialize_config_value(value[key], seen)
		end

		seen[value] = nil
		return "table:{" .. table.concat(parts, ",") .. "}"
	end

	return value_type .. ":" .. tostring(value)
end

local function get_request_config(options)
	return options and options.config or nil
end

local function build_config_cache_suffix(options)
	local config = get_request_config(options)

	if config == nil then return "nil" end

	return serialize_config_value(config, {})
end

local function default_cache_key(path, options)
	return path .. "|config=" .. build_config_cache_suffix(options)
end

local function make_model_entry(path, cache_key)
	return {
		category = "models",
		path = path,
		cache_key = cache_key,
		is_ready = false,
		is_loading = true,
		entries = {},
		value = nil,
		error = nil,
		pending_ready = {},
		pending_error = {},
	}
end

local function queue_callbacks(entry, options)
	if not options then return end

	if options.on_ready then
		entry.pending_ready = entry.pending_ready or {}
		list.insert(entry.pending_ready, options.on_ready)
	end

	if options.on_error then
		entry.pending_error = entry.pending_error or {}
		list.insert(entry.pending_error, options.on_error)
	end
end

local function flush_ready(entry, value)
	if not entry.pending_ready then return end

	for _, callback in ipairs(entry.pending_ready) do
		callback(value)
	end

	entry.pending_ready = {}
	entry.pending_error = {}
end

local function flush_error(entry, reason)
	if not entry.pending_error then return end

	for _, callback in ipairs(entry.pending_error) do
		callback(reason)
	end

	entry.pending_ready = {}
	entry.pending_error = {}
end

local function build_candidates(category, path)
	path = normalize_path(path)
	local candidates = {}
	local seen = {}
	local rooted = starts_with_any_root(path, category.roots)
	local bases = {}

	if rooted then
		bases[1] = path
	else
		for i, root in ipairs(category.roots) do
			bases[i] = root .. path
		end
	end

	for _, base in ipairs(bases) do
		add_candidate(candidates, seen, base)

		if not has_extension(base) then
			for _, ext in ipairs(category.extensions) do
				add_candidate(candidates, seen, base .. ext)
			end
		end
	end

	return candidates
end

local function get_virtual_asset(path)
	return assets.virtual_assets[normalize_path(path)]
end

local function get_category_name(path)
	local normalized = normalize_path(path)

	for name, category in pairs(assets.categories) do
		if starts_with_any_root(normalized, category.roots) then return name end
	end

	return nil
end

local function get_category(category_name, path)
	local resolved_name = category_name or get_category_name(path)
	local category = resolved_name and assets.categories[resolved_name] or nil

	if not category then
		error(("unknown asset category for %q"):format(tostring(path)), 3)
	end

	return category, resolved_name
end

function assets.ResolvePath(path, category_name, all_candidates)
	local category = get_category(category_name, path)
	local candidates = build_candidates(category, path)

	if all_candidates then return candidates end

	for _, candidate in ipairs(candidates) do
		if get_virtual_asset(candidate) or vfs.IsFile(candidate) then
			return candidate
		end
	end

	return nil, candidates
end

local function get_allowed_extensions(category)
	if category.allowed_extensions then return category.allowed_extensions end

	local allowed = {}

	for _, ext in ipairs(category.extensions) do
		allowed[ext] = true
	end

	category.allowed_extensions = allowed
	return allowed
end

do
	local function make_entry(category, path, root, kind, size, source)
		local dir, file = path:match("^(.*/)([^/]*)$")
		local name, ext = file:match("^(.*)(%.[^.]*)$")

		if name then ext = ext:lower() else name, ext = file, "" end

		return {
			path = path,
			lower_path = path:lower(),
			category = category.name,
			root = root,
			extension = ext,
			kind = kind or (ext == ".lua" and "lua" or "file"),
			name = name,
			dir_path = dir,
			size = size,
			source = source,
		}
	end

	local function get_shortest_root(category, lower_path)
		local best

		for _, root in ipairs(category.roots) do
			if
				lower_path:starts_with(root:lower()) and
				(
					not best or
					#root < #best
				)
			then
				best = root
			end
		end

		return best
	end

	local function new_folder(category, path, name, parent)
		return {
			path = path,
			category = category.name,
			name = name,
			parent = parent,
			folders = {},
			entries = {},
			count = 0,
		}
	end

	local function ensure_folder(index, category, dir_path)
		local lower = dir_path:lower()
		local folder = index.folders[lower]

		if folder then return folder end

		local parent_path = dir_path:match("^(.*/)[^/]+/$")
		local parent = parent_path and ensure_folder(index, category, parent_path) or index.root
		folder = new_folder(category, dir_path, dir_path:match("([^/]+)/$"), parent)
		index.folders[lower] = folder
		list.insert(parent.folders, folder)
		return folder
	end

	local function sort_by_lower_path(a, b)
		return a.lower_path < b.lower_path
	end

	local function find_entry_position(entries, lower_path)
		local low, high = 1, #entries

		while low <= high do
			local mid = math.floor((low + high) / 2)
			local mid_path = entries[mid].lower_path

			if mid_path < lower_path then
				low = mid + 1
			elseif mid_path > lower_path then
				high = mid - 1
			else
				return mid, true
			end
		end

		return low, false
	end

	local function add_entry(index, category, entry, sorted)
		local root = get_shortest_root(category, entry.lower_path)

		if not root then return end

		entry.root = root
		local folder = ensure_folder(index, category, entry.dir_path)
		entry.folder = folder
		index.by_path[entry.lower_path] = entry

		if sorted then
			list.insert(index.entries, find_entry_position(index.entries, entry.lower_path), entry)
			list.insert(folder.entries, find_entry_position(folder.entries, entry.lower_path), entry)
		else
			index.entries[#index.entries + 1] = entry
			folder.entries[#folder.entries + 1] = entry
		end

		while folder do
			folder.count = folder.count + 1
			folder = folder.parent
		end
	end

	local function remove_entry(index, entry)
		index.by_path[entry.lower_path] = nil
		local position, found = find_entry_position(index.entries, entry.lower_path)

		if found then list.remove(index.entries, position) end

		local folder = entry.folder
		position, found = find_entry_position(folder.entries, entry.lower_path)

		if found then list.remove(folder.entries, position) end

		while folder do
			folder.count = folder.count - 1

			if folder.count == 0 and folder.parent then
				index.folders[folder.path:lower()] = nil
				list.remove_value(folder.parent.folders, folder)
			end

			folder = folder.parent
		end
	end

	local function build_index(category)
		local allowed = get_allowed_extensions(category)
		local accepts = category.accepts
		local index = {
			category = category.name,
			mount_generation = vfs.mount_generation,
			version = 0,
			entries = {},
			by_path = {},
			folders = {},
			root = new_folder(category, "", category.name, nil),
		}
		local found = {}
		local paths = {}

		for _, root in ipairs(category.roots) do
			vfs.FindRecursive(root, function(path, size, data)
				local ext = path:match("(%.[^./]+)$")

				if not ext then return end

				ext = ext:lower()

				if not allowed[ext] then return end

				local lower = path:lower()

				if found[lower] then return end

				if accepts and not accepts(lower, ext) then return end

				found[lower] = {path, size, data.context.Name}
				paths[#paths + 1] = lower
			end)
		end

		table.sort(paths)

		for _, lower in ipairs(paths) do
			local info = found[lower]
			add_entry(index, category, make_entry(category, info[1], nil, nil, info[2], info[3]), false)
		end

		for virtual_path, virtual_asset in pairs(assets.virtual_assets) do
			if virtual_asset.category == category.name then
				add_entry(
					index,
					category,
					make_entry(category, virtual_path, nil, virtual_asset.kind, nil, "virtual"),
					true
				)
			end
		end

		table.sort(index.root.folders, function(a, b)
			return a.path:lower() < b.path:lower()
		end)

		return index
	end

	function assets.GetIndex(category_name)
		local category = get_category(category_name, category_name)
		local index = assets.indexes[category_name]

		if index and index.mount_generation == vfs.mount_generation then return index end

		index = build_index(category)
		assets.indexes[category_name] = index
		return index
	end

	function assets.InvalidateIndex(category_name)
		if category_name then
			assets.indexes[category_name] = nil
		else
			assets.indexes = {}
		end
	end

	function assets.IndexVirtualAsset(virtual_asset)
		local index = assets.indexes[virtual_asset.category]

		if not index then return end

		local category = assets.categories[virtual_asset.category]
		local entry = make_entry(category, virtual_asset.path, nil, virtual_asset.kind, nil, "virtual")
		local existing = index.by_path[entry.lower_path]

		if existing then remove_entry(index, existing) end

		add_entry(index, category, entry, true)
		index.version = index.version + 1
	end

	function assets.UnindexVirtualAsset(virtual_asset)
		local index = assets.indexes[virtual_asset.category]

		if not index then return end

		local existing = index.by_path[virtual_asset.path:lower()]

		if existing then
			remove_entry(index, existing)
			index.version = index.version + 1
		end
	end
end

local function find_prefix_folders(index, category, prefix)
	local out = {}

	for _, root in ipairs(category.roots) do
		local path = root

		if prefix then
			path = prefix:lower():starts_with(root:lower()) and prefix or (root .. prefix)
		end

		if not path:ends_with("/") then path = path .. "/" end

		local folder = index.folders[path:lower()]

		if folder then out[#out + 1] = folder end
	end

	return out
end

function assets.EnumerateFolders(category_name, options)
	local category = get_category(category_name, category_name)
	local prefix = options and options.prefix and normalize_path(options.prefix) or nil
	local out = {}

	for _, folder in ipairs(find_prefix_folders(assets.GetIndex(category_name), category, prefix)) do
		for _, child in ipairs(folder.folders) do
			out[#out + 1] = {
				path = child.path,
				category = category.name,
				name = child.name,
			}
		end
	end

	list.sort(out, function(a, b)
		return a.path:lower() < b.path:lower()
	end)

	return out
end

function assets.Enumerate(category_name, options)
	local category = get_category(category_name, category_name)
	options = options or {}
	local prefix = options.prefix and normalize_path(options.prefix) or nil
	local index = assets.GetIndex(category_name)
	local out = {}
	local seen = {}

	for _, folder in ipairs(find_prefix_folders(index, category, prefix)) do
		local candidates = folder.entries

		if options.recursive then
			candidates = {}
			local lower_prefix = folder.path:lower()

			for _, entry in ipairs(index.entries) do
				if entry.lower_path:starts_with(lower_prefix) then
					candidates[#candidates + 1] = entry
				end
			end
		end

		for _, entry in ipairs(candidates) do
			if not seen[entry] then
				seen[entry] = true
				out[#out + 1] = entry
			end
		end
	end

	list.sort(out, function(a, b)
		return a.lower_path < b.lower_path
	end)

	return out
end

do
	local function matches_all(lower_path, tokens)
		for i = 1, #tokens do
			if not lower_path:find(tokens[i], 1, true) then return false end
		end

		return true
	end

	function assets.Search(category_name, query, options)
		local index = assets.GetIndex(category_name)
		local entries = options and options.entries or index.entries
		local prefix = options and options.prefix and options.prefix:lower() or nil
		local tokens = {}

		for token in query:lower():gmatch("%S+") do
			tokens[#tokens + 1] = token
		end

		local first = tokens[1]
		local exact, starts, contains, rest = {}, {}, {}, {}

		for i = 1, #entries do
			local entry = entries[i]
			local lower_path = entry.lower_path

			if (not prefix or lower_path:starts_with(prefix)) and matches_all(lower_path, tokens) then
				local lower_name = entry.lower_name

				if not lower_name then
					lower_name = entry.name:lower()
					entry.lower_name = lower_name
				end

				if lower_name == first then
					exact[#exact + 1] = entry
				elseif lower_name:starts_with(first) then
					starts[#starts + 1] = entry
				elseif lower_name:find(first, 1, true) then
					contains[#contains + 1] = entry
				else
					rest[#rest + 1] = entry
				end
			end
		end

		return list.extend(list.extend(list.extend(exact, starts), contains), rest)
	end
end

function assets.RegisterVirtualAsset(path, config)
	if type(config) == "function" then config = {load = config} end

	assert(type(path) == "string", "virtual asset path must be a string")
	assert(type(config) == "table", "virtual asset config must be a table")
	assert(type(config.load) == "function", "virtual asset config.load must be a function")
	path = normalize_path(path)
	local category_name = config.category or get_category_name(path)

	if not category_name then
		error(("unknown asset category for %q"):format(path), 2)
	end

	local virtual_asset = {
		path = path,
		category = category_name,
		kind = config.kind or (get_extension(path) == ".lua" and "lua" or "file"),
		load = config.load,
	}
	assets.virtual_assets[path] = virtual_asset
	assets.IndexVirtualAsset(virtual_asset)
	return virtual_asset
end

function assets.RegisterVirtualTexture(path, load)
	return assets.RegisterVirtualAsset(path, {category = "textures", load = load, kind = "lua"})
end

function assets.UnregisterVirtualAsset(path)
	path = normalize_path(path)
	local virtual_asset = assets.virtual_assets[path]

	if not virtual_asset then return end

	assets.virtual_assets[path] = nil
	assets.UnindexVirtualAsset(virtual_asset)
end

function assets.IsLoaded(path, options)
	options = options or {}
	local category = get_category(options.category, path)
	local resolved = assets.ResolvePath(path, category.name)

	if not resolved then return false end

	local key = category.build_cache_key(resolved, options)
	return assets.cache[key] ~= nil
end

function assets.Uncache(path, options)
	options = options or {}
	local category = get_category(options.category, path)
	local resolved = assets.ResolvePath(path, category.name)

	if not resolved then return false end

	local key = category.build_cache_key(resolved, options)

	if assets.cache[key] then
		assets.cache[key] = nil
		return true
	end

	return false
end

function assets.ClearCache(category_name)
	if not category_name then
		assets.cache = {}
		return
	end

	for key, entry in pairs(assets.cache) do
		if entry.category == category_name then assets.cache[key] = nil end
	end
end

local function load_lua_asset(path)
	local ok, result = xpcall(function()
		return import(path)
	end, debug.traceback)

	if not ok then return nil, result end

	if result == nil then
		return nil, ("lua asset %q returned nil"):format(path)
	end

	return result
end

local function is_texture_asset(value)
	local value_type = type(value)

	if value_type ~= "table" and value_type ~= "userdata" and value_type ~= "cdata" then
		return false
	end

	return type(value.IsReady) == "function" and
		type(value.GetWidth) == "function" and
		type(value.GetHeight) == "function"
end

function assets.RegisterCategory(name, config)
	assert(type(name) == "string", "category name must be a string")
	assert(type(config) == "table", "category config must be a table")
	assert(type(config.roots) == "table", "category roots must be a table")
	assert(type(config.extensions) == "table", "category extensions must be a table")
	assert(
		type(config.load) == "function" or config.load == false,
		"category load must be a function or false"
	)
	config.name = name
	config.build_cache_key = config.build_cache_key or default_cache_key
	assets.categories[name] = config
	return config
end

local function notify_texture_ready(texture, options)
	if options and options.on_ready then options.on_ready(texture) end
end

if RENDER_2D then
	local Texture = import("goluwa/render/texture.lua")
	assets.RegisterCategory(
		"textures",
		{
			roots = {"textures/render/", "textures/", "materials/"},
			extensions = {".lua", ".png", ".jpg", ".jpeg", ".dds", ".gif", ".vtf"},
			load = function(path, options)
				local ext = get_extension(path)

				if ext == ".lua" then
					local texture, err = load_lua_asset(path)

					if not texture then return nil, err end

					if type(texture) == "function" then
						local ok, result = xpcall(
							function()
								return texture(get_request_config(options))
							end,
							debug.traceback
						)

						if not ok then return nil, result end

						texture = result
					end

					if not is_texture_asset(texture) then
						return nil,
						(
							"texture asset %q must return a ready-to-use texture object or a factory function"
						):format(path)
					end

					notify_texture_ready(texture, options)
					return texture
				end

				local texture_config = {}

				for key, value in pairs(get_request_config(options) or {}) do
					texture_config[key] = value
				end

				texture_config.path = path
				texture_config.on_ready = function(texture)
					notify_texture_ready(texture, options)
				end
				return Texture.New(texture_config)
			end,
		}
	)
end

assets.RegisterCategory(
	"models",
	{
		roots = {"models/", "objects/"},
		extensions = {".lua", ".mdl", ".bsp", ".gltf", ".glb", ".obj", ".cgf"},
		build_cache_key = default_cache_key,
		load = function(path, options, entry)
			local ext = get_extension(path)

			if ext == ".lua" then
				local model, err = load_lua_asset(path)

				if not model then return nil, err end

				if type(model) == "function" then
					local ok, result = xpcall(
						function()
							return model(get_request_config(options))
						end,
						debug.traceback
					)

					if not ok then return nil, result end

					model = result
				end

				entry.value = model
				entry.is_ready = true
				entry.is_loading = false
				flush_ready(entry, entry)
				return entry
			end

			import("goluwa/render3d/model_loader.lua").LoadModel(
				path,
				function(data)
					entry.value = data
					entry.entries = data or entry.entries
					entry.is_ready = true
					entry.is_loading = false
					flush_ready(entry, entry)
				end,
				function(data)
					list.insert(entry.entries, data)
				end,
				function(err)
					entry.error = err
					entry.is_loading = false
					assets.cache[entry.cache_key] = nil
					flush_error(entry, err)
				end
			)

			return entry
		end,
	}
)
assets.RegisterCategory(
	"materials",
	{
		roots = {"materials/", "objects/"},
		extensions = {".lua", ".vmt", ".mtl"},
		load = function(path, options)
			if get_extension(path) == ".lua" then
				local material, err = load_lua_asset(path)

				if not material then return nil, err end

				if type(material) == "function" then
					material = material(get_request_config(options))
				end

				if material.Type ~= "render3d_material" then
					material = import("goluwa/render3d/material.lua").New(material)
				end

				return material
			end

			import("goluwa/source_engine/vmt_material.lua")
			import("goluwa/cry_engine/mtl_material.lua")
			local slots, material = import("goluwa/render3d/material.lua").GetOverrideFromPath(path)
			return material or slots[0]
		end,
	}
)
assets.RegisterCategory(
	"sounds",
	{
		roots = {"sound/", "sounds/"},
		extensions = {".lua", ".wav", ".ogg", ".mp3"},
		load = false,
	}
)
assets.RegisterCategory("scenes", {
	roots = {"scenes/"},
	extensions = {".lua"},
	load = false,
})
-- a prefab is identified by its name, the file stem, so properties and pickers hold the name and not the path
assets.RegisterCategory(
	"prefabs",
	{
		roots = {"prefabs/"},
		extensions = {".prefab"},
		load = false,
		accepts = function(lower_path)
			return not lower_path:find("/", #"prefabs/" + 1, true)
		end,
		get_value = function(entry)
			return entry.name
		end,
		get_path = function(value)
			return "prefabs/" .. value .. ".prefab"
		end,
	}
)

function assets.RefreshInternalTextures()
	local current = {}

	if RENDER_2D then
		local Texture = import("goluwa/render/texture.lua")

		for _, texture in pairs(Texture.Instances) do
			if texture:IsValid() then
				current["textures/internals/" .. tostring(texture):gsub("/", "|")] = texture
			end
		end
	end

	for virtual_path in pairs(assets.virtual_assets) do
		if virtual_path:starts_with("textures/internals/") and not current[virtual_path] then
			assets.UnregisterVirtualAsset(virtual_path)
		end
	end

	for virtual_path, texture in pairs(current) do
		if not assets.virtual_assets[virtual_path] then
			assets.RegisterVirtualAsset(
				virtual_path,
				{
					category = "textures",
					load = function()
						return texture:IsValid() and texture or nil
					end,
				}
			)
		end
	end
end

function assets.Load(path, options)
	options = options or {}
	local category, category_name = get_category(options.category, path)
	local resolved, tried = assets.ResolvePath(path, category_name)

	if not resolved then
		if options.on_error then
			options.on_error(("unable to resolve asset %q"):format(path), tried)
		end

		return nil
	end

	local key = category.build_cache_key(resolved, options)
	local cached = assets.cache[key]
	local virtual_asset = get_virtual_asset(resolved)
	local load = virtual_asset and virtual_asset.load or category.load

	if cached then
		if category_name == "models" then
			if cached.is_ready then
				if options.on_ready then options.on_ready(cached) end
			elseif cached.error then
				if options.on_error then options.on_error(cached.error) end
			else
				queue_callbacks(cached, options)
			end

			return cached
		end

		if options.on_ready then
			if cached.IsReady and cached:IsReady() then options.on_ready(cached) end
		end

		return cached
	end

	if category.load == false and not virtual_asset then
		error(("asset category %q does not support loading yet"):format(category_name), 2)
	end

	if category_name == "models" then
		local entry = make_model_entry(resolved, key)
		assets.cache[key] = entry
		queue_callbacks(entry, options)
		local ok, result = xpcall(load, debug.traceback, resolved, options, entry)

		if not ok then
			assets.cache[key] = nil
			entry.error = result
			entry.is_loading = false
			flush_error(entry, result)
			return entry
		end

		return result
	end

	local ok, result = xpcall(load, debug.traceback, resolved, options)

	if not ok then
		if options.on_error then options.on_error(result) end

		return nil
	end

	assets.cache[key] = result
	return result
end

local srgb_image_extensions = {
	png = true,
	jpg = true,
	jpeg = true,
}

function assets.GetTexture(path, options)
	options = options or {}
	options.category = "textures"
	local config = options.config or {}

	if config.srgb == nil then
		local ext = path:lower():match("%.(%w+)$")
		config.srgb = srgb_image_extensions[ext] or false
	end

	options.config = config
	return assets.Load(path, options)
end

function assets.GetMaterial(path, options)
	options = options or {}
	options.category = "materials"
	return assets.Load(path, options)
end

function assets.GetModel(path, options)
	options = options or {}
	options.category = "models"
	return assets.Load(path, options)
end

return assets
