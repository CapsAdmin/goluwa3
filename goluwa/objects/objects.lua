local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local traceback = import("goluwa/debug/traceback.lua")
local objects = library()
import.loaded["goluwa/objects/objects.lua"] = objects
objects.registered = objects.registered or {}
objects.prepared_metatables = objects.prepared_metatables or {}
objects.invalidate_meta = objects.invalidate_meta or {}
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

function objects.CreateTemplate(type_name)
	local template = {Type = type_name}

	for _, key in ipairs(template_functions) do
		template[key] = objects[key]
	end

	return template
end

do
	local blacklist = {
		objects_variables = true,
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

	function objects.Register(meta)
		if not HOTERLOAD then
			if objects.registered[meta.Type] then
				wlog("objects already registered: " .. meta.Type, 2)
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
			if key ~= "CreateObject" and meta[key] == objects[key] then
				meta[key] = nil
			end
		end

		meta.Instances = meta.Instances or table.weak()
		objects.registered[meta.Type] = meta
		objects.invalidate_meta[meta.Type] = true

		if HOTRELOAD then
			logn("Hotreloading objects: " .. meta.Type)
			objects.UpdateObjects(meta)

			for k, v in pairs(meta) do
				if type(v) ~= "function" and not blacklist[k] then
					local found = false

					if meta.objects_variables then
						for _, v in pairs(meta.objects_variables) do
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

function objects.RebuildMetatables(what)
	for type_name, meta in pairs(objects.registered) do
		if what == nil or what == type_name then
			objects.invalidate_meta[type_name] = nil
			local copy = {}
			local objects_variables = {}

			-- first add all the base functions from the base object
			for k, v in pairs(objects.base_metatable) do
				copy[k] = v

				if k == "objects_variables" then
					for k, v in pairs(v) do
						objects_variables[k] = v
					end
				end
			end

			-- then go through the list of bases and derive from them in reversed order
			local base_list = {}

			if meta.Base then
				list.insert(base_list, meta.Base)
				local base = meta

				for _ = 1, 50 do
					base = objects.registered[base.Base]

					if not base or not base.Base then break end

					list.insert(base_list, 1, base.Base)
				end

				for _, v in ipairs(base_list) do
					local base = objects.registered[v]

					-- the base might not be registered yet
					-- however this will be run again once it actually is
					if base then
						for k, v in pairs(base) do
							copy[k] = v

							if k == "objects_variables" then
								for k, v in pairs(v) do
									objects_variables[k] = v
								end
							end
						end
					end
				end
			end

			-- finally the actual metatable
			for k, v in pairs(meta) do
				copy[k] = v

				if k == "objects_variables" then
					for k, v in pairs(v) do
						objects_variables[k] = v
					end
				end
			end

			do
				local tbl = {}

				for _, info in pairs(objects_variables) do
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

			copy.BaseClass = objects.registered[base_list[#base_list]]
			meta.BaseClass = copy.BaseClass
			copy.objects_variables = objects_variables
			objects.prepared_metatables[type_name] = copy
		end
	end
end

do
	function objects.GetRegistered(type_name)
		if objects.registered[type_name] then
			if objects.invalidate_meta[type_name] then
				objects.RebuildMetatables(type_name)
			end

			return objects.prepared_metatables[type_name]
		end
	end

	function objects.GetAllRegistered()
		local out = {}

		for _, meta in pairs(objects.registered) do
			list.insert(out, meta)
		end

		return out
	end

	function objects.GetCreated(sorted, type_name)
		if sorted then
			local out = {}

			for _, v in pairs(objects.created_objects) do
				if not type_name or v.Type == type_name then list.insert(out, v) end
			end

			list.sort(out, function(a, b)
				return a:GetCreationTime() < b:GetCreationTime()
			end)

			return out
		end

		return objects.created_objects or {}
	end
end

local function remove_callback(self)
	if (not self.IsValid or self:IsValid()) and self.Remove then self:Remove() end

	if objects.created_objects then objects.created_objects[self] = nil end
end

do
	local DEBUG = DEBUG or DEBUG_OPENGL
	local setmetatable = setmetatable
	local type = type
	local ipairs = ipairs
	objects.created_objects = objects.created_objects or table.weak()
	objects.created_objects_list = objects.created_objects_list or {}

	function objects.CreateObject(meta, override)
		override = override or objects.override_object or {}
		-- this has to be done in order to ensure we have the prepared metatable with bases
		meta = objects.GetRegistered(meta.Type) or meta

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

		objects.created_objects[self] = self
		list.insert(meta.Instances, self)

		if DEBUG then
			self:SetDebugTrace(debug.traceback())
			self:SetCreationTime(system and system.GetElapsedTime and system.GetElapsedTime() or os.clock())
		end

		return self
	end
end

function objects.SafeRemove(obj)
	if has_index(obj) and obj.IsValid and obj.Remove and obj:IsValid() then
		obj:Remove()
	end
end

function objects.UpdateObjects(meta)
	if type(meta) == "string" then meta = objects.GetRegistered(meta) end

	if not meta then return end

	for _, obj in pairs(objects.GetCreated()) do
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

function objects.RemoveObjects(type_name)
	for _, obj in pairs(objects.GetCreated()) do
		if obj.Type == type_name then if obj:IsValid() then obj:Remove() end end
	end
end

function objects.DumpObjectCount()
	local found = {}

	for obj in pairs(objects.GetCreated()) do
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

	function objects.StartStorable(meta)
		__store = true
		__meta = meta
	end

	function objects.EndStorable()
		__store = false
		__meta = nil
	end

	function objects.GetStorableVariables(meta)
		return meta.storable_variables or {}
	end

	function objects.GetPropertyInfo(meta, name)
		if meta.objects_variables then return meta.objects_variables[name] end
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

	function objects.ValidatePropertyValue(info, value, level)
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

	function objects.ComparePropertyValues(info, a, b)
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

	function objects.CommitProperty(obj, key, value)
		local info = objects.GetPropertyInfo(getmetatable(obj), key)

		if info and info.commit then
			info.commit(obj, value)
			return true
		end

		return false
	end

	function objects.SetProperty(obj, key, value)
		local info = objects.GetPropertyInfo(getmetatable(obj), key)

		if info then
			if
				info.validate or
				info.enums or
				info.list_type or
				info.list_enums or
				info.list_length
			then
				value = objects.ValidatePropertyValue(info, value, 2)
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

	function objects.GetProperty(obj, key)
		local info = objects.GetPropertyInfo(getmetatable(obj), key)

		if info then return obj[info.get_name](obj) end

		local getter = "Get" .. key

		if obj[getter] then return obj[getter](obj) end

		local is_getter = "Is" .. key

		if obj[is_getter] then return obj[is_getter](obj) end

		return obj[key]
	end

	function objects.DelegateProperties(meta, from, var_name, callback)
		meta[var_name] = NULL

		for _, info in pairs(objects.GetStorableVariables(from)) do
			if not meta[info.var_name] then
				objects.SetupProperty{
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

	function objects.SetupProperty(info)
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
		local cast

		if type(default) == "number" then
			cast = function(var, default)
				return tonumber(var) or default
			end
		elseif type(default) == "string" then
			cast = function(var)
				return tostring(var)
			end
		else
			cast = function(var, default)
				if var == nil then return default end

				return var
			end
		end

		local function commit(self, var)
			if has_validation then
				if var == nil then
					var = default
				else
					var = objects.ValidatePropertyValue(info, var, 2)
				end
			else
				var = cast(var, default)
			end

			local listeners = self.property_change_listeners

			if (callback or listeners) and objects.ComparePropertyValues(info, self[name], var) then
				return
			end

			local old_value = self[name]
			self[name] = var

			if callback then
				if var ~= old_value then self[callback](self, name, old_value, var) end
			end

			if listeners then notify_property_listeners(self, info, old_value, var) end
		end

		info.commit = commit
		meta[set_name] = meta[set_name] or commit
		meta[get_name] = meta[get_name] or
			function(self)
				if self[name] ~= nil then return self[name] end

				return default
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

			meta.objects_variables = meta.objects_variables or {}
			meta.objects_variables[info.var_name] = info
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

		return objects.SetupProperty(info)
	end

	function objects.GetSet(meta, name, default, extra_info)
		if type(meta) == "string" and __meta then
			return add(__meta, meta, name, default, "Get")
		else
			return add(meta, name, default, extra_info, "Get")
		end
	end

	function objects.IsSet(meta, name, default, extra_info)
		if type(meta) == "string" and __meta then
			return add(__meta, meta, name, default, "Is")
		else
			return add(meta, name, default, extra_info, "Is")
		end
	end

	function objects.Delegate(meta, key, func_name, func_name2)
		if not func_name2 then func_name2 = func_name end

		meta[func_name] = function(self, ...)
			return self[key][func_name2](self[key], ...)
		end
	end

	function objects.GetSetDelegate(meta, func_name, def, key)
		local get = "Get" .. func_name
		local set = "Set" .. func_name
		local info = objects.GetSet(meta, func_name, def)
		objects.Delegate(meta, key, get)
		objects.Delegate(meta, key, set)
		return info
	end

	function objects.RemoveField(meta, name)
		meta["Set" .. name] = nil
		meta["Get" .. name] = nil
		meta["Is" .. name] = nil
		meta[name] = nil
	end
end

objects.ParentingTemplate = import("goluwa/objects/parenting_template.lua")
import("goluwa/objects/base_object.lua")
import("goluwa/objects/null.lua")
import("goluwa/objects/property_link.lua")

do
	objects.focused_obj = NULL

	function objects.SetFocusedObject(obj)
		if obj.Owner and obj.Owner:IsValid() then
			return objects.SetFocusedObject(obj.Owner)
		end

		if objects.focused_obj == obj then return end

		local old = objects.focused_obj

		if old:IsValid() then if old.OnUnfocus then old:OnUnfocus() end end

		objects.focused_obj = obj

		if obj:IsValid() then if obj.OnFocus then obj:OnFocus() end end
	end

	function objects.GetFocusedObject()
		return objects.focused_obj
	end
end

return objects
