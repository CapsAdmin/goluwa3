local objects = import("goluwa/objects/objects.lua")
local prefab = import("goluwa/entities/prefab.lua")
local META = objects.CreateTemplate("script")
META.Network = {
	Source = {"string", 0.5, "reliable"},
	Values = {"table", 0.5, "reliable"},
}
local LIFECYCLE = {
	OnConstruct = true,
	OnCreate = true,
	OnPostCreate = true,
	OnAdd = true,
	OnRemove = true,
	OnReload = true,
	OnFirstCreated = true,
	OnLastRemoved = true,
	OnUpdate = true,
}
META:StartStorable()
META:GetSet(
	"Source",
	"",
	{
		callback = "Reload",
		code = "lua",
		status = function(script)
			return script.Error
		end,
	}
)
META:GetSet("Values", nil, {callback = "OnValuesChanged", Hidden = true})
META:EndStorable()
local classes = {}
local scope_counter = 0

local function call(script, fn, ...)
	if script.Error then return end

	prefab.Suppress()
	local ok, result = xpcall(fn, debug.traceback, ...)
	prefab.Unsuppress()

	if not ok then
		script.Error = result
		wlog("script of %s failed: %s", script.Owner, result)

		if script.instance then
			for name in pairs(script.instance.added_events or {}) do
				script.instance:RemoveEvent(name)
			end
		end

		return
	end

	return result
end

local function acquire_class(source, name)
	local class = classes[source]

	if class then
		class.count = class.count + 1
		return class
	end

	local chunk, err = loadstring(source, "=script:" .. (name ~= "" and name or "entity"))

	if not chunk then return nil, err end

	scope_counter = scope_counter + 1
	objects.registry_scope = "script" .. scope_counter .. ":"
	local ok, meta = xpcall(chunk, debug.traceback)
	objects.registry_scope = nil

	if not ok then return nil, meta end

	if type(meta) ~= "table" or not meta.RegistryKey then
		return nil,
		"the script must return the component it defines (return META:Register())"
	end

	for key, fn in pairs(meta) do
		if type(fn) == "function" and (key == "Initialize" or key:starts_with("On")) then
			meta[key] = function(self, ...)
				local script = self.ScriptComponent

				if script.Error then return end

				return call(script, fn, self, ...)
			end
		end
	end

	local properties = {}

	for _, info in pairs(meta.objects_variables or {}) do
		if not info.Hidden then properties[#properties + 1] = info end
	end

	table.sort(properties, function(a, b)
		return a.order < b.order
	end)

	class = {meta = meta, source = source, count = 1, properties = properties}
	classes[source] = class
	return class
end

local function release_class(class)
	class.count = class.count - 1

	if class.count == 0 then
		objects.Unregister(class.meta)
		classes[class.source] = nil
	end
end

local function build_instance(script, class)
	local entity = script.Owner
	local meta = class.meta
	local alias = meta.Type

	if entity[alias] ~= nil then
		error("the entity already has a " .. alias .. " component", 0)
	end

	local instance = entity:CreateSubObject(meta, {ScriptComponent = script})
	script.instance = instance
	script.alias = alias
	entity[alias] = instance

	for key, fn in pairs(meta) do
		if
			type(fn) == "function" and
			key:starts_with("On") and
			not LIFECYCLE[key] and
			script[key] == nil
		then
			script.event_names[#script.event_names + 1] = key
			script[key] = function(_, a, b, c, d, e, f, g)
				return instance[key](instance, a, b, c, d, e, f, g)
			end
		end
	end

	instance:AddPropertyListener(script.OnInstancePropertyChanged, "script")
	script:ApplyValues()

	if instance.Initialize then instance:Initialize() end

	if instance.OnAdd then instance:OnAdd() end
end

function META:OnCreate()
	self.event_names = {}
	self.load_id = 0
end

function META:Initialize()
	self.initialized = true
	self:Reload()
end

function META:Unload()
	self.load_id = self.load_id + 1
	local instance = self.instance

	if instance then
		for _, name in ipairs(self.event_names) do
			self[name] = nil
		end

		self.event_names = {}
		local entity = self.Owner
		entity[self.alias] = nil
		entity.sub_objects[instance] = nil
		entity.call_on_remove[instance] = nil
		instance:Remove()
		self.instance = nil
	end

	if self.class then
		release_class(self.class)
		self.class = nil
	end

	self.Error = nil
end

function META:Reload()
	if not self.initialized then return end

	self:Unload()

	if not self.Source:find("^%s*$") then
		local class, err = acquire_class(self.Source, self.Owner:GetName())

		if class then
			self.class = class
			local id = self.load_id

			prefab.WhenBuilt(function()
				if self.load_id ~= id then return end

				call(self, build_instance, self, class)
				objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})
			end)

			return
		end

		self.Error = err
		wlog("script of %s failed to load: %s", self.Owner, err)
	end

	objects.NotifyPropertyListeners(self, {var_name = "DynamicProperties"})
end

function META:OnRemove()
	self:Unload()
end

function META:ApplyValues()
	local instance = self.instance
	local values = self.Values
	self.syncing = true

	for _, info in ipairs(self.class.properties) do
		if info.storable then
			local value = values and values[info.var_name]

			if value == nil then value = info.copy and info.copy() or info.default end

			objects.SetProperty(instance, info.var_name, prefab.CopyValue(value))
		end
	end

	self.syncing = false
end

function META:OnValuesChanged()
	if self.syncing or not self.instance then return end

	self:ApplyValues()
end

function META.OnInstancePropertyChanged(instance, var_name, new_value, old_value, info)
	local script = instance.ScriptComponent

	if info.storable and not script.syncing then
		local values = {}

		for key, value in pairs(script.Values or {}) do
			values[key] = value
		end

		if objects.IsPropertyValueEqual(info, new_value, info.default) then
			values[var_name] = nil
		else
			values[var_name] = prefab.CopyValue(new_value)
		end

		script.syncing = true
		script:SetValues(next(values) and values or nil)
		script.syncing = false
	end

	objects.NotifyPropertyListeners(script, {var_name = "properties/" .. var_name}, old_value, new_value)
end

do
	local function get(script, info)
		local instance = script.instance
		return instance[info.get_name](instance)
	end

	local function set(script, info, value)
		objects.SetProperty(script.instance, info.var_name, value)
	end

	function META:GetDynamicProperties()
		local out = {}

		if not self.instance then return out end

		for _, info in ipairs(self.class.properties) do
			local row = {}

			for key, value in pairs(info) do
				row[key] = value
			end

			row.key = "properties/" .. info.var_name
			row.link = info.storable and {Property = "Values", Key = info.var_name} or nil
			row.storable = false
			row.callback = nil
			row.requires = nil
			row.get = function(script)
				return get(script, info)
			end
			row.set = function(script, value)
				set(script, info, value)
			end

			if info.get_enums then
				row.get_enums = function(script)
					return info.get_enums(script.instance)
				end
			end

			out[#out + 1] = row
		end

		return out
	end
end

return META:Register()
