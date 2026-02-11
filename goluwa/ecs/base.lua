return function(name, base_path, get_valid_components)
	local prototype = require("prototype")
	local BaseEntity = prototype.CreateTemplate(name)
	prototype.ParentingTemplate(BaseEntity)
	local valid_components

	local function apply_config(instance, config)
		if type(config) ~= "table" then return end

		for key, value in pairs(config) do
			if type(key) == "string" then
				if key:starts_with("On") then
					instance[key] = value
				else
					local setter = "Set" .. key

					if instance[setter] then
						instance[setter](instance, value)
					else
						instance[key] = value
					end
				end
			end
		end

		for i = 1, #config do
			apply_config(instance, config[i])
		end
	end

	function BaseEntity.New(config)
		local self = BaseEntity:CreateObject(
			{
				Children = {},
				ChildrenMap = {},
				component_map = {},
				component_list = {},
			}
		)
		local ent = self
		local components = {}
		local local_events = {}
		local ref
		local parent = BaseEntity.World

		local function find_special_props(config)
			if type(config) ~= "table" then return end

			if config.Ref then
				ref = config.Ref
				config.Ref = nil
			end

			if config.Parent then
				parent = config.Parent
				config.Parent = nil
			end

			for i = 1, #config do
				find_special_props(config[i])
			end
		end

		find_special_props(config)
		self:SetParent(parent)

		if config then
			local function apply_root_config(config)
				if config.ComponentSet then
					for _, lib in ipairs(config.ComponentSet) do
						table.insert(components, ent:AddComponent(lib, nil, true))
					end
				end

				if config.Events then
					for event_name, handler in pairs(config.Events) do
						self:AddLocalListener(event_name, handler)
					end
				end

				valid_components = valid_components or get_valid_components()

				for key, val in pairs(config) do
					if
						type(key) == "table" and
						key.Component or
						(
							type(key) == "string" and
							valid_components[key]
						)
					then
						if not ent:HasComponent(key) then
							table.insert(components, ent:AddComponent(key, val, true))
						else
							local instance = ent.component_map[key]
							apply_config(instance, val)
						end
					end
				end

				for key, val in pairs(config) do
					if
						not (
							type(key) == "table" and
							key.Component or
							(
								type(key) == "string" and
								valid_components[key]
							)
						) and
						type(key) == "string" and
						key ~= "ComponentSet"
					then
						if key:starts_with("On") then
							ent[key] = val
						else
							local setter_name = "Set" .. key

							if ent[setter_name] then
								ent[setter_name](ent, val)
							else
								local found = false

								for _, component in ipairs(ent.component_list) do
									if component[setter_name] then
										component[setter_name](component, val)
										found = true

										break
									end
								end

								if not found then
									for comp_name, comp_meta in pairs(valid_components) do
										if comp_meta[setter_name] then
											local component = ent:AddComponent(comp_name, nil, true)
											table.insert(components, component)
											component[setter_name](component, val)
											found = true

											break
										end
									end
								end

								if not found then
									if not ent[setter_name] then
										--error("Missing setter for property: " .. key)
										ent[key] = val
									else
										ent[setter_name](ent, val)
									end
								end
							end
						end
					end
				end

				for i = 1, #config do
					apply_root_config(config[i])
				end
			end

			apply_root_config(config)
		end

		if self:GetKey() ~= "" and self.Parent:IsValid() then
			self.Parent.keyed_children = self.Parent.keyed_children or {}
			local existing = self.Parent.keyed_children[self:GetKey()]

			if existing and existing:IsValid() then existing:Remove() end

			self.Parent.keyed_children[self:GetKey()] = self
		end

		for _, component in ipairs(self.component_list) do
			if component.Initialize then component:Initialize() end
		end

		if ref then ref(ent) end

		return self
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
		local lst = list.flatten(children or {})

		for i = #lst, 1, -1 do
			local child = lst[i]

			if type(child) == "table" and child.UnParent then child:UnParent() end
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
		valid_components = valid_components or get_valid_components()
		local meta = valid_components[name] --require(base_path .. name)
		self[name] = self:CreateSubObject(meta)
		apply_config(self[name], tbl)

		if not skip_init then
			if self[name].Initialize then self[name]:Initialize() end
		end

		self.component_map[name] = self[name]
		self.component_list = self.component_list or {}
		list.insert(self.component_list, self[name])
		return self[name]
	end

	function BaseEntity:RemoveComponent(name)
		if not self[name] then return end

		self[name]:Remove()
		self[name] = nil
		self.component_map[name] = nil

		for i, component in ipairs(self.component_list) do
			if component == self[name] then
				table.remove(self.component_list, i)

				break
			end
		end
	end

	function BaseEntity:HasComponent(name)
		return self[name] ~= nil
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
			local key = ent.Key

			if key and key ~= "" then
				local existing = self:GetKeyed(key)

				if existing then return existing end
			end

			ent.Parent = self
			return BaseEntity.New(ent)
		end

		local key = ent:GetKey()

		if key ~= "" then
			local existing = self:GetKeyed(key)

			if existing and existing ~= ent then
				-- if we actually already has an existing one that is DIFFERENT from the one passed,
				-- we should probably keep the old one and remove the new one.
				-- but BaseEntity.New already removed the old one if it was keyed to the same parent.
				-- so this case might only happen if the parent was changed or keys were changed.
				ent:Remove()
				return existing
			end
		end

		ent:SetParent(self)
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

	return BaseEntity:Register()
end
