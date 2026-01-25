local event = require("event")
local system = require("system")
local traceback = require("helpers.traceback")
local prototype = library()
prototype.registered = prototype.registered or {}
prototype.prepared_metatables = prototype.prepared_metatables or {}
prototype.invalidate_meta = prototype.invalidate_meta or {}
local template_functions = {
	"GetSet",
	"IsSet",
	"Delegate",
	"GetSetDelegate",
	"DelegateProperties",
	"RemoveField",
	"StartStorable",
	"EndStorable",
	"Register",
	"RegisterComponent",
	"CreateObject",
}

function prototype.CreateTemplate(type_name)
	local template = {Type = type_name}

	for _, key in ipairs(template_functions) do
		template[key] = prototype[key]
	end

	return template
end

do
	local blacklist = {
		prototype_variables = true,
		Events = true,
		Require = true,
		Network = true,
		write_functions = true,
		read_functions = true,
		Args = true,
		type_ids = true,
		storable_variables = true,
		ProtectedFields = true,
	}

	function prototype.Register(meta)
		if not meta.Type then error("The type field was not found!", 2) end

		if meta.Base then
			if type(meta.Base) ~= "table" then
				error(
					string.format(
						"%s: Base must be a table (is %s: %s)",
						meta.Type,
						type(meta.Base),
						tostring(meta.Base)
					),
					2
				)
			end

			if not meta.Base.Type then
				error(string.format("%s: Base table does not have a Type field", meta.Type), 2)
			end

			meta.Base = meta.Base.Type
		end

		for _, key in ipairs(template_functions) do
			if key ~= "CreateObject" and meta[key] == prototype[key] then
				meta[key] = nil
			end
		end

		prototype.registered[meta.Type] = meta
		prototype.invalidate_meta[meta.Type] = true

		if HOTRELOAD then
			logn("Hotreloading prototype: " .. meta.Type)
			prototype.UpdateObjects(meta)

			for k, v in pairs(meta) do
				if type(v) ~= "function" and not blacklist[k] then
					local found = false

					if meta.prototype_variables then
						for _, v in pairs(meta.prototype_variables) do
							if v.var_name == k then
								found = true

								break
							end
						end
					end

					local t = type(v)

					if
						t == "number" or
						t == "string" or
						t == "function" or
						t == "boolean" or
						typex(v) == "null"
					then
						found = true
					end

					if not found then
						wlog("%s: META.%s = %s is mutable", meta.Type, k, tostring(v), 2)
					end
				end
			end
		end

		return meta
	end
end

function prototype.RebuildMetatables(what)
	for type_name, meta in pairs(prototype.registered) do
		if what == nil or what == type_name then
			prototype.invalidate_meta[type_name] = nil
			local copy = {}
			local prototype_variables = {}

			-- first add all the base functions from the base object
			for k, v in pairs(prototype.base_metatable) do
				copy[k] = v

				if k == "prototype_variables" then
					for k, v in pairs(v) do
						prototype_variables[k] = v
					end
				end
			end

			-- then go through the list of bases and derive from them in reversed order
			local base_list = {}

			if meta.Base then
				list.insert(base_list, meta.Base)
				local base = meta

				for _ = 1, 50 do
					base = prototype.registered[base.Base]

					if not base or not base.Base then break end

					list.insert(base_list, 1, base.Base)
				end

				for _, v in ipairs(base_list) do
					local base = prototype.registered[v]

					-- the base might not be registered yet
					-- however this will be run again once it actually is
					if base then
						for k, v in pairs(base) do
							copy[k] = v

							if k == "prototype_variables" then
								for k, v in pairs(v) do
									prototype_variables[k] = v
								end
							end
						end
					end
				end
			end

			-- finally the actual metatable
			for k, v in pairs(meta) do
				copy[k] = v

				if k == "prototype_variables" then
					for k, v in pairs(v) do
						prototype_variables[k] = v
					end
				end
			end

			do
				local tbl = {}

				for _, info in pairs(prototype_variables) do
					if info.copy then list.insert(tbl, info) end
				end

				copy.copy_variables = tbl[1] and tbl
			end

			if copy.__index2 then
				copy.__index = function(s, k)
					return copy[k] or copy.__index2(s, k)
				end
			else
				copy.__index = copy
			end

			copy.BaseClass = prototype.registered[base_list[#base_list]]
			meta.BaseClass = copy.BaseClass
			prototype.prepared_metatables[type_name] = copy
		end
	end
end

function prototype.GetRegistered(type_name)
	if prototype.registered[type_name] then
		if prototype.invalidate_meta[type_name] then
			prototype.RebuildMetatables(type_name)
		end

		return prototype.prepared_metatables[type_name]
	end
end

function prototype.GetRegisteredSubTypes(super_type)
	return {prototype.registered[super_type]}
end

function prototype.GetAllRegistered()
	local out = {}

	for _, meta in pairs(prototype.registered) do
		list.insert(out, meta)
	end

	return out
end

local function remove_callback(self)
	if (not self.IsValid or self:IsValid()) and self.Remove then self:Remove() end

	if prototype.created_objects then prototype.created_objects[self] = nil end
end

function prototype.OverrideCreateObjectTable(obj)
	prototype.override_object = obj
end

do
	local DEBUG = DEBUG or DEBUG_OPENGL
	local setmetatable = setmetatable
	local type = type
	local ipairs = ipairs
	prototype.created_objects = prototype.created_objects or table.weak()

	function prototype.CreateObject(meta, override)
		override = override or prototype.override_object or {}

		if type(meta) == "string" then
			local str = meta
			meta = prototype.GetRegistered(meta)

			if not meta then error("Unable to find prototype: " .. str, 2) end
		end

		-- this has to be done in order to ensure we have the prepared metatable with bases
		meta = prototype.GetRegistered(meta.Type) or meta

		if not meta.__gc then meta.__gc = remove_callback end

		local self = setmetatable(override, meta)

		if meta.copy_variables then
			for _, info in ipairs(meta.copy_variables) do
				self[info.var_name] = info.copy()
			end
		end

		prototype.created_objects[self] = self

		if DEBUG then
			self:SetDebugTrace(debug.traceback())
			self:SetCreationTime(system and system.GetElapsedTime and system.GetElapsedTime() or os.clock())
		end

		return self
	end
end

do
	prototype.linked_objects = prototype.linked_objects or {}

	function prototype.AddPropertyLink(...)
		local args = table.weak()
		local input = {...}

		for i = 1, select("#", ...) do
			args[i] = input[i]
		end

		event.AddListener("Update", "update_object_properties", function()
			for i, data in ipairs(prototype.linked_objects) do
				if type(data.args[1]) == "table" and type(data.args[2]) == "table" then
					local obj_a = data.args[1]
					local obj_b = data.args[2]
					local field_a = data.args[3]
					local field_b = data.args[4]
					local key_a = data.args[5]
					local key_b = data.args[6]

					if obj_a:IsValid() and obj_b:IsValid() then
						local info_a = obj_a.prototype_variables[field_a]
						local info_b = obj_b.prototype_variables[field_b]

						if info_a and info_b then
							if key_a and key_b then
								-- local val = a:GeFieldA().key_a
								-- val.key_a = b:GetFieldB().key_b
								-- a:SetFieldA(val)
								local val = obj_a[info_a.get_name](obj_a)
								val[key_a] = obj_b[info_b.get_name](obj_b)[key_b]

								if data.store.last_val ~= val then
									obj_a[info_a.set_name](obj_a, val)
									data.store.last_val = val
								end
							elseif key_a and not key_b then
								-- local val = a:GeFieldA()
								-- val.key_a = b:GetFieldB()
								-- a:SetFieldA(val)
								local val = obj_a[info_a.get_name](obj_a)
								val[key_a] = obj_b[info_b.get_name](obj_b)

								if data.store.last_val ~= val then
									obj_a[info_a.set_name](obj_a, val)
									data.store.last_val = val
								end
							elseif key_b and not key_a then
								-- local val = b:GeFieldB().key_b
								-- a:SetFieldA(val)
								local val = obj_b[info_b.get_name](obj_b)[key_b]

								if data.store.last_val ~= val then
									obj_a[info_a.set_name](obj_a, val)
									data.store.last_val = val
								end
							else
								-- local val = b:GeFieldB()
								-- a:SetFieldA(val)
								local val = obj_b[info_b.get_name](obj_b)

								if data.store.last_val ~= val then
									obj_a[info_a.set_name](obj_a, val)
									data.store.last_val = val
								end
							end
						end

						if not info_b then
							wlog("unable to find property info for %s (%s)", field_b, obj_b)
						end
					else
						list.remove(prototype.linked_objects, i)

						break
					end
				elseif type(data.args[2]) == "function" and type(data.args[3]) == "function" then
					local obj = data.args[1]
					local get_func = data.args[2]
					local set_func = data.args[3]

					if obj:IsValid() then
						local val = get_func()

						if data.store.last_val ~= val then
							set_func(val)
							data.store.last_val = val
						end
					end
				end
			end
		end)

		list.insert(prototype.linked_objects, {store = table.weak(), args = args})
	end

	function prototype.RemovePropertyLink(obj_a, obj_b, field_a, field_b, key_a, key_b)
		for i, v in ipairs(prototype.linked_objects) do
			local obj_a_, obj_b_, field_a_, field_b_, key_a_, key_b_ = unpack(v)

			if
				obj_a == obj_a_ and
				obj_b == obj_b_ and
				field_a == field_a_ and
				field_b == field_b_ and
				key_a == key_a_ and
				key_b == key_b_
			then
				list.remove(prototype.linked_objects, i)

				break
			end
		end
	end

	function prototype.RemovePropertyLinks(obj)
		for i, v in pairs(prototype.linked_objects) do
			if v.args[1] == obj or v.args[2] == obj then
				prototype.linked_objects[i] = nil
			end
		end

		list.fix_indices(prototype.linked_objects)
	end

	function prototype.GetPropertyLinks(obj)
		local out = {}

		for _, v in ipairs(prototype.linked_objects) do
			if v.args[1] == obj or v.args[2] == obj then
				list.insert(out, {unpack(v.args)})
			end
		end

		return out
	end
end

function prototype.SafeRemove(obj)
	if has_index(obj) and obj.IsValid and obj.Remove and obj:IsValid() then
		obj:Remove()
	end
end

function prototype.GetCreated(sorted, type_name)
	if sorted then
		local out = {}

		for _, v in pairs(prototype.created_objects) do
			if not type_name or v.Type == type_name then list.insert(out, v) end
		end

		list.sort(out, function(a, b)
			return a:GetCreationTime() < b:GetCreationTime()
		end)

		return out
	end

	return prototype.created_objects or {}
end

function prototype.FindObject(str)
	local name, property = str:match("(.-):(.+)")

	if not name then name = str end

	local objects = prototype.GetCreated()
	local found

	local function try(compare)
		for obj in pairs(objects) do
			if compare(obj) then
				found = obj
				return true
			end
		end
	end

	local function find_property(obj)
		if not property then return true end

		for _, v in pairs(prototype.GetStorableVariables(obj)) do
			if tostring(obj[v.get_name](obj)):compare(property) then return true end
		end
	end

	if try(function(obj)
		return obj:GetName() == name and find_property(obj)
	end) then
		return found
	end

	if
		try(function(obj)
			return obj:GetName():compare(name) and find_property(obj)
		end)
	then
		return found
	end

	if try(function(obj)
		return obj.Type == name and find_property(obj)
	end) then
		return found
	end

	if try(function(obj)
		return obj.Type:compare(name) and find_property(obj)
	end) then
		return found
	end
end

function prototype.UpdateObjects(meta)
	if type(meta) == "string" then meta = prototype.GetRegistered(meta) end

	if not meta then return end

	for _, obj in pairs(prototype.GetCreated()) do
		if obj.Type == meta.Type then
			if HOTRELOAD then
				if obj.OnReload then obj:OnReload() end

				for k, v in pairs(meta) do
					if type(v) == "function" then
						if
							type(obj[k]) == "function" and
							debug.getinfo(v).source ~= debug.getinfo(obj[k]).source and
							#string.dump(v) < #string.dump(obj[k])
						then
							llog(
								"not overriding smaller function %s:%s(%s)",
								meta.Type,
								k,
								list.concat_member(debug.get_upvalues(v), "key", ", ")
							)
						else
							obj[k] = v
						end
					elseif obj[k] == nil then
						obj[k] = v
					end
				end
			else
				for k, v in pairs(meta) do
					if type(v) == "function" then obj[k] = v end
				end
			end
		end
	end
end

function prototype.RemoveObjects(type_name)
	for _, obj in pairs(prototype.GetCreated()) do
		if obj.Type == type_name then if obj:IsValid() then obj:Remove() end end
	end
end

function prototype.DumpObjectCount()
	local found = {}

	for obj in pairs(prototype.GetCreated()) do
		local name = obj.Type
		found[name] = (found[name] or 0) + 1
	end

	local sorted = {}

	for k, v in pairs(found) do
		list.insert(sorted, {k = k, v = v})
	end

	list.sort(sorted, function(a, b)
		return a.v > b.v
	end)

	for _, v in ipairs(sorted) do
		logn(v.k, " = ", v.v)
	end
end

do -- get is set
	local __store = false
	local __meta

	function prototype.StartStorable(meta)
		__store = true
		__meta = meta
	end

	function prototype.EndStorable()
		__store = false
		__meta = nil
	end

	function prototype.GetStorableVariables(meta)
		return meta.storable_variables or {}
	end

	function prototype.DelegateProperties(meta, from, var_name, callback)
		meta[var_name] = NULL

		for _, info in pairs(prototype.GetStorableVariables(from)) do
			if not meta[info.var_name] then
				prototype.SetupProperty(
					{
						meta = meta,
						var_name = info.var_name,
						default = info.default,
						set_name = info.set_name,
						get_name = info.get_name,
					}
				)

				if callback then
					meta[info.set_name] = function(self, var)
						self[info.var_name] = var

						if self[var_name]:IsValid() then
							self[var_name][info.set_name](self[var_name], var)
						end

						self[callback](self, var)
					end
				else
					meta[info.set_name] = function(self, var)
						self[info.var_name] = var

						if self[var_name]:IsValid() then
							self[var_name][info.set_name](self[var_name], var)
						end
					end
				end

				meta[info.get_name] = function(self)
					if self[var_name]:IsValid() then
						return self[var_name][info.get_name](self[var_name])
					end

					return self[info.var_name]
				end
			end
		end
	end

	local function has_copy(obj)
		assert(type(obj.__copy) == "function")
	end

	function prototype.SetupProperty(info)
		local meta = info.meta or __meta
		local default = info.default
		local name = info.var_name
		local set_name = info.set_name
		local get_name = info.get_name
		local callback = info.callback

		if type(default) == "number" then
			if callback then
				meta[set_name] = meta[set_name] or
					function(self, var)
						self[name] = tonumber(var) or default
						self[callback](self)
					end
			else
				meta[set_name] = meta[set_name] or
					function(self, var)
						self[name] = tonumber(var) or default
					end
			end

			meta[get_name] = meta[get_name] or function(self)
				return self[name] or default
			end
		elseif type(default) == "string" then
			if callback then
				meta[set_name] = meta[set_name] or
					function(self, var)
						self[name] = tostring(var)
						self[callback](self)
					end
			else
				meta[set_name] = meta[set_name] or function(self, var)
					self[name] = tostring(var)
				end
			end

			meta[get_name] = meta[get_name] or
				function(self)
					if self[name] ~= nil then return self[name] end

					return default
				end
		else
			if callback then
				meta[set_name] = meta[set_name] or
					function(self, var)
						if var == nil then var = default end

						self[name] = var
						self[callback](self)
					end
			else
				meta[set_name] = meta[set_name] or
					function(self, var)
						if var == nil then var = default end

						self[name] = var
					end
			end

			meta[get_name] = meta[get_name] or
				function(self)
					if self[name] ~= nil then return self[name] end

					return default
				end
		end

		meta[name] = default

		if __store then
			info.type = type(default)
			meta.storable_variables = meta.storable_variables or {}
			list.insert(meta.storable_variables, info)
		end

		do
			if pcall(has_copy, info.default) then
				info.copy = function()
					return info.default:__copy()
				end
			elseif type(info.default) == "table" then
				if not next(info.default) then
					info.copy = function()
						return {}
					end
				else
					info.copy = function()
						return table.copy(info.default)
					end
				end
			end

			meta.prototype_variables = meta.prototype_variables or {}
			meta.prototype_variables[info.var_name] = info
		end

		return info
	end

	local function add(meta, name, default, extra_info, get)
		local info = {
			meta = meta,
			default = default,
			var_name = name,
			set_name = "Set" .. name,
			get_name = get .. name,
		}

		if extra_info then
			if list.is_list(extra_info) and #extra_info > 1 then
				extra_info = {enums = extra_info}
			end

			table.merge(info, extra_info)
		end

		return prototype.SetupProperty(info)
	end

	function prototype.GetSet(meta, name, default, extra_info)
		if type(meta) == "string" and __meta then
			return add(__meta, meta, name, default, "Get")
		else
			return add(meta, name, default, extra_info, "Get")
		end
	end

	function prototype.IsSet(meta, name, default, extra_info)
		if type(meta) == "string" and __meta then
			return add(__meta, meta, name, default, "Is")
		else
			return add(meta, name, default, extra_info, "Is")
		end
	end

	function prototype.Delegate(meta, key, func_name, func_name2)
		if not func_name2 then func_name2 = func_name end

		meta[func_name] = function(self, ...)
			return self[key][func_name2](self[key], ...)
		end
	end

	function prototype.GetSetDelegate(meta, func_name, def, key)
		local get = "Get" .. func_name
		local set = "Set" .. func_name
		local info = prototype.GetSet(meta, func_name, def)
		prototype.Delegate(meta, key, get)
		prototype.Delegate(meta, key, set)
		return info
	end

	function prototype.RemoveField(meta, name)
		meta["Set" .. name] = nil
		meta["Get" .. name] = nil
		meta["Is" .. name] = nil
		meta[name] = nil
	end
end

do -- base object
	local META = {}
	prototype.GetSet(META, "DebugTrace", "")
	prototype.GetSet(META, "CreationTime", os.clock())
	prototype.GetSet(META, "PropertyIcon", "")
	prototype.GetSet(META, "HideFromEditor", false)
	prototype.GetSet(META, "GUID", "")
	prototype.StartStorable(META)
	prototype.GetSet("Name", "")
	prototype.GetSet("Description", "")
	prototype.EndStorable()

	function META:GetGUID()
		self.GUID = self.GUID or ("%p%p"):format(self, getmetatable(META))
		return self.GUID
	end

	function META:GetEditorName()
		if self.Name == "" then return self.EditorName or "" end

		return self.Name
	end

	function META:__tostring()
		local additional_info = self:__tostring2()

		if self.Name ~= "" then
			return ("%s[%s]%s"):format(self.Type, self.Name, additional_info)
		else
			return ("%s[%p]%s"):format(self.Type, self, additional_info)
		end
	end

	function META:__tostring2()
		return ""
	end

	function META:IsValid()
		return not self.__removed
	end

	do
		prototype.remove_these = prototype.remove_these or {}
		local event_added = false

		function META:Remove(...)
			if self.__removed then return end

			if self.call_on_remove then
				for _, v in pairs(self.call_on_remove) do
					if v(self) == false then return end
				end
			end

			if self.added_events then
				for event in pairs(self.added_events) do
					self:RemoveEvent(event)
				end
			end

			if self.OnRemove then self:OnRemove(...) end

			if not event_added and event then
				event.AddListener("Update", "prototype_remove_objects", function()
					if #prototype.remove_these > 0 then
						for _, obj in ipairs(prototype.remove_these) do
							prototype.created_objects[obj] = nil
							prototype.MakeNULL(obj)
						end

						list.clear(prototype.remove_these)
					end
				end)

				event_added = true
			end

			list.insert(prototype.remove_these, self)
			self.__removed = true
		end
	end

	do -- serializing
		local callbacks = {}

		function META:SetStorableTable(tbl)
			self:SetGUID(tbl.GUID)

			if self.OnDeserialize then self:OnDeserialize(tbl.__extra_data) end

			for _, info in ipairs(prototype.GetStorableVariables(self)) do
				if tbl[info.var_name] ~= nil then
					self[info.set_name](self, tbl[info.var_name])
				end
			end

			if tbl.__property_links then
				for _, v in ipairs(tbl.__property_links) do
					self:WaitForGUID(v[1], function(obj)
						v[1] = obj

						self:WaitForGUID(v[2], function(obj)
							v[2] = obj
							prototype.AddPropertyLink(unpack(v))
						end)
					end)
				end
			end
		end

		function META:GetStorableTable()
			local out = {}

			for _, info in ipairs(prototype.GetStorableVariables(self)) do
				out[info.var_name] = self[info.get_name](self)
			end

			out.GUID = self.GUID
			local info = prototype.GetPropertyLinks(self)

			if next(info) then
				for _, v in ipairs(info) do
					v[1] = v[1].GUID
					v[2] = v[2].GUID
				end

				out.__property_links = info
			end

			if self.OnSerialize then out.__extra_data = self:OnSerialize() end

			return table.copy(out)
		end

		function META:SetGUID(guid)
			prototype.created_objects_guid = prototype.created_objects_guid or table.weak()

			if prototype.created_objects_guid[self.GUID] then
				prototype.created_objects_guid[self.GUID] = nil
			end

			self.GUID = guid
			prototype.created_objects_guid[self.GUID] = self

			if callbacks[self.GUID] then
				for _, cb in ipairs(callbacks[self.GUID]) do
					cb(self)
				end

				callbacks[self.GUID] = nil
			end
		end

		function META:WaitForGUID(guid, callback)
			local obj = prototype.GetObjectByGUID(guid)

			if obj:IsValid() then
				callback(obj)
			else
				callbacks[guid] = callbacks[guid] or {}
				list.insert(callbacks[guid], callback)
				print("added callback for ", guid)
			end
		end

		function prototype.GetObjectByGUID(guid)
			prototype.created_objects_guid = prototype.created_objects_guid or table.weak()
			return prototype.created_objects_guid[guid] or NULL
		end
	end

	function META:AddLocalListener(what, callback, id)
		id = id or callback
		self.local_events = self.local_events or {}
		self.local_events[what] = self.local_events[what] or {}
		self.local_events[what][id] = callback
		return function(...)
			self.local_events[what][id] = nil
		end
	end

	function META:CallLocalListeners(what, ...)
		if self.local_events and self.local_events[what] then
			for _, callback in pairs(self.local_events[what]) do
				callback(self, ...)
			end
		end
	end

	function META:CallOnRemove(callback, id)
		id = id or callback

		if type(callback) == "table" and callback.Remove then
			callback = function()
				prototype.SafeRemove(callback)
			end
		end

		self.call_on_remove = self.call_on_remove or {}
		self.call_on_remove[id] = callback
	end

	do -- events
		local events = {}

		function META:AddEvent(event_type)
			self.added_events = self.added_events or {}

			if self.added_events[event_type] then return end

			local func_name = "On" .. event_type
			events[event_type] = events[event_type] or table.weak()
			list.insert(events[event_type], self)

			event.AddListener(
				event_type,
				"prototype_events",
				function(a_, b_, c_)
					--for _, self in ipairs(events[event_type]) do
					for i = 1, #events[event_type] do
						local self = events[event_type][i]

						if self then
							if self[func_name] then
								self[func_name](self, a_, b_, c_)
							else
								wlog("%s.%s is nil", self, func_name)
								self:RemoveEvent(event_type)
							end
						end
					end
				end,
				{
					on_error = function(str)
						traceback.OnError(str)
						self:RemoveEvent(event_type)
					end,
				}
			)

			self.added_events[event_type] = true
		end

		function META:RemoveEvent(event_type)
			self.added_events = self.added_events or {}

			if not self.added_events[event_type] then return end

			events[event_type] = events[event_type] or table.weak()

			for i, other in pairs(events[event_type]) do
				if other == self then
					events[event_type][i] = nil

					break
				end
			end

			list.fix_indices(events[event_type])
			self.added_events[event_type] = nil

			if #events[event_type] <= 0 then
				event.RemoveListener(event_type, "prototype_events")
			end
		end

		prototype.added_events = events
	end

	prototype.base_metatable = META
end

do
	do
		local NULL = {}
		NULL.Type = "null"
		NULL.IsNull = true

		local function FALSE()
			return false
		end

		function NULL:IsValid()
			return false
		end

		function NULL:__tostring()
			return "NULL"
		end

		function NULL:__copy()
			return self
		end

		function NULL:__index2(key)
			if type(key) == "string" and key:sub(0, 2) == "Is" then return FALSE end
		--error(("tried to index %q on a NULL value"):format(key), 2)
		end

		prototype.Register(NULL)
	end

	function prototype.MakeNULL(tbl)
		table.clear(tbl)
		tbl.Type = "null"
		setmetatable(tbl, prototype.GetRegistered("null"))

		if prototype.created_objects then prototype.created_objects[tbl] = nil end
	end

	_G.NULL = setmetatable({Type = "null"}, prototype.GetRegistered("null"))
end

do -- pool
	local list_remove = list.remove

	function prototype.CreateObjectPool(name)
		return {
			i = 1,
			list = {},
			map = {},
			remove = function(self, obj)
				if not self.map[obj] then
					error("tried to remove non existing object in pool " .. name, 2)
				end

				for i = 1, self.i do
					if obj == self.list[i] then
						list_remove(self.list, i)
						self.map[obj] = nil
						self.i = self.i - 1

						break
					end
				end

				if self.map[obj] then
					error("unable to remove " .. tostring(obj) .. " from pool " .. name)
				end
			end,
			insert = function(self, obj)
				if self.map[obj] then
					error("tried to add existing object to pool " .. name, 2)
				end

				self.list[self.i] = obj
				self.map[obj] = self.i
				self.i = self.i + 1
			end,
			call = function(self, func_name, ...)
				for _, obj in ipairs(self.list) do
					if obj[func_name] then obj[func_name](obj, ...) end
				end
			end,
		}
	end
end

-- parenting
function prototype.ParentingTemplate(META)
	META.OnParent = META.OnParent or function() end
	META.OnChildAdd = META.OnChildAdd or function() end
	META.OnChildRemove = META.OnChildRemove or function() end
	META.OnUnParent = META.OnUnParent or function() end
	META:GetSet("Parent", NULL)
	META:GetSet("Children", {})
	META:GetSet("ChildrenMap", {})
	META:GetSet("ChildOrder", 0)

	do -- children
		function META:GetChildren()
			return self.Children
		end

		local function add_recursive(obj, tbl, index)
			local source = obj.Children

			for i = 1, #source do
				tbl[index] = source[i]
				index = index + 1
				index = add_recursive(source[i], tbl, index)
			end

			return index
		end

		function META:GetChildrenList()
			if not self.children_list then
				local tbl = {}
				add_recursive(self, tbl, 1)
				self.children_list = tbl
			end

			return self.children_list
		end

		function META:InvalidateChildrenList()
			self.children_list = nil

			for _, parent in ipairs(self:GetParentList()) do
				parent.children_list = nil
			end
		end
	end

	do -- parent
		function META:SetParent(obj)
			if not obj or not obj:IsValid() then
				self:UnParent()
				return false
			else
				return obj:AddChild(self)
			end
		end

		function META:ContainsParent(obj)
			for _, v in ipairs(self:GetParentList()) do
				if v == obj then return true end
			end
		end

		local function quick_copy(input)
			local output = {}

			for i = 1, #input do
				output[i + 1] = input[i]
			end

			return output
		end

		function META:GetParentList()
			if not self.parent_list then
				if self.Parent and self.Parent:IsValid() then
					self.parent_list = quick_copy(self.Parent:GetParentList())
					self.parent_list[1] = self.Parent
				else
					self.parent_list = {}
				end
			end

			return self.parent_list
		end

		function META:InvalidateParentList()
			self.parent_list = nil

			for _, child in ipairs(self:GetChildrenList()) do
				child.parent_list = nil
			end
		end

		function META:InvalidateParentListPartial(parent_list, parent)
			self.parent_list = quick_copy(parent_list)
			self.parent_list[1] = parent

			for _, child in ipairs(self:GetChildren()) do
				child:InvalidateParentListPartial(self.parent_list, self)
			end
		end
	end

	function META:AddChild(obj, pos)
		if not obj.HasParent then for k, v in pairs(obj) do
			print(k, v)
		end end

		if not obj or not obj:IsValid() then
			self:UnParent()
			return
		end

		if self == obj or self:ContainsParent(obj) then return false end

		if obj:HasParent() then obj:UnParent() end

		obj.Parent = self

		if not self:HasChild(obj) then
			self.ChildrenMap[obj] = obj

			if pos then
				list.insert(self.Children, pos, obj)
			else
				list.insert(self.Children, obj)
			end
		end

		self:InvalidateChildrenList()
		obj:OnParent(self)

		if not obj.suppress_child_add then
			obj.suppress_child_add = true
			self:OnChildAdd(obj)
			obj.suppress_child_add = nil
		end

		if self:HasParent() then self:GetParent():SortChildren() end

		-- why would we need to sort obj's children
		-- if it is completely unmodified?
		obj:SortChildren()
		self:SortChildren()
		obj:InvalidateParentListPartial(self:GetParentList(), self)
		return true
	end

	do
		local function sort(a, b)
			return a.ChildOrder < b.ChildOrder
		end

		function META:SortChildren() -- todo
		--table.sort(self.Children, sort)
		--self:InvalidateChildrenList()
		end
	end

	function META:HasParent()
		return self.Parent:IsValid()
	end

	function META:HasChildren()
		return self.Children[1] ~= nil
	end

	function META:HasChild(obj)
		return self.ChildrenMap[obj] ~= nil
	end

	function META:GetRoot()
		local list = self:GetParentList()

		if list[1] then return list[#list] end

		return self
	end

	function META:RemoveChildren()
		self:InvalidateChildrenList()
		local children = self:GetChildren()

		for i = #children, 1, -1 do
			local obj = children[i]
			obj:Remove()
		end

		self.Children = {}
		self.ChildrenMap = {}
	end

	function META:UnParent()
		local parent = self:GetParent()

		if parent:IsValid() then
			parent:RemoveChild(self)
		else
			if self.Parent ~= NULL then
				self.Parent = NULL
				self:InvalidateParentList()
				self:OnUnParent(parent)
			end
		end
	end

	function META:RemoveChild(obj)
		if self.ChildrenMap[obj] == nil then return end

		self.ChildrenMap[obj] = nil

		for i, val in ipairs(self.Children) do
			if val == obj then
				table.remove(self.Children, i)
				self:InvalidateChildrenList()
				obj.Parent = NULL
				obj:InvalidateParentList()
				obj:OnUnParent(self)
				self:OnChildRemove(obj)

				break
			end
		end
	end

	do
		function META:CallRecursive(func, a, b, c)
			assert(c == nil, "EXTEND ME")

			if self[func] then self[func](self, a, b, c) end

			for _, child in ipairs(self:GetChildrenList()) do
				if child[func] then child[func](child, a, b, c) end
			end
		end

		function META:CallRecursiveOnType(type_name, func, a, b, c)
			assert(c == nil, "EXTEND ME")

			if self[func] and self.Type == type_name then
				self[func](self, a, b, c)
			end

			for _, child in ipairs(self:GetChildrenList()) do
				if child[func] and self.Type == type_name then
					child[func](child, a, b, c)
				end
			end
		end

		function META:SetKeyValueRecursive(key, val)
			self[key] = val

			for _, child in ipairs(self:GetChildrenList()) do
				child[key] = val
			end
		end
	end
end

return prototype
