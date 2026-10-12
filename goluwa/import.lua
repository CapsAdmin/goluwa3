local import = {}
import.__index = import
import.loaded = {}
import.loading_stack = {}
import.loading = {}
import.imports = {}
import.importers = {}
import.strong = {}
import.snapshots = {}
import.tracking = false

for _, value in ipairs(_G.arg or {}) do
	if value == "--hot-reload" then import.tracking = true end
end

local require = require("goluwa.require")

function import:GetCurrentPath()
	return self.loading_stack[#self.loading_stack]
end

function import:GetCurrentBasePath()
	local path = self:GetCurrentPath()
	return path and require.GetBasePath(path) or nil
end

function import:GetCallerPath(stack_level)
	return require.GetCallerPath(stack_level or 2, debug.getinfo(1, "S").source)
end

function import:ResolvePath(path)
	local current_path = self:GetCurrentPath()
	local caller_path

	if
		path:find("./", 1, true) == 1 or
		path:find("../", 1, true) == 1 or
		path:find("lua/ui/", 1, true) == 1
	then
		caller_path = self:GetCallerPath(2)
	end

	return require.ResolveImportPath(path, current_path, caller_path)
end

import.loadfile = _G.loadfile

local source_paths = {}

function import.SourceToPath(source)
	local path = source_paths[source]

	if path == nil then
		path = source:byte(1) == 64 and source:sub(2):gsub("^%./", ""):gsub("//+", "/") or false
		source_paths[source] = path
	end

	return path
end

local function add_edge(importer, path)
	local imports = import.imports[importer]

	if not imports then
		imports = {}
		import.imports[importer] = imports
	end

	imports[path] = true
	local importers = import.importers[path]

	if not importers then
		importers = {}
		import.importers[path] = importers
	end

	importers[importer] = true
end

local get_info = debug.getinfo
local get_own_functions
local take_snapshot
local find_load_time_uses

function import:__call(path)
	path = self:ResolvePath(path)

	if self.tracking then
		local importer = self.loading_stack[#self.loading_stack]

		-- imports made after a module has loaded fetch the module again every time, so they can't go stale
		if importer and importer ~= path then add_edge(importer, path) end
	end

	if self.loaded[path] then return self.loaded[path] end

	if self.loading[path] then
		error("import loop detected while loading " .. path, 2)
	end

	self.loading[path] = true
	local chunk, err = self.loadfile(path)

	if not chunk then
		self.loading[path] = nil
		error("Error loading " .. path .. ": " .. err, 2)
	end

	local ok, result = self:Run(path, chunk)
	self.loading[path] = nil

	if not ok then error(result, 0) end

	self.loaded[path] = result

	if self.tracking and type(result) == "table" and result.Type == nil then
		take_snapshot(result, path, get_own_functions(result, path))
	end

	return self.loaded[path]
end

do
	local function run_chunk(chunk, path)
		return chunk(path)
	end

	function import:Run(path, chunk)
		self.loading_stack[#self.loading_stack + 1] = path

		if self.tracking then
			find_load_time_uses = find_load_time_uses or _G.require("goluwa.load_time_uses")
			self.strong[path] = find_load_time_uses(chunk, path)
		end

		local ok, result = xpcall(run_chunk, debug.traceback, chunk, path)
		self.loading_stack[#self.loading_stack] = nil
		return ok, result
	end
end

-- the functions a module defined itself, as opposed to ones other files added to its table
function get_own_functions(module, path)
	local own = {}
	local source = "@" .. path
	local count = 0

	for key, value in pairs(module) do
		if type(value) == "function" and get_info(value, "S").source == source then
			own[key] = value
			count = count + 1
		end
	end

	return count > 0 and own or nil
end

-- a module that returns a fresh table still has to be the table everyone already holds,
-- so its closures are pointed at the old one and the contents moved over
local function adopt_table(old, new)
	local function rebind(value)
		if type(value) ~= "function" then return end

		local i = 1

		while true do
			local name, upvalue = debug.getupvalue(value, i)

			if not name then break end

			if upvalue == new then debug.setupvalue(value, i, old) end

			i = i + 1
		end
	end

	for _, value in pairs(new) do
		rebind(value)

		if type(value) == "table" and value ~= new then
			for _, nested in pairs(value) do
				rebind(nested)
			end
		end
	end

	for key, value in pairs(new) do
		old[key] = value
	end

	setmetatable(old, getmetatable(new))
end

-- every closure of a module's own functions, including the local helpers they call. a slot names
-- an upvalue by the path of functions leading to it, so the same variable is found again after a reload
local function walk_upvalues(module, own, source, callback)
	local function visit(func, prefix, visited)
		visited[func] = true
		local i = 1

		while true do
			local name, value = debug.getupvalue(func, i)

			if not name then break end

			local slot = prefix .. "/" .. i .. name
			callback(slot, func, i, value)

			if
				type(value) == "function" and
				not visited[value] and
				get_info(value, "S").source == source
			then
				visit(value, slot, visited)
			end

			i = i + 1
		end
	end

	for key in pairs(own) do
		local func = module[key]

		if type(func) == "function" then visit(func, tostring(key), {}) end
	end
end

-- small tables get copied so that changes made in place can be told from what the file set up
local function shallow_copy(value)
	if type(value) ~= "table" then return nil end

	local copy = {}
	local count = 0

	for key, item in pairs(value) do
		count = count + 1

		if count > 64 then return nil end

		copy[key] = item
	end

	return copy
end

local function table_mutated(copy, current)
	for key, value in pairs(copy) do
		if current[key] ~= value then return true end
	end

	for key in pairs(current) do
		if copy[key] == nil then return true end
	end

	return false
end

-- what the module looked like right after it loaded, to tell what it did itself from what happened later
function take_snapshot(module, path, own)
	local snapshot = {values = {}, copies = {}, upvalues = {}, upvalue_copies = {}}

	for key, value in pairs(module) do
		if type(value) ~= "function" then
			snapshot.values[key] = value
			snapshot.copies[key] = shallow_copy(value)
		end
	end

	if own then
		walk_upvalues(module, own, "@" .. path, function(slot, _, _, value)
			snapshot.upvalues[slot] = value
			snapshot.upvalue_copies[slot] = shallow_copy(value)
		end)
	end

	import.snapshots[path] = snapshot
end

local function is_live_object(value)
	local kind = type(value)

	if kind == "cdata" then return not tostring(value):find("^ctype<") end

	return kind == "table" or kind == "userdata" or kind == "thread"
end

-- state is whatever changed after the module loaded, and it survives unless the file now sets something different
local function keep_current(loaded, loaded_copy, current, new)
	if type(current) == "function" then return false end

	if
		current == loaded and
		not (
			loaded_copy and
			type(current) == "table" and
			table_mutated(loaded_copy, current)
		)
	then
		return false
	end

	if type(new) == "table" then
		if loaded_copy and next(loaded_copy) == nil then return next(new) == nil end

		return true
	end

	if type(new) == "cdata" or type(new) == "userdata" then return true end

	return new == loaded
end

function import:IsNamespace(path)
	local module = self.loaded[path]

	return type(module) == "table" and
		module.Type == nil and
		get_own_functions(module, path) ~= nil
end

-- returns true when the module is still the same value everyone else holds, false when
-- importers are holding a stale value, nil and an error when it did not load
function import:Reload(path)
	local chunk, err = self.loadfile(path)

	if not chunk then return nil, err end

	local old = self.loaded[path]
	local is_table = type(old) == "table"
	local own = is_table and old.Type == nil and get_own_functions(old, path)
	local snapshot = self.snapshots[path]
	local current_fields = {}
	local current_upvalues = {}

	if own then
		for key, value in pairs(old) do
			if type(value) ~= "function" then current_fields[key] = value end
		end

		walk_upvalues(old, own, "@" .. path, function(slot, _, _, value)
			current_upvalues[slot] = value
		end)

		for key in pairs(own) do
			old[key] = nil
		end
	end

	local old_imports = self.imports[path]

	for dependency in pairs(old_imports or {}) do
		self.importers[dependency][path] = nil
	end

	self.imports[path] = nil
	self.loaded[path] = nil
	self.loading[path] = true
	local ok, result = self:Run(path, chunk)
	self.loading[path] = nil

	if not ok then
		self.loaded[path] = old

		for key, value in pairs(own or {}) do
			if old[key] == nil then old[key] = value end
		end

		if old_imports then
			for dependency in pairs(old_imports) do
				add_edge(path, dependency)
			end
		end

		return nil, result
	end

	local kept = false
	local module = result

	if result == old then
		kept = true
	elseif is_table and type(result) == "table" and (own or result.Type ~= nil) then
		kept = true

		if result.Type == nil then
			adopt_table(old, result)
			module = old
		end
	end

	self.loaded[path] = module

	if kept and own and module.Type == nil then
		local new_own = get_own_functions(module, path)
		take_snapshot(module, path, new_own)

		if snapshot and new_own then
			for key, value in pairs(current_fields) do
				if
					keep_current(
						snapshot.values[key],
						snapshot.copies[key],
						value,
						module[key]
					)
				then
					module[key] = value
				end
			end

			walk_upvalues(module, new_own, "@" .. path, function(slot, func, i, value)
				local current = current_upvalues[slot]

				-- only live objects survive. a string or number is as likely to be a cache of what the
				-- edited code produces, or to belong to a buffer that was just made again at its default size
				if
					current ~= nil and
					is_live_object(current) and
					keep_current(
						snapshot.upvalues[slot],
						snapshot.upvalue_copies[slot],
						current,
						value
					)
				then
					debug.setupvalue(func, i, current)
				end
			end)
		end
	elseif type(module) == "table" and module.Type == nil then
		take_snapshot(module, path, get_own_functions(module, path))
	end

	return kept
end

setmetatable(import, import)
return import
