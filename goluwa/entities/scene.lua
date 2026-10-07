local Entity = import("goluwa/entities/entity.lua")
local objects = import("goluwa/objects/objects.lua")
local luadata = import("goluwa/codecs/luadata.lua")
local vfs = import("goluwa/vfs.lua")
local scene = library()
scene.Version = 1
local TRANSIENT_COMPONENTS = {visual_primitive = true, network = true}
local MAX_TABLE_DEPTH = 8

local function is_serializable(value, depth)
	local kind = typex(value)

	if kind == "number" then return value == value end

	if
		kind == "string" or
		kind == "boolean" or
		kind == "vec3" or
		kind == "quat" or
		kind == "color"
	then
		return true
	end

	if kind ~= "table" or getmetatable(value) or depth > MAX_TABLE_DEPTH then
		return false
	end

	for k, v in pairs(value) do
		local key_kind = type(k)

		if
			(
				key_kind ~= "string" and
				key_kind ~= "number"
			)
			or
			not is_serializable(v, depth + 1)
		then
			return false
		end
	end

	return true
end

local function values_equal(a, b)
	if a == b then return true end

	if type(a) ~= "table" or type(b) ~= "table" or getmetatable(a) or getmetatable(b) then
		return false
	end

	for k, v in pairs(a) do
		if not values_equal(v, b[k]) then return false end
	end

	for k in pairs(b) do
		if a[k] == nil then return false end
	end

	return true
end

local function serialize_properties(object)
	local out

	for _, info in ipairs(objects.GetStorableVariables(object)) do
		local value = object[info.get_name](object)

		if
			value ~= nil and
			not values_equal(value, info.default)
			and
			is_serializable(value, 0)
		then
			out = out or {}
			out[info.var_name] = value
		end
	end

	return out
end

local function is_transient_entity(entity)
	return entity:GetTransient()
end

local function serialize_entity(entity, parent_guid, out)
	local record = {
		guid = entity:GetGUID(),
		parent = parent_guid,
		properties = serialize_properties(entity),
	}
	local components = {}
	local has_model = entity.model ~= nil

	for name, component in pairs(entity.component_map) do
		if
			not TRANSIENT_COMPONENTS[name] and
			not (
				has_model and
				name == "visual"
			)
			and
			(
				not component.ShouldSerialize or
				component:ShouldSerialize()
			)
		then
			components[name] = serialize_properties(component) or {}
		end
	end

	record.components = components
	out[#out + 1] = record
	local model_children

	if has_model and entity.model.children then
		model_children = {}

		for _, child in ipairs(entity.model.children) do
			model_children[child] = true
		end
	end

	for _, child in ipairs(entity:GetChildren()) do
		if not is_transient_entity(child) and not (model_children and model_children[child]) then
			serialize_entity(child, record.guid, out)
		end
	end
end

function scene.SerializeEntities(entities)
	local records = {}

	for _, entity in ipairs(entities) do
		if not is_transient_entity(entity) then
			serialize_entity(entity, nil, records)
		end
	end

	return {version = scene.Version, entities = records}
end

function scene.GetRoots()
	local roots = {}

	for _, child in ipairs(Entity.World:GetChildren()) do
		if not child:GetTransient() then roots[#roots + 1] = child end
	end

	return roots
end

function scene.Serialize()
	return scene.SerializeEntities(scene.GetRoots())
end

function scene.Clear()
	for _, root in ipairs(scene.GetRoots()) do
		if not root:GetSingleton() then root:Remove() end
	end
end

local function apply_properties(object, properties, what)
	if not properties then return end

	local infos = {}

	for _, info in ipairs(objects.GetStorableVariables(object)) do
		infos[info.var_name] = info
	end

	for var_name, value in pairs(properties) do
		local info = infos[var_name]

		if info then
			object[info.set_name](object, value)
		else
			wlog("scene: unknown property %s on %s", var_name, what)
		end
	end
end

local function sorted_component_names(components)
	local names = {}

	for name in pairs(components) do
		if name ~= "transform" then names[#names + 1] = name end
	end

	table.sort(names)

	if components.transform then table.insert(names, 1, "transform") end

	return names
end

local function has_singleton_component(record)
	local valid_components = Entity.GetValidComponents()

	for name in pairs(record.components) do
		if valid_components[name].Singleton then return true end
	end

	return false
end

function scene.Deserialize(data, parent, options)
	options = options or {}
	assert(data.version == scene.Version, "unsupported scene version " .. tostring(data.version))
	local spawned = {}
	local skipped = {}
	local roots = {}

	for _, record in ipairs(data.entities) do
		local existing = objects.GetObjectByGUID(record.guid)
		local reuse = not options.regenerate_guids and
			existing and
			existing:IsValid() and
			existing:GetSingleton()

		if skipped[record.parent] then
			skipped[record.guid] = true
		elseif not reuse and has_singleton_component(record) then
			wlog(
				"scene: skipping %s (%s), only the existing singleton may hold its components",
				tostring(record.guid),
				tostring(record.properties and record.properties.Name)
			)
			skipped[record.guid] = true
		else
			local entity = reuse and
				existing or
				Entity.New{Parent = record.parent and spawned[record.parent] or parent}
			entity:SetTransient(false)

			if not reuse then
				if options.regenerate_guids or (existing and existing:IsValid()) then
					entity:SetGUID(objects.GenerateGUID())
				else
					entity:SetGUID(record.guid)
				end
			end

			apply_properties(entity, record.properties, "entity")

			for _, name in ipairs(sorted_component_names(record.components)) do
				local component = entity:HasComponent(name) and entity[name] or entity:AddComponent(name)
				apply_properties(component, record.components[name], name)

				if component.OnDeserialized then component:OnDeserialized() end
			end

			spawned[record.guid] = entity

			if not record.parent then roots[#roots + 1] = entity end
		end
	end

	return roots, spawned
end

function scene.GetDirectory()
	return vfs.GetStorageDirectory("storage") .. "scenes/"
end

function scene.GetPath(name)
	assert(name:find("^[%w_%-%. ]+$"), "invalid scene name: " .. name)
	return scene.GetDirectory() .. name .. ".luadata"
end

function scene.Save(name)
	local data = scene.Serialize()
	local path = scene.GetPath(name)
	vfs.CreateDirectoriesFromPath(path, true)
	local ok, err = vfs.Write(path, luadata.Encode(data))

	if not ok then
		error("failed to save scene " .. name .. ": " .. tostring(err), 0)
	end

	return #data.entities
end

function scene.Load(name)
	local str, err = vfs.Read(scene.GetPath(name))

	if not str then
		error("failed to read scene " .. name .. ": " .. tostring(err), 0)
	end

	local data, decode_err = luadata.Decode(str)

	if not data then
		error("failed to decode scene " .. name .. ": " .. tostring(decode_err), 0)
	end

	scene.Clear()
	local _, spawned = scene.Deserialize(data, Entity.World)
	local loaded = {}

	for _, entity in pairs(spawned) do
		loaded[entity] = true
	end

	for _, root in ipairs(scene.GetRoots()) do
		if root:GetSingleton() and not loaded[root] then
			for _, component in pairs(root.component_map) do
				if component.ResetProperties then component:ResetProperties() end
			end
		end
	end
end

function scene.GetUniqueName(parent, name)
	local base = name:match("^(.-) %(%d+%)$") or (name ~= "" and name or "entity")
	local taken = {}

	for _, sibling in ipairs(parent:GetChildren()) do
		taken[sibling:GetName()] = true
	end

	local n = 2

	while taken[base .. " (" .. n .. ")"] do
		n = n + 1
	end

	return base .. " (" .. n .. ")"
end

function scene.Clone(entity)
	assert(not entity:GetSingleton(), "cannot clone a singleton entity")
	local parent = entity:GetParent()
	local data = scene.SerializeEntities({entity})
	local root_properties = data.entities[1].properties or {}
	root_properties.Name = scene.GetUniqueName(parent, entity:GetName())
	data.entities[1].properties = root_properties
	return (scene.Deserialize(data, parent, {regenerate_guids = true}))[1]
end

return scene
