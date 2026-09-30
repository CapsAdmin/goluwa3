local objects = import("goluwa/objects/objects.lua")
local codec = import("goluwa/codec.lua")
local callstack = import("goluwa/debug/callstack.lua")
local timer = import("goluwa/timer.lua")
local event = import("goluwa/event.lua")
local pvars = library()
local path = "data/pvars.txt"
local mode = "luadata"
pvars.vars = pvars.vars or {}
pvars.infos = pvars.infos or {}
pvars.groups = pvars.groups or {}
-- key -> the value on disk (false for none) of a pvar set with SetSession
pvars.session = pvars.session or {}

do
	local group

	function pvars.StartGroup(name, defaults)
		group = {name = name, defaults = defaults or {}}
	end

	function pvars.EndGroup()
		group = nil
	end

	function pvars.GetCurrentGroup()
		return group
	end
end

-- returns the value to store, or nil and why it can't be
local function validate(info, val)
	if val == nil then val = info.default end

	if val == nil then return nil end

	if typex(val) ~= info.type then
		return nil, string.format("expected %s, got %s", info.type, typex(val))
	end

	if info.enums then
		if not table.has_value(info.enums, val) then
			return nil, "expected one of: " .. table.concat(info.enums, ", ")
		end
	end

	if info.type == "number" then
		if info.integer then val = math.floor(val + 0.5) end

		if info.min or info.max then
			val = math.clamp(val, info.min or -math.huge, info.max or math.huge)
		end
	end

	if info.modify then val = info.modify(val) end

	return val
end

-- values that came from a file or a definition fall back to the default when
-- they are no longer valid, values from Set are errors
local function load(key, val)
	local info = pvars.infos[key]
	local checked, err = validate(info, val)

	if err then
		logf("[pvars] %s: %s, using the default\n", key, err)
		checked = validate(info, nil)
	end

	pvars.vars[key] = checked
end

local function write_file()
	local vars = {}

	for key, val in pairs(pvars.vars) do
		local info = pvars.infos[key]

		local session = pvars.session[key]

		if session ~= nil then
			if session ~= false then vars[key] = session end
		elseif not info or info.store then
			vars[key] = val
		end
	end

	codec.WriteFile(mode, path, vars)
end

function pvars.Initialize()
	local old = {}

	for key, val in pairs(pvars.vars) do
		old[key] = val
	end

	pvars.vars = codec.ReadFile(mode, path) or {}

	for key, info in pairs(pvars.infos) do
		load(key, info.store and pvars.vars[key] or nil)
	end

	pvars.init = true
	write_file()

	for key, info in pairs(pvars.infos) do
		if info.callback and pvars.vars[key] ~= old[key] then
			callstack.pcall(info.callback, pvars.vars[key])
			event.Call("PersistentVariableChanged", key, pvars.vars[key], old[key])
		end
	end
end

function pvars.Save()
	if pvars.init then timer.Delay(0, write_file, "save_pvars") end
end

local META = objects.CreateTemplate("pvar")

function META:Get()
	local val = pvars.vars[self.key]

	if val == nil then return pvars.infos[self.key].default end

	return val
end

function META:Set(val)
	pvars.Set(self.key, val)
end

function META:SetSession(val)
	pvars.SetSession(self.key, val)
end

function META:GetInfo()
	return pvars.infos[self.key]
end

function META:GetCallback()
	return pvars.infos[self.key].callback
end

function META:GetDefault()
	return pvars.infos[self.key].default
end

function META:GetType()
	return pvars.infos[self.key].type
end

function META:GetHelp()
	return pvars.infos[self.key].help
end

function META:GetGroup()
	return pvars.infos[self.key].group
end

META:Register()

function pvars.Setup2(info)
	assert(info.key, "a pvar needs a key")
	local group = pvars.GetCurrentGroup()

	if group then
		info.group = info.group or group.name

		for k, v in pairs(group.defaults) do
			if info[k] == nil then info[k] = v end
		end
	end

	if info.default == nil then
		assert(info.type, info.key .. ": a pvar without a default needs a type")
	end

	info.type = info.type or typex(info.default)

	if info.store == nil then info.store = true end

	if info.enums then
		assert(info.type ~= "table", info.key .. ": enums need a scalar type")
		assert(
			info.default == nil or table.has_value(info.enums, info.default),
			info.key .. ": the default is not one of the enums"
		)
	end

	if info.min or info.max or info.integer then
		assert(info.type == "number", info.key .. ": min, max and integer need a number")
	end

	if not info.group then info.group = info.key:match("^([^_%s]+)_") or "other" end

	if not info.friendly then
		local friendly = info.key:gsub("^r_", "")
		local prefix = info.group .. "_"

		if friendly:sub(1, #prefix) == prefix and #friendly > #prefix then
			friendly = friendly:sub(#prefix + 1)
		end

		info.friendly = friendly:gsub("_", " ")
	end

	pvars.infos[info.key] = info
	info.object = META:CreateObject({key = info.key})
	load(info.key, info.store and pvars.vars[info.key] or nil)

	if info.callback then
		timer.Delay(function()
			local val = pvars.Get(info.key)
			event.Call("PersistentVariableChanged", info.key, val, nil)
			info.callback(val, true)
		end)
	end

	if info.store then pvars.Save() end

	return info.object
end

function pvars.Setup(key, def, callback, help, dont_save)
	return pvars.Setup2{
		key = key,
		default = def,
		callback = callback,
		help = help,
		store = not dont_save,
	}
end

function pvars.GetAll()
	return pvars.infos
end

function pvars.GetGroups()
	local by_name = {}
	local out = {}

	for _, info in pairs(pvars.infos) do
		local entry = by_name[info.group]

		if not entry then
			entry = {name = info.group, infos = {}}
			by_name[info.group] = entry
			out[#out + 1] = entry
		end

		entry.infos[#entry.infos + 1] = info
	end

	table.sort(out, function(a, b)
		return a.name < b.name
	end)

	for _, entry in ipairs(out) do
		table.sort(entry.infos, function(a, b)
			return a.key < b.key
		end)
	end

	return out
end

function pvars.GetObject(key)
	local info = pvars.infos[key]

	if info then return info.object end
end

function pvars.IsSetup(key)
	return pvars.infos[key] ~= nil
end

function pvars.Get(key)
	local info = pvars.infos[key]

	if info then
		local val = pvars.vars[key]

		if val == nil then val = info.default end

		return val
	end
end

local function set(key, val, session)
	local info = assert(pvars.infos[key], "unknown pvar " .. tostring(key))
	local old = pvars.Get(key)
	local checked, err = validate(info, val)

	if err then error(key .. ": " .. err, 0) end

	if session then
		if info.store and pvars.session[key] == nil then
			local stored = pvars.vars[key]

			if stored == nil then stored = false end

			pvars.session[key] = stored
		end
	else
		pvars.session[key] = nil
	end

	pvars.vars[key] = checked

	if info.store then pvars.Save() end

	if info.callback and not info.in_callback then
		info.in_callback = true
		callstack.pcall(info.callback, checked)
		info.in_callback = nil
	end

	event.Call("PersistentVariableChanged", key, checked, old)
end

function pvars.Set(key, val)
	set(key, val, false)
end

-- like Set, but the value is not written to disk: the next run starts from the
-- value that was there before
function pvars.SetSession(key, val)
	set(key, val, true)
end

do
	local booleans = {
		["1"] = true,
		["true"] = true,
		on = true,
		yes = true,
		y = true,
		["0"] = false,
		["false"] = false,
		off = false,
		no = false,
		n = false,
	}

	function pvars.SetString(key, val)
		local info = assert(pvars.infos[key], "unknown pvar " .. tostring(key))

		if info.type == "table" then
			val = codec.GetLibrary("comma").Decode(val)
		elseif info.type == "boolean" then
			local parsed = booleans[val:trim():lower()]

			if parsed == nil then error(key .. ": expected a boolean, got " .. val, 0) end

			val = parsed
		elseif info.type == "number" then
			local parsed = tonumber(val)

			if parsed == nil then error(key .. ": expected a number, got " .. val, 0) end

			val = parsed
		elseif info.type ~= "string" then
			val = codec.GetLibrary(mode).FromString(val)
		end

		pvars.Set(key, val)
	end
end

function pvars.GetString(key)
	local val = pvars.Get(key)
	local info = pvars.infos[key]

	if val == nil then return "nil" end

	if info.type == "table" then return codec.GetLibrary("comma").Encode(val) end

	if info.type == "string" or info.type == "boolean" or info.type == "number" then
		return tostring(val)
	end

	return codec.GetLibrary(mode).Encode(val)
end

return pvars
