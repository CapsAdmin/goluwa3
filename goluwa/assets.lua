local assets = library()
local vfs = import("goluwa/vfs.lua")
local Texture = import("goluwa/render/texture.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
assets.categories = assets.categories or {}
assets.cache = assets.cache or {}
assets.virtual_assets = assets.virtual_assets or {}

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
	local name = vfs.GetFileNameFromPath(path)
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

local function make_browser_entry(category_name, path, root, kind)
	return {
		path = path,
		category = category_name,
		root = root,
		extension = get_extension(path),
		kind = kind or (get_extension(path) == ".lua" and "lua" or "file"),
		name = get_file_stem(path),
	}
end

local function enumerate_logical_files(path, recursive, out, seen)
	for _, name in ipairs(vfs.Find(path)) do
		local child_path = path

		if not child_path:ends_with("/") then child_path = child_path .. "/" end

		child_path = normalize_path(child_path .. name)

		if vfs.IsDirectory(child_path) then
			if recursive then enumerate_logical_files(child_path, recursive, out, seen) end
		else
			local key = child_path:lower()

			if not seen[key] then
				seen[key] = true
				out[#out + 1] = child_path
			end
		end
	end
end

function assets.Enumerate(category_name, options)
	local category = get_category(category_name, category_name)
	options = options or {}
	local recursive = not not options.recursive
	local prefix = options.prefix and normalize_path(options.prefix) or nil
	local out = {}
	local seen = {}

	for _, root in ipairs(category.roots) do
		local scan_root

		if prefix and prefix ~= "" then
			if prefix:lower():starts_with(root:lower()) then
				scan_root = prefix
			else
				scan_root = root .. prefix
			end
		else
			scan_root = root
		end

		if not scan_root:ends_with("/") then scan_root = scan_root .. "/" end

		local found = {}
		enumerate_logical_files(scan_root, recursive, found, {})

		for _, path in ipairs(found) do
			if not vfs.IsDirectory(path) then
				local ext = get_extension(path)

				if ext then
					for _, allowed_ext in ipairs(category.extensions) do
						if ext == allowed_ext then
							local key = path:lower()

							if not seen[key] then
								seen[key] = true
								list.insert(out, make_browser_entry(category.name, path, root))
							end

							break
						end
					end
				end
			end
		end

		for virtual_path, virtual_asset in pairs(assets.virtual_assets) do
			if
				virtual_asset.category == category.name and
				virtual_path:lower():starts_with(scan_root:lower())
			then
				local key = virtual_path:lower()

				if not seen[key] then
					seen[key] = true
					list.insert(out, make_browser_entry(category.name, virtual_path, root, virtual_asset.kind))
				end
			end
		end
	end

	list.sort(out, function(a, b)
		return a.path:lower() < b.path:lower()
	end)

	return out
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

	assets.virtual_assets[path] = {
		path = path,
		category = category_name,
		kind = config.kind or (get_extension(path) == ".lua" and "lua" or "file"),
		load = config.load,
	}
	return assets.virtual_assets[path]
end

function assets.RegisterVirtualTexture(path, load)
	return assets.RegisterVirtualAsset(path, {category = "textures", load = load, kind = "lua"})
end

function assets.UnregisterVirtualAsset(path)
	path = normalize_path(path)
	assets.virtual_assets[path] = nil
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
assets.RegisterCategory(
	"models",
	{
		roots = {"models/"},
		extensions = {".lua", ".mdl", ".bsp", ".gltf", ".glb", ".obj"},
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

			model_loader.LoadModel(
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
		roots = {"materials/"},
		extensions = {".lua", ".vmt"},
		load = false,
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

	if category.load == false then
		error(("asset category %q does not support loading yet"):format(category_name), 2)
	end

	if category_name == "models" then
		local entry = make_model_entry(resolved, key)
		assets.cache[key] = entry
		queue_callbacks(entry, options)
		local ok, result = xpcall(function()
			return load(resolved, options, entry)
		end, debug.traceback)

		if not ok then
			assets.cache[key] = nil
			entry.error = result
			entry.is_loading = false
			flush_error(entry, result)
			return entry
		end

		return result
	end

	local ok, result = xpcall(function()
		return load(resolved, options)
	end, debug.traceback)

	if not ok then
		if options.on_error then options.on_error(result) end

		return nil
	end

	assets.cache[key] = result
	return result
end

function assets.GetTexture(path, options)
	options = options or {}
	options.category = "textures"
	return assets.Load(path, options)
end

function assets.GetModel(path, options)
	options = options or {}
	options.category = "models"
	return assets.Load(path, options)
end

return assets
