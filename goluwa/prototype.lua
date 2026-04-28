local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local traceback = import("goluwa/helpers/traceback.lua")
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
		if not HOTERLOAD then
			if prototype.registered[meta.Type] then
				wlog("Prototype already registered: " .. meta.Type, 2)
			end
		end

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

		meta.Instances = meta.Instances or table.weak()
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
			copy.prototype_variables = prototype_variables
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
	prototype.created_objects_list = prototype.created_objects_list or {}

	function prototype.CreateObject(meta, override)
		override = override or prototype.override_object or {}

		if type(meta) == "string" then
			debug.trace()
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

		if not meta.Instances then meta.Instances = table.weak() end

		if self.OnFirstCreated and not meta.Instances[1] then
			self:OnFirstCreated()
		end

		prototype.created_objects[self] = self
		list.insert(meta.Instances, self)

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
		local args = {...}
		args.n = select("#", ...)

		event.AddListener("Update", "update_object_properties", function()
			for i = #prototype.linked_objects, 1, -1 do
				local data = prototype.linked_objects[i]

				if type(data.args[1]) == "table" and type(data.args[2]) == "table" then
					local obj_a = data.args[1]
					local obj_b = data.args[2]
					local field_a = data.args[3]
					local field_b = data.args[4]
					local key_a = data.args[5]
					local key_b = data.args[6]

					if obj_a:IsValid() and obj_b:IsValid() then
						local info_a = obj_a.prototype_variables and obj_a.prototype_variables[field_a]
						local info_b = obj_b.prototype_variables and obj_b.prototype_variables[field_b]

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
					else
						list.remove(prototype.linked_objects, i)
					end
				end
			end
		end)

		list.insert(prototype.linked_objects, {store = table.weak(), args = args})
	end

	function prototype.RemovePropertyLink(obj_a, obj_b, field_a, field_b, key_a, key_b)
		for i, v in ipairs(prototype.linked_objects) do
			local a = v.args

			if
				a[1] == obj_a and
				a[2] == obj_b and
				a[3] == field_a and
				a[4] == field_b and
				a[5] == key_a and
				a[6] == key_b
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

do
	prototype.focused_obj = NULL

	function prototype.SetFocusedObject(obj)
		if obj.Owner and obj.Owner:IsValid() then
			return prototype.SetFocusedObject(obj.Owner)
		end

		if prototype.focused_obj == obj then return end

		local old = prototype.focused_obj

		if old and old:IsValid() then if old.OnUnfocus then old:OnUnfocus() end end

		prototype.focused_obj = obj

		if obj and obj:IsValid() then if obj.OnFocus then obj:OnFocus() end end
	end

	function prototype.GetFocusedObject()
		return prototype.focused_obj
	end
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

	function prototype.GetPropertyInfo(meta, name)
		if meta.prototype_variables then return meta.prototype_variables[name] end
	end

	local function is_list_property(info)
		return info.compare == "list" or info.list_type or info.list_enums or info.list_length
	end

	local function list_equals(a, b)
		if a == b then return true end

		if type(a) ~= "table" or type(b) ~= "table" then return false end

		for i = 1, math.max(#a, #b) do
			if a[i] ~= b[i] then return false end
		end

		return true
	end

	local function get_expected_description(info)
		if info.validate == "boolean" then return "boolean" end

		if info.validate == "number" then return "number" end

		if info.validate == "integer" then return "integer" end

		if info.validate == "string" then return "string" end

		if info.enums then return "one of: " .. table.concat(info.enums, ", ") end

		if is_list_property(info) then
			local parts = {"list"}

			if info.list_length then list.insert(parts, "length " .. info.list_length) end

			if info.list_type then
				list.insert(parts, "values of type " .. info.list_type)
			end

			if info.list_enums then
				list.insert(parts, "values in: " .. table.concat(info.list_enums, ", "))
			end

			return list.concat(parts, ", ")
		end

		return info.type or "valid value"
	end

	local function validation_error(info, value, level)
		error(
			string.format(
				"property %q: expected %s, got %s",
				info.var_name,
				get_expected_description(info),
				type(value) == "string" and string.format("%q", value) or tostring(value)
			),
			level or 2
		)
	end

	local function validate_scalar(info, value, level)
		if info.validate == "boolean" then
			if type(value) ~= "boolean" then validation_error(info, value, level) end
		elseif info.validate == "number" then
			if type(value) ~= "number" then validation_error(info, value, level) end
		elseif info.validate == "integer" then
			if type(value) ~= "number" or value % 1 ~= 0 then
				validation_error(info, value, level)
			end
		elseif info.validate == "string" then
			if type(value) ~= "string" then validation_error(info, value, level) end
		elseif type(info.validate) == "function" then
			local new_value = info.validate(value, info)

			if new_value ~= nil then value = new_value end
		end

		if info.enums and not info.enum_lookup[value] then
			validation_error(info, value, level)
		end

		return value
	end

	function prototype.ValidatePropertyValue(info, value, level)
		if value == nil then return nil end

		if is_list_property(info) then
			if type(value) ~= "table" then validation_error(info, value, level) end

			if info.list_length and #value ~= info.list_length then
				validation_error(info, value, level)
			end

			for i = 1, #value do
				local item = value[i]

				if info.list_type and type(item) ~= info.list_type then
					validation_error(info, item, level)
				end

				if info.list_enums and not info.list_enum_lookup[item] then
					validation_error(info, item, level)
				end
			end

			return value
		end

		return validate_scalar(info, value, level)
	end

	function prototype.ComparePropertyValues(info, a, b)
		if info and info.compare == "list" then return list_equals(a, b) end

		return a == b
	end

	local function notify_property_listeners(self, info, old_value, new_value)
		local listeners = self.property_change_listeners

		if not listeners then return end

		if listeners.any then
			for _, callback in pairs(listeners.any) do
				callback(self, info.var_name, new_value, old_value, info)
			end
		end

		if listeners.by_name and listeners.by_name[info.var_name] then
			for _, callback in pairs(listeners.by_name[info.var_name]) do
				callback(self, info.var_name, new_value, old_value, info)
			end
		end
	end

	local function get_type(val)
		local t = type(val)

		if (t == "table" or t == "userdata" or t == "cdata") and val.Type then
			return val.Type
		end

		return t
	end

	function prototype.CommitProperty(obj, key, value)
		local info = prototype.GetPropertyInfo(getmetatable(obj), key)

		if info and info.commit then
			info.commit(obj, value)
			return true
		end

		return false
	end

	function prototype.SetProperty(obj, key, value)
		local info = prototype.GetPropertyInfo(getmetatable(obj), key)

		if info then
			if
				info.validate or
				info.enums or
				info.list_type or
				info.list_enums or
				info.list_length
			then
				value = prototype.ValidatePropertyValue(info, value, 2)
			end

			if info.type ~= "nil" and value ~= nil then
				local actual_type = get_type(value)

				if actual_type ~= info.type then
					if not (info.type == "number" and tonumber(value)) then
						error(
							string.format(
								"%s: property %q: expected %s, got %s",
								obj.Type or "unknown",
								key,
								info.type,
								actual_type
							),
							2
						)
					end
				end
			end

			obj[info.set_name](obj, value)
			return true
		end

		local setter = "Set" .. key

		if obj[setter] then
			obj[setter](obj, value)
			return true
		end

		return false
	end

	function prototype.GetProperty(obj, key)
		local info = prototype.GetPropertyInfo(getmetatable(obj), key)

		if info then return obj[info.get_name](obj) end

		local getter = "Get" .. key

		if obj[getter] then return obj[getter](obj) end

		local is_getter = "Is" .. key

		if obj[is_getter] then return obj[is_getter](obj) end

		return obj[key]
	end

	function prototype.DelegateProperties(meta, from, var_name, callback)
		meta[var_name] = NULL

		for _, info in pairs(prototype.GetStorableVariables(from)) do
			if not meta[info.var_name] then
				prototype.SetupProperty{
					meta = meta,
					var_name = info.var_name,
					default = info.default,
					set_name = info.set_name,
					get_name = info.get_name,
				}

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
		local has_validation = info.validate or
			info.enums or
			info.list_type or
			info.list_enums or
			info.list_length

		if type(default) == "number" then
			local function commit(self, var)
				if has_validation then
					if var == nil then
						var = default
					else
						var = prototype.ValidatePropertyValue(info, var, 2)
					end
				else
					var = tonumber(var) or default
				end

				local listeners = self.property_change_listeners

				if (callback or listeners) and prototype.ComparePropertyValues(info, self[name], var) then
					return
				end

				local old_value = self[name]
				self[name] = var

				if callback then self[callback](self) end

				if listeners then notify_property_listeners(self, info, old_value, var) end
			end

			info.commit = commit

			if has_validation then
				meta[set_name] = meta[set_name] or commit
			elseif callback then
				meta[set_name] = meta[set_name] or commit
			else
				meta[set_name] = meta[set_name] or commit
			end

			meta[get_name] = meta[get_name] or function(self)
				return self[name] or default
			end
		elseif type(default) == "string" then
			local function commit(self, var)
				if has_validation then
					if var == nil then
						var = default
					else
						var = prototype.ValidatePropertyValue(info, var, 2)
					end
				else
					var = tostring(var)
				end

				local listeners = self.property_change_listeners

				if (callback or listeners) and prototype.ComparePropertyValues(info, self[name], var) then
					return
				end

				local old_value = self[name]
				self[name] = var

				if callback then self[callback](self) end

				if listeners then notify_property_listeners(self, info, old_value, var) end
			end

			info.commit = commit

			if has_validation then
				meta[set_name] = meta[set_name] or commit
			elseif callback then
				meta[set_name] = meta[set_name] or commit
			else
				meta[set_name] = meta[set_name] or commit
			end

			meta[get_name] = meta[get_name] or
				function(self)
					if self[name] ~= nil then return self[name] end

					return default
				end
		else
			local function commit(self, var)
				if has_validation then
					if var == nil then
						var = default
					else
						var = prototype.ValidatePropertyValue(info, var, 2)
					end
				else
					if var == nil then var = default end
				end

				local listeners = self.property_change_listeners

				if (callback or listeners) and prototype.ComparePropertyValues(info, self[name], var) then
					return
				end

				local old_value = self[name]
				self[name] = var

				if callback then self[callback](self) end

				if listeners then notify_property_listeners(self, info, old_value, var) end
			end

			info.commit = commit

			if has_validation then
				meta[set_name] = meta[set_name] or commit
			elseif callback then
				meta[set_name] = meta[set_name] or commit
			else
				meta[set_name] = meta[set_name] or commit
			end

			meta[get_name] = meta[get_name] or
				function(self)
					if self[name] ~= nil then return self[name] end

					return default
				end
		end

		meta[name] = default
		info.type = info.type or get_type(default)

		if info.enums then
			info.enum_lookup = {}

			for _, v in ipairs(info.enums) do
				info.enum_lookup[v] = true
			end
		end

		if info.list_enums then
			info.list_enum_lookup = {}

			for _, v in ipairs(info.list_enums) do
				info.list_enum_lookup[v] = true
			end
		end

		if __store then
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
				elseif getmetatable(info.default) then
					wlog(
						"Default value for %s has a metatable, but does not have a __copy method. This may cause issues if multiple instances of the object are created.",
						info.var_name,
						2
					)
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
	prototype.GetSet(META, "Owner", nil)
	prototype.GetSet(META, "Key", "")
	prototype.StartStorable(META)
	prototype.GetSet(META, "Name", "")
	prototype.GetSet(META, "Description", "")
	prototype.EndStorable()

	function META:GetGUID()
		local guid = self.GUID

		if guid == nil or guid == "" then
			guid = ("%p%p"):format(self, getmetatable(META))
			self:SetGUID(guid)
			return guid
		end

		prototype.created_objects_guid = prototype.created_objects_guid or table.weak()

		if prototype.created_objects_guid[guid] ~= self then self:SetGUID(guid) end

		return self.GUID
	end

	function META:GetEditorName()
		if self.Name == "" then return self.EditorName or "" end

		return self.Name
	end

	function META:AddPropertyListener(callback, id)
		id = id or callback
		self.property_change_listeners = self.property_change_listeners or {}
		self.property_change_listeners.any = self.property_change_listeners.any or {}
		self.property_change_listeners.any[id] = callback
		return function()
			local listeners = self.property_change_listeners
			local any = listeners and listeners.any

			if not (any and any[id]) then return false end

			any[id] = nil

			if not next(any) then listeners.any = nil end

			if not next(listeners) then self.property_change_listeners = nil end

			return true
		end
	end

	function META:AddPropertyListenerFor(name, callback, id)
		id = id or callback
		self.property_change_listeners = self.property_change_listeners or {}
		self.property_change_listeners.by_name = self.property_change_listeners.by_name or {}
		self.property_change_listeners.by_name[name] = self.property_change_listeners.by_name[name] or {}
		self.property_change_listeners.by_name[name][id] = callback
		return function()
			local listeners = self.property_change_listeners
			local by_name = listeners and listeners.by_name
			local named = by_name and by_name[name]

			if not (named and named[id]) then return false end

			named[id] = nil

			if not next(named) then by_name[name] = nil end

			if not next(by_name) then listeners.by_name = nil end

			if not next(listeners) then self.property_change_listeners = nil end

			return true
		end
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

	do -- sub objects
		function META:CreateSubObject(meta, override)
			local obj = prototype.CreateObject(meta, override)
			obj:SetOwner(self)

			self:CallOnRemove(function()
				self.sub_objects[obj] = nil
				prototype.SafeRemove(obj)
			end)

			self.sub_objects = self.sub_objects or {}
			self.sub_objects[obj] = obj
			return obj
		end
	end

	function META:KeepApplicationAlive()
		self:CallOnRemove(system.KeepAlive(self))
	end

	function META:RequestFocus()
		prototype.SetFocusedObject(self)
	end

	do
		prototype.remove_these = prototype.remove_these or {}
		local event_added = false

		local function remove_from_instances(obj)
			if obj.__removed_from_instances then return end

			local instances = obj.Instances
			local removed = false

			if instances then
				for i, v in ipairs(instances) do
					if v == obj then
						list.remove(instances, i)
						removed = true

						break
					end
				end
			end

			obj.__removed_from_instances = true

			if removed and instances and not instances[1] and obj.OnLastRemoved then
				obj:OnLastRemoved()
			end
		end

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

			if self.local_event_removers then
				for remover in pairs(self.local_event_removers) do
					remover()
				end

				self.local_event_removers = nil
			end

			if self.OnRemove then self:OnRemove(...) end

			remove_from_instances(self)

			if not event_added and event then
				event.AddListener("Update", "prototype_remove_objects", prototype.CheckRemovedObjects)
				event_added = true
			end

			list.insert(prototype.remove_these, self)
			self.__removed = true
		end

		function prototype.CheckRemovedObjects()
			if #prototype.remove_these > 0 then
				for _, obj in ipairs(prototype.remove_these) do
					remove_from_instances(obj)
					prototype.created_objects[obj] = nil

					if prototype.created_objects_guid and obj.GUID ~= "" then
						prototype.created_objects_guid[obj.GUID] = nil
					end

					prototype.MakeNULL(obj)
				end

				list.clear(prototype.remove_these)
			end
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
		self.local_events = self.local_events or {}

		if not self.local_events[what] then
			if event.IsEvent(what) then
				self.local_events[what] = what
			else
				self.local_events[what] = event.UniqueEvent(what)
			end
		end

		local remover = event.AddListener(self.local_events[what], id or callback, callback, {self_arg = self})
		self.local_event_removers = self.local_event_removers or {}
		self.local_event_removers[remover] = true
		return function(...)
			if self.local_event_removers and self.local_event_removers[remover] then
				self.local_event_removers[remover] = nil
				return remover(...)
			end
		end
	end

	function META:CallLocalEvent(what, a, b, c, d, e, f, g)
		local ret = nil

		if self[what] then
			ret = self[what](self, a, b, c, d, e, f, g)

			if ret ~= nil then return ret end
		end

		if self.component_list then
			for _, component in ipairs(self.component_list) do
				if component[what] then
					ret = component[what](component, a, b, c, d, e, f, g)

					if ret ~= nil then return ret end
				end
			end
		end

		if self.local_events then
			local unique_event = self.local_events[what]

			if self[what] then event.SkipCallback(self[what]) end

			if unique_event then
				return event.Call(unique_event, a, b, c, d, e, f, g)
			elseif event.IsEvent(what) then
				return event.Call(what, a, b, c, d, e, f, g)
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
		local event_configs = {}

		function META:AddGlobalEvent(event_type, config)
			self.added_events = self.added_events or {}

			if self.added_events[event_type] then return end

			if not events[event_type] then
				events[event_type] = table.weak()
				event_configs[event_type] = config or {}
				local real_event_name = config and config.event_name or event_type
				local func_name = config and config.func_name or ("On" .. event_type)

				event.AddListener(
					real_event_name,
					"prototype_events:" .. event_type,
					function(a, b, c, d, e, f, g)
						for i = 1, #events[event_type] do
							local self = events[event_type][i]

							if self then
								local func = config and config.callback or self[func_name]

								if func then
									func(self, a, b, c, d, e, f, g)
								else
									wlog("%s.%s is nil", self, func_name)
									self:RemoveEvent(event_type)
								end
							end
						end
					end,
					config
				)
			end

			list.insert(events[event_type], self)
			self.added_events[event_type] = true
		end

		function META:RemoveEvent(event_type)
			if not self.added_events or not self.added_events[event_type] then return end

			local tbl = events[event_type]

			if tbl then
				for i, other in pairs(tbl) do
					if other == self then
						tbl[i] = nil

						break
					end
				end

				list.fix_indices(tbl)

				if #tbl <= 0 then
					local config = event_configs[event_type]
					local real_event_name = config and config.event_name or event_type
					event.RemoveListener(real_event_name, "prototype_events:" .. event_type)
					events[event_type] = nil
					event_configs[event_type] = nil
				end
			end

			self.added_events[event_type] = nil
		end
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
	META:GetSet("Parent", NULL)
	META:GetSet("Children", {})
	META:GetSet("ChildrenMap", {})

	do -- child order
		META:GetSet("ChildOrder", 0)

		local function child_order_sort(a, b)
			local order_a = a.ChildOrder or 0
			local order_b = b.ChildOrder or 0

			if order_a == order_b then
				return (a._child_insert_order or 0) < (b._child_insert_order or 0)
			end

			return order_a < order_b
		end

		local function refresh_child_insert_order(parent)
			local children = parent.Children

			for i = 1, #children do
				children[i]._child_insert_order = i
			end

			parent._child_insert_serial = #children
		end

		local function move_child(parent, obj, index)
			local children = parent.Children
			local current_index

			for i = 1, #children do
				if children[i] == obj then
					current_index = i

					break
				end
			end

			if not current_index then return false end

			if current_index == index then return true end

			table.remove(children, current_index)

			if index > #children + 1 then index = #children + 1 end

			if index < 1 then index = 1 end

			table.insert(children, index, obj)
			refresh_child_insert_order(parent)
			parent:InvalidateChildrenList()
			return true
		end

		function META:BringToFront()
			local parent = self:GetParent()

			if parent:IsValid() then move_child(parent, self, #parent.Children) end
		end

		META.BringToTop = META.BringToFront

		function META:SendToBack()
			local parent = self:GetParent()

			if parent:IsValid() then move_child(parent, self, 1) end
		end

		META.SendToBottom = META.SendToBack

		function META:SetChildOrder(pos)
			self.ChildOrder = pos

			if self:HasParent() then
				list.sort(self.Parent.Children, child_order_sort)
				self.Parent:InvalidateChildrenList()
			end
		end
	end

	do -- children
		local function clear_children_traversal_cache(obj)
			obj.children_list = nil
			obj.children_traversal_cache = nil
		end

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

		local function build_children_list(self)
			local tbl = {}
			add_recursive(self, tbl, 1)
			return tbl
		end

		function META:GetCachedChildrenTraversal(cache_key, builder)
			local cache = self.children_traversal_cache

			if not cache then
				cache = {}
				self.children_traversal_cache = cache
			end

			local traversal = cache[cache_key]

			if traversal == nil then
				traversal = builder(self)
				cache[cache_key] = traversal
			end

			return traversal
		end

		function META:GetChildrenList()
			if not self.children_list then
				self.children_list = self:GetCachedChildrenTraversal("children_list", build_children_list)
			end

			return self.children_list
		end

		function META:InvalidateChildrenList()
			clear_children_traversal_cache(self)

			for _, parent in ipairs(self:GetParentList()) do
				clear_children_traversal_cache(parent)
			end
		end
	end

	do -- parent
		function META:SetParent(obj)
			if obj and not obj.IsValid then
				table.print(obj)
				debug.trace()
			end

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

		local function invalidate_parent_list_recursive(obj)
			obj.parent_list = nil

			for _, child in ipairs(obj:GetChildren()) do
				invalidate_parent_list_recursive(child)
			end
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
			invalidate_parent_list_recursive(self)
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
		if self.PreChildAdd and self:PreChildAdd(obj, pos) == false then return false end

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
			self._child_insert_serial = (self._child_insert_serial or 0) + 1
			obj._child_insert_order = self._child_insert_serial

			if pos then
				list.insert(self.Children, pos, obj)
			else
				list.insert(self.Children, obj)
			end
		end

		self:InvalidateChildrenList()
		obj:CallLocalEvent("OnParent", self)

		if not obj.suppress_child_add then
			obj.suppress_child_add = true
			self:CallLocalEvent("OnChildAdd", obj)
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
			local order_a = a.ChildOrder or 0
			local order_b = b.ChildOrder or 0

			if order_a == order_b then
				return (a._child_insert_order or 0) < (b._child_insert_order or 0)
			end

			return order_a < order_b
		end

		function META:SortChildren() -- todo
		-- Preserve insertion order by default; explicit SetChildOrder already sorts when needed.
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
		if self.PreRemoveChildren and self:PreRemoveChildren() == false then return end

		if self.__skip_remove_children then
			self.__skip_remove_children = nil
			return
		end

		if not self.Children[1] then
			self.Children = {}
			self.ChildrenMap = {}
			return
		end

		self:InvalidateChildrenList()
		local children = self:GetChildren()
		local remove_list = {}
		self.bulk_removing_children = true

		for i = #children, 1, -1 do
			local root = children[i]
			local stack = {root}

			while #stack > 0 do
				local obj = stack[#stack]

				if obj.__bulk_remove_mark then
					stack[#stack] = nil
					remove_list[#remove_list + 1] = obj
				else
					obj.__bulk_remove_mark = true
					obj.__skip_remove_children = true
					local obj_children = obj:GetChildren()

					for j = #obj_children, 1, -1 do
						stack[#stack + 1] = obj_children[j]
					end
				end
			end
		end

		for i = 1, #remove_list do
			local obj = remove_list[i]
			obj.__bulk_remove_mark = nil
			obj:Remove()
		end

		self.bulk_removing_children = nil
		self.Children = {}
		self.ChildrenMap = {}
	end

	function META:UnParent()
		local parent = self:GetParent()

		if parent:IsValid() then parent:RemoveChild(self) end
	end

	function META:RemoveChild(obj)
		if self.ChildrenMap[obj] == nil then return end

		self.ChildrenMap[obj] = nil

		if self.bulk_removing_children and self.Children[#self.Children] == obj then
			self.Children[#self.Children] = nil
			obj.Parent = NULL
			obj:InvalidateParentList()
			obj:CallLocalEvent("OnUnParent", self)
			self:CallLocalEvent("OnChildRemove", obj)
			return
		end

		for i, val in ipairs(self.Children) do
			if val == obj then
				table.remove(self.Children, i)
				self:InvalidateChildrenList()
				obj.Parent = NULL
				obj:InvalidateParentList()
				obj:CallLocalEvent("OnUnParent", self)
				self:CallLocalEvent("OnChildRemove", obj)

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
