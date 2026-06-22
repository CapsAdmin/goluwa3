local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local META = {}
objects.GetSet(META, "DebugTrace", "")
objects.GetSet(META, "CreationTime", os.clock())
objects.GetSet(META, "PropertyIcon", "")
objects.GetSet(META, "HideFromEditor", false)
objects.GetSet(META, "GUID", "")
objects.GetSet(META, "Owner", nil)
objects.GetSet(META, "Key", "")
objects.StartStorable(META)
objects.GetSet(META, "Name", "")
objects.GetSet(META, "Description", "")
objects.EndStorable()

function META:GetGUID()
	local guid = self.GUID

	if guid == nil or guid == "" then
		guid = ("%p%p"):format(self, getmetatable(META))
		self:SetGUID(guid)
		return guid
	end

	objects.created_objects_guid = objects.created_objects_guid or table.weak()

	if objects.created_objects_guid[guid] ~= self then self:SetGUID(guid) end

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
		local obj = objects.CreateObject(meta, override)
		obj:SetOwner(self)

		self:CallOnRemove(function()
			self.sub_objects[obj] = nil
			objects.SafeRemove(obj)
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
	objects.SetFocusedObject(self)
end

do
	objects.remove_these = objects.remove_these or {}
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
			event.AddListener("Update", "objects_remove_objects", objects.CheckRemovedObjects)
			event_added = true
		end

		list.insert(objects.remove_these, self)
		self.__removed = true
	end

	function objects.CheckRemovedObjects()
		if #objects.remove_these > 0 then
			for _, obj in ipairs(objects.remove_these) do
				remove_from_instances(obj)
				objects.created_objects[obj] = nil

				if objects.created_objects_guid and obj.GUID ~= "" then
					objects.created_objects_guid[obj.GUID] = nil
				end

				objects.MakeNULL(obj)
			end

			list.clear(objects.remove_these)
		end
	end
end

do -- serializing
	local callbacks = {}

	function META:SetStorableTable(tbl)
		self:SetGUID(tbl.GUID)

		if self.OnDeserialize then self:OnDeserialize(tbl.__extra_data) end

		for _, info in ipairs(objects.GetStorableVariables(self)) do
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
						objects.AddPropertyLink(unpack(v))
					end)
				end)
			end
		end
	end

	function META:GetStorableTable()
		local out = {}

		for _, info in ipairs(objects.GetStorableVariables(self)) do
			out[info.var_name] = self[info.get_name](self)
		end

		out.GUID = self.GUID
		local info = objects.GetPropertyLinks(self)

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
		objects.created_objects_guid = objects.created_objects_guid or table.weak()

		if objects.created_objects_guid[self.GUID] then
			objects.created_objects_guid[self.GUID] = nil
		end

		self.GUID = guid
		objects.created_objects_guid[self.GUID] = self

		if callbacks[self.GUID] then
			for _, cb in ipairs(callbacks[self.GUID]) do
				cb(self)
			end

			callbacks[self.GUID] = nil
		end
	end

	function META:WaitForGUID(guid, callback)
		local obj = objects.GetObjectByGUID(guid)

		if obj:IsValid() then
			callback(obj)
		else
			callbacks[guid] = callbacks[guid] or {}
			list.insert(callbacks[guid], callback)
			print("added callback for ", guid)
		end
	end

	function objects.GetObjectByGUID(guid)
		objects.created_objects_guid = objects.created_objects_guid or table.weak()
		return objects.created_objects_guid[guid] or NULL
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
			objects.SafeRemove(callback)
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
				"objects_events:" .. event_type,
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
				event.RemoveListener(real_event_name, "objects_events:" .. event_type)
				events[event_type] = nil
				event_configs[event_type] = nil
			end
		end

		self.added_events[event_type] = nil
	end
end

objects.base_metatable = META
