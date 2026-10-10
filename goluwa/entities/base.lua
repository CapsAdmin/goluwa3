local event = import("goluwa/event.lua")
local objects = import("goluwa/objects/objects.lua")
local BaseEntity = objects.CreateTemplate("base_entity")
objects.ParentingTemplate(BaseEntity)
BaseEntity:GetSet("Transient", nil, {type = "boolean"})

function BaseEntity:GetTransient()
	if self.Transient ~= nil then return self.Transient end

	local parent = self:GetParent()

	if not parent:IsValid() or parent == self.World then return true end

	return parent:GetTransient()
end

BaseEntity:GetSet("Singleton", false)
local valid_components

local function record_property_token(owner, obj, key, token, resolved)
	local records = owner.property_tokens

	if not records then
		records = {}
		owner.property_tokens = records
	end

	for i = 1, #records do
		local record = records[i]

		if record.obj == obj and record.key == key then
			record.token = token
			record.resolved = resolved
			return
		end
	end

	records[#records + 1] = {obj = obj, key = key, token = token, resolved = resolved}
end

local function set_property(owner, obj, key, val)
	local resolved, token = event.Call("OnEntitySetProperty", obj, key, val)
	local original = val

	if resolved ~= nil then val = resolved end

	local ok = objects.SetProperty(obj, key, val)

	if ok and resolved ~= nil and (token ~= nil or resolved ~= original) then
		record_property_token(owner, obj, key, token == nil and original or token, resolved)
	end

	return ok, val
end

local flatten_component

do
	local function flatten_component_into(dst, src)
		for key, value in pairs(src) do
			if type(key) == "string" then dst[key] = value end
		end

		for i = 1, #src do
			local nested = src[i]

			if type(nested) == "table" and not getmetatable(nested) then
				flatten_component_into(dst, nested)
			end
		end
	end

	function flatten_component(src)
		local dst = {}
		flatten_component_into(dst, src)
		return dst
	end
end

local flatten_props

do
	local function merge_list(dst, key, src)
		local merged = {}
		local old = dst[key]

		if old then for i = 1, #old do
			merged[i] = old[i]
		end end

		for i = 1, #src do
			if not list.has_value(merged, src[i]) then merged[#merged + 1] = src[i] end
		end

		dst[key] = merged
	end

	function flatten_props(valid_components, dst, children, src)
		for key, value in pairs(src) do
			if type(key) == "string" then
				if valid_components[key] then
					local old = dst[key]

					if type(value) == "table" then
						local merged = type(old) == "table" and flatten_component(old) or {}

						for k, v in pairs(flatten_component(value)) do
							merged[k] = v
						end

						dst[key] = merged
					elseif type(old) ~= "table" then
						dst[key] = value
					end
				elseif key == "ComponentSet" then
					merge_list(dst, key, value)
				elseif key == "Events" then
					local merged = {}

					for k, v in pairs(dst.Events or {}) do
						merged[k] = v
					end

					for k, v in pairs(value) do
						merged[k] = v
					end

					dst.Events = merged
				else
					dst[key] = value
				end
			end
		end

		for i = 1, #src do
			local nested = src[i]

			if getmetatable(nested) then
				children[#children + 1] = nested
			elseif type(nested) == "table" then
				flatten_props(valid_components, dst, children, nested)
			end
		end
	end
end

local sort_orders

local function compare_keys(a, b)
	local order_a, order_b = sort_orders[a], sort_orders[b]

	if order_a ~= order_b then return order_a < order_b end

	return a < b
end

local function sorted_keys(props, get_order, a, b, c)
	local keys = {}
	local orders = {}

	for key in pairs(props) do
		if type(key) == "string" then
			keys[#keys + 1] = key
			orders[key] = get_order(key, a, b, c)
		end
	end

	sort_orders = orders
	table.sort(keys, compare_keys)
	sort_orders = nil
	return keys
end

local function declared_order(meta, key)
	local info = meta.objects_variables and meta.objects_variables[key]
	return info and info.order
end

local function get_component_key_order(key, meta)
	return declared_order(meta, key) or math.huge
end

local function apply_component_props(owner, component, props)
	if type(props) ~= "table" then return end

	local flat = flatten_component(props)
	local keys = sorted_keys(flat, get_component_key_order, getmetatable(component))

	for _, key in ipairs(keys) do
		local value = flat[key]

		if key:starts_with("On") then
			component[key] = value
		else
			local ok, new_value = set_property(owner, component, key, value)

			if not ok then component[key] = new_value end
		end
	end
end

function BaseEntity:NotifyWorldEvent(event_name, a, b, c, d, e, f, g)
	local world = self.World

	if world and world.IsValid and world:IsValid() then
		return world:CallLocalEvent(event_name, self, a, b, c, d, e, f, g)
	end
end

local function notify_parented(self, parent)
	self:NotifyWorldEvent("OnEntityHierarchyChanged", "parented", parent)
end

local function notify_unparented(self, old_parent)
	self:NotifyWorldEvent("OnEntityHierarchyChanged", "unparented", old_parent)
end

local function set_keyed(self)
	self.Parent.keyed_children = self.Parent.keyed_children or {}
	local existing = self.Parent.keyed_children[self:GetKey()]

	if existing ~= self and existing and existing:IsValid() then
		existing:Remove()
	end

	self.Parent.keyed_children[self:GetKey()] = self
end

local function get_defaults_chain(meta)
	local chain = meta.prop_defaults_chain

	if chain then return chain end

	chain = {}
	local registered = objects.registered[meta.Type]

	while registered do
		local defaults = rawget(registered, "PropDefaults")

		if defaults then table.insert(chain, 1, defaults) end

		registered = registered.Base and objects.registered[registered.Base]
	end

	meta.prop_defaults_chain = chain
	return chain
end

local function get_sorted_component_names(meta, valid_components)
	local names = meta.sorted_component_names

	if not names then
		names = {}

		for name in pairs(valid_components) do
			names[#names + 1] = name
		end

		table.sort(names)
		meta.sorted_component_names = names
	end

	return names
end

local function add_unique(names, added, name)
	if not added[name] then
		added[name] = true
		names[#names + 1] = name
	end
end

local function get_key_order(key, valid_components, meta)
	local orders = meta.prop_key_orders

	if not orders then
		orders = {}
		meta.prop_key_orders = orders
	end

	local order = orders[key]

	if order then return order end

	order = declared_order(meta, key)

	if not order then
		for _, name in ipairs(get_sorted_component_names(meta, valid_components)) do
			order = declared_order(valid_components[name], key)

			if order then break end
		end
	end

	order = order or math.huge
	orders[key] = order
	return order
end

function BaseEntity:OnConstruct(config)
	self.Children = {}
	self.ChildrenMap = {}
	self.component_map = {}
	self.component_list = {}
	self:AddLocalListener("OnParent", notify_parented)
	self:AddLocalListener("OnUnParent", notify_unparented)
	local meta = getmetatable(self)
	local chain = get_defaults_chain(meta)
	local component_set = self.ComponentSet

	if not config and not chain[1] and not (component_set and component_set[1]) then
		return
	end

	local valid_components = self.GetValidComponents()
	local given = {}
	local children = {}

	if config then flatten_props(valid_components, given, children, config) end

	for i = #chain, 1, -1 do
		local merged = {}
		flatten_props(valid_components, merged, children, chain[i](self, given))
		flatten_props(valid_components, merged, children, given)
		given = merged
	end

	local props = {}
	local cmp = self.CMP

	if component_set then
		for _, name in ipairs(component_set) do
			local defaults = cmp and rawget(cmp, name)

			if defaults and next(defaults) then
				props[name] = flatten_component(defaults)
			else
				props[name] = true
			end
		end
	end

	flatten_props(valid_components, props, children, given)
	local names = {}
	local added = {}

	if component_set then
		for _, name in ipairs(component_set) do
			add_unique(names, added, name)
		end
	end

	if props.ComponentSet then
		for _, name in ipairs(props.ComponentSet) do
			add_unique(names, added, name)
		end
	end

	local extra = {}

	for key in pairs(props) do
		if valid_components[key] and not added[key] then extra[#extra + 1] = key end
	end

	table.sort(extra)

	for _, name in ipairs(extra) do
		add_unique(names, added, name)
	end

	for _, name in ipairs(names) do
		self:AddComponent(name, props[name], true)
	end

	if props.Events then
		local event_names = {}

		for event_name in pairs(props.Events) do
			event_names[#event_names + 1] = event_name
		end

		table.sort(event_names)

		for _, event_name in ipairs(event_names) do
			self:AddLocalListener(event_name, props.Events[event_name])
		end
	end

	local keys = sorted_keys(props, get_key_order, valid_components, meta)

	for _, key in ipairs(keys) do
		local val = props[key]

		if
			not valid_components[key] and
			key ~= "ComponentSet" and
			key ~= "Events" and
			key ~= "Ref" and
			key ~= "Parent"
		then
			if key:starts_with("On") then
				self[key] = val
			else
				local ok, new_val = set_property(self, self, key, val)

				if not ok then
					local found = false

					for _, component in ipairs(self.component_list) do
						if set_property(self, component, key, val) then
							found = true

							break
						end
					end

					if not found then
						for _, comp_name in ipairs(get_sorted_component_names(meta, valid_components)) do
							local comp_meta = valid_components[comp_name]

							if objects.GetPropertyInfo(comp_meta, key) or comp_meta["Set" .. key] then
								local component = self:AddComponent(comp_name, nil, true)
								set_property(self, component, key, val)
								found = true

								break
							end
						end
					end

					if not found then self[key] = new_val end
				end
			end
		end
	end

	for _, child in ipairs(children) do
		self:AddChild(child)
	end

	for _, component in ipairs(self.component_list) do
		if component.Initialize then component:Initialize() end

		if component.OnAdd then component:OnAdd() end
	end

	self.construct_ref = props.Ref
	self.construct_parent = props.Parent
end

function BaseEntity:OnCreate() end

function BaseEntity:OnPostCreate()
	local ref_func = self.construct_ref
	local parent = self.construct_parent or self.World
	self.construct_ref = nil
	self.construct_parent = nil

	if ref_func then ref_func(self) end

	self:SetParent(parent)

	if parent and parent:IsValid() and self:GetKey() ~= "" then set_keyed(self) end
end

-- the nearest entity at or above this one that is a prefab instance
function BaseEntity:GetPrefab()
	local entity = self

	while entity:IsValid() do
		if entity.prefab then return entity end

		entity = entity:GetParent()
	end
end

-- a node of the nearest prefab by its id
function BaseEntity:GetNode(id)
	local root = self:GetPrefab()
	assert(root, "entity is not part of a prefab instance")
	return root.prefab:GetNode(id)
end

function BaseEntity:GetPropertyToken(key)
	local records = self.property_tokens

	if records then
		for i = 1, #records do
			if records[i].key == key then return records[i].token end
		end
	end

	return objects.GetProperty(self, key)
end

function BaseEntity:ReresolveProperties()
	local records = self.property_tokens

	if not records then return end

	for _, record in ipairs(records) do
		local obj = record.obj

		if objects.GetProperty(obj, record.key) == record.resolved then
			local resolved = event.Call("OnEntitySetProperty", obj, record.key, record.token)

			if resolved ~= nil then
				objects.SetProperty(obj, record.key, resolved)
				record.resolved = resolved
			end
		end
	end
end

function BaseEntity:EnsureComponent(name, tbl)
	if self[name] then return self[name] end

	return self:AddComponent(name, tbl)
end

function BaseEntity:__call(...)
	self:SetChildren({...})
	return self
end

function BaseEntity:SetChildren(children)
	if not children then
		self:RemoveChildren()
		return
	end

	local lst = list.flatten_with_holes(children)

	for i = #lst, 1, -1 do
		lst[i]:UnParent()
	end

	self:RemoveChildren()

	for _, child in ipairs(lst) do
		self:AddChild(child)
	end
end

function BaseEntity:OnRemove()
	local parent = self:GetParent()
	self:UnParent()

	if parent and parent:IsValid() and parent.keyed_children then
		local key = self:GetKey()

		if key ~= "" and parent.keyed_children[key] == self then
			parent.keyed_children[key] = nil
		end
	end

	self:RemoveChildren()
end

function BaseEntity:AddComponent(name, tbl, skip_init)
	local valid_components = self.GetValidComponents()
	local meta = valid_components[name]
	local component = self:CreateSubObject(meta)
	self[name] = component
	apply_component_props(self, component, tbl)

	if not skip_init then
		if component.Initialize then component:Initialize() end
	end

	self.component_map[name] = component
	self.component_list = self.component_list or {}
	list.insert(self.component_list, component)

	if not skip_init and component.OnAdd then component:OnAdd() end

	self:NotifyWorldEvent("OnEntityComponentChanged", "added", name, component)
	return component
end

function BaseEntity:RemoveComponent(name)
	local component = self[name]

	if not component then return end

	component:Remove()
	self[name] = nil
	self.component_map[name] = nil

	for i, other in ipairs(self.component_list) do
		if other == component then
			table.remove(self.component_list, i)

			break
		end
	end

	self:NotifyWorldEvent("OnEntityComponentChanged", "removed", name, component)
end

function BaseEntity:HasComponent(name)
	return self.component_map[name] ~= nil
end

function BaseEntity:GetComponents()
	return self.component_list
end

function BaseEntity:GetKeyed(key)
	local ent = self.keyed_children and self.keyed_children[key]

	if ent and ent:IsValid() then return ent end
end

function BaseEntity:RemoveKeyed(key)
	local entity = self:GetKeyed(key)

	if entity and entity:IsValid() then
		if entity:GetParent() == self then entity:Remove() end

		self.keyed_children[key] = nil
	end
end

function BaseEntity:Ensure(ent)
	if not ent then return end

	if type(ent) == "table" and not ent.IsValid then
		local key = assert(ent.Key, "missing key")
		local existing = self:GetKeyed(key)

		if existing then return existing end

		ent.Parent = self
		return self.New(ent)
	end

	local key = assert(ent:GetKey(), "missing key")
	local existing = self:GetKeyed(key)

	if existing and existing ~= ent then
		ent:Remove()
		return existing
	end

	ent:SetParent(self)
	set_keyed(ent)
	return ent
end

function BaseEntity:Conditional(condition, props)
	local key = props.Key

	if not key then error("Conditional requires a Key prop") end

	if condition then
		return self:Ensure(props)
	else
		self:RemoveKeyed(key)
		return nil
	end
end

function BaseEntity:SetState(key, val)
	self.state = self.state or {}

	if self.state[key] == val then return end

	self.state[key] = val
	self:CallLocalEvent("OnStateChanged", key, val)
	event.Call("OnEntityStateChanged", self, key, val)
end

function BaseEntity:GetState(key)
	if not key then return self.state end

	return self.state and self.state[key]
end

return BaseEntity:Register()
