local Entity = import("goluwa/entities/entity.lua")
local objects = import("goluwa/objects/objects.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local crypto = import("goluwa/crypto.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
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
		kind == "vec2" or
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
	if entity:GetTransient() then return true end

	for _, component in pairs(entity.component_map) do
		if component.ShouldSerializeEntity and not component:ShouldSerializeEntity() then
			return true
		end
	end

	return false
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

	if entity.unavailable_components then
		for name, properties in pairs(entity.unavailable_components) do
			components[name] = properties
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

-- with skip_equal a value the object already has is not set again, a table is a new object every time so setting it would count as a change and run the callbacks of the property, a model would rebuild
local function apply_properties(object, properties, what, skip_equal)
	if not properties then return end

	local infos = objects.GetStorableVariables(object)
	local known = {}

	for _, info in ipairs(infos) do
		known[info.var_name] = true
		local value = properties[info.var_name]

		if
			value ~= nil and
			not (
				skip_equal and
				values_equal(object[info.get_name](object), value)
			)
		then
			object[info.set_name](object, value)
		end
	end

	for var_name in pairs(properties) do
		if not known[var_name] then
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

-- components this process cannot create, a headless server has no render components, are kept as plain data so the scene stays whole
local function split_available(components, valid_components)
	local available = {}
	local unavailable

	for name, properties in pairs(components) do
		if valid_components[name] then
			available[name] = properties
		else
			unavailable = unavailable or {}
			unavailable[name] = properties
		end
	end

	return available, unavailable
end

local function has_singleton_component(components)
	local valid_components = Entity.GetValidComponents()

	for name in pairs(components) do
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
	local yield_every = options.yield_every
	local valid_components = Entity.GetValidComponents()

	for index, record in ipairs(data.entities) do
		if yield_every and index % yield_every == 0 then
			tasks.ReportProgress("spawning entities", #data.entities)
			tasks.Wait()
		end

		local components, unavailable = record.components, nil

		if options.skip_unavailable then
			components, unavailable = split_available(record.components, valid_components)
		end

		local existing = objects.GetObjectByGUID(record.guid)
		local reuse = not options.regenerate_guids and
			existing and
			existing:IsValid() and
			existing:GetSingleton()

		if skipped[record.parent] then
			skipped[record.guid] = true
		elseif not reuse and has_singleton_component(components) then
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
			entity.unavailable_components = unavailable

			for _, name in ipairs(sorted_component_names(components)) do
				local component = entity:HasComponent(name) and entity[name] or entity:AddComponent(name)

				if reuse and component.ResetProperties then component:ResetProperties() end

				apply_properties(component, components[name], name)

				if component.OnDeserialized then component:OnDeserialized() end
			end

			spawned[record.guid] = entity

			if not record.parent then roots[#roots + 1] = entity end
		end
	end

	return roots, spawned
end

do
	local function sync_state(object, properties, what)
		for _, info in ipairs(objects.GetStorableVariables(object)) do
			if
				info.default ~= nil and
				(
					not properties or
					properties[info.var_name] == nil
				)
				and
				not values_equal(object[info.get_name](object), info.default)
			then
				object[info.set_name](object, info.copy and info.copy() or info.default)
			end
		end

		apply_properties(object, properties, what, true)
	end

	function scene.Apply(data, parent, options)
		options = options or {}
		local valid_components = Entity.GetValidComponents()
		local spawned = {}
		local present = {}
		local roots = {}

		for _, record in ipairs(data.entities) do
			local components, unavailable = record.components, nil

			if options.skip_unavailable then
				components, unavailable = split_available(record.components, valid_components)
			end

			local entity = objects.GetObjectByGUID(record.guid)
			local wanted_parent = record.parent and spawned[record.parent] or parent

			if not (entity and entity:IsValid()) then
				entity = Entity.New{Parent = wanted_parent}
				entity:SetTransient(false)
				entity:SetGUID(record.guid)
			elseif not record.parent and entity:GetParent() ~= wanted_parent then
				entity:SetParent(wanted_parent)
			end

			sync_state(entity, record.properties, "entity")
			entity.unavailable_components = unavailable

			for _, name in ipairs(sorted_component_names(components)) do
				local component = entity:HasComponent(name) and entity[name] or entity:AddComponent(name)
				sync_state(component, components[name], name)

				if component.OnDeserialized then component:OnDeserialized() end
			end

			local stale = {}

			for name, component in pairs(entity.component_map) do
				if
					not record.components[name] and
					not TRANSIENT_COMPONENTS[name] and
					not (
						entity.model and
						name == "visual"
					)
					and
					(
						not component.ShouldSerialize or
						component:ShouldSerialize()
					)
				then
					stale[#stale + 1] = name
				end
			end

			for _, name in ipairs(stale) do
				entity:RemoveComponent(name)
			end

			present[record.guid] = true
			spawned[record.guid] = entity

			if not record.parent then roots[#roots + 1] = entity end
		end

		for _, entity in pairs(spawned) do
			local stale = {}

			for _, child in ipairs(entity:GetChildren()) do
				if not present[child:GetGUID()] and not child:GetTransient() and not child.network then
					stale[#stale + 1] = child
				end
			end

			for _, child in ipairs(stale) do
				child:Remove()
			end
		end

		return roots, spawned
	end
end

function scene.GetDirectory()
	return vfs.GetStorageDirectory("storage") .. "scenes/"
end

function scene.GetPath(name)
	assert(name:find("^[%w_%-%. ]+$"), "invalid scene name: " .. name)
	return scene.GetDirectory() .. name .. ".scene"
end

do
	local MAGIC = "GLWS"
	local FORMAT_VERSION = 1
	local HEADER_SIZE = 13
	local MAX_INTERNED_LENGTH = 64
	local TAG_NIL = 0
	local TAG_FALSE = 1
	local TAG_TRUE = 2
	local TAG_NUMBER = 3
	local TAG_STRING = 4
	local TAG_RAW_STRING = 5
	local TAG_VEC2 = 6
	local TAG_VEC3 = 7
	local TAG_QUAT = 8
	local TAG_COLOR = 9
	local TAG_TABLE = 10

	local function compare_keys(a, b)
		local a_number = type(a) == "number"

		if a_number ~= (type(b) == "number") then return a_number end

		return a < b
	end

	local function intern(strings, str)
		local index = strings.index[str]

		if not index then
			index = #strings.list
			strings.list[index + 1] = str
			strings.index[str] = index
		end

		return index
	end

	local function write_value(buffer, strings, value)
		local kind = typex(value)

		if kind == "nil" then
			buffer:WriteByte(TAG_NIL)
		elseif kind == "boolean" then
			buffer:WriteByte(value and TAG_TRUE or TAG_FALSE)
		elseif kind == "number" then
			buffer:WriteByte(TAG_NUMBER)
			buffer:WriteDouble(value)
		elseif kind == "string" then
			if #value <= MAX_INTERNED_LENGTH then
				buffer:WriteByte(TAG_STRING)
				buffer:WriteVariableSizedInteger(intern(strings, value))
			else
				buffer:WriteByte(TAG_RAW_STRING)
				buffer:WriteVariableSizedInteger(#value)
				buffer:WriteBytes(value)
			end
		elseif kind == "vec2" then
			buffer:WriteByte(TAG_VEC2)
			buffer:WriteDouble(value.x)
			buffer:WriteDouble(value.y)
		elseif kind == "vec3" then
			buffer:WriteByte(TAG_VEC3)
			buffer:WriteDouble(value.x)
			buffer:WriteDouble(value.y)
			buffer:WriteDouble(value.z)
		elseif kind == "quat" then
			buffer:WriteByte(TAG_QUAT)
			buffer:WriteDouble(value.x)
			buffer:WriteDouble(value.y)
			buffer:WriteDouble(value.z)
			buffer:WriteDouble(value.w)
		elseif kind == "color" then
			buffer:WriteByte(TAG_COLOR)
			buffer:WriteDouble(value.r)
			buffer:WriteDouble(value.g)
			buffer:WriteDouble(value.b)
			buffer:WriteDouble(value.a)
		else
			local keys = {}

			for key in pairs(value) do
				keys[#keys + 1] = key
			end

			table.sort(keys, compare_keys)
			buffer:WriteByte(TAG_TABLE)
			buffer:WriteVariableSizedInteger(#keys)

			for _, key in ipairs(keys) do
				write_value(buffer, strings, key)
				write_value(buffer, strings, value[key])
			end
		end
	end

	local function read_value(buffer, strings)
		local tag = buffer:ReadByte()

		if tag == TAG_NIL then return nil end

		if tag == TAG_FALSE then return false end

		if tag == TAG_TRUE then return true end

		if tag == TAG_NUMBER then return buffer:ReadDouble() end

		if tag == TAG_STRING then return strings[buffer:ReadULEB128() + 1] end

		if tag == TAG_RAW_STRING then return buffer:ReadBytes(buffer:ReadULEB128()) end

		if tag == TAG_VEC2 then return Vec2(buffer:ReadDouble(), buffer:ReadDouble()) end

		if tag == TAG_VEC3 then
			return Vec3(buffer:ReadDouble(), buffer:ReadDouble(), buffer:ReadDouble())
		end

		if tag == TAG_QUAT then
			return Quat(
				buffer:ReadDouble(),
				buffer:ReadDouble(),
				buffer:ReadDouble(),
				buffer:ReadDouble()
			)
		end

		if tag == TAG_COLOR then
			return Color(
				buffer:ReadDouble(),
				buffer:ReadDouble(),
				buffer:ReadDouble(),
				buffer:ReadDouble()
			)
		end

		assert(tag == TAG_TABLE, "corrupt scene: unknown value tag " .. tostring(tag))
		local out = {}

		for _ = 1, buffer:ReadULEB128() do
			local key = read_value(buffer, strings)
			out[key] = read_value(buffer, strings)
		end

		return out
	end

	local function write_strings(buffer, list)
		buffer:WriteVariableSizedInteger(#list)

		for _, str in ipairs(list) do
			buffer:WriteVariableSizedInteger(#str)
			buffer:WriteBytes(str)
		end
	end

	local function read_strings(buffer)
		local strings = {}

		for i = 1, buffer:ReadULEB128() do
			strings[i] = buffer:ReadBytes(buffer:ReadULEB128())
		end

		return strings
	end

	function scene.IsSerializable(value)
		return is_serializable(value, 0)
	end

	function scene.EncodeValue(value)
		local strings = {index = {}, list = {}}
		local body = Buffer.New(nil, 256):MakeWritable()
		write_value(body, strings, value)
		local out = Buffer.New(nil, 256):MakeWritable()
		write_strings(out, strings.list)
		out:WriteBytes(body:GetStringSlice(0, body:GetPosition() - 1))
		return out:GetStringSlice(0, out:GetPosition() - 1)
	end

	function scene.DecodeValue(str)
		local buffer = Buffer.New(str)
		return read_value(buffer, read_strings(buffer))
	end

	function scene.Encode(data)
		local strings = {index = {}, list = {}}
		local records = Buffer.New(nil, 65536):MakeWritable()
		records:WriteVariableSizedInteger(#data.entities)

		for _, record in ipairs(data.entities) do
			records:WriteVariableSizedInteger(intern(strings, record.guid))
			records:WriteVariableSizedInteger(record.parent and intern(strings, record.parent) + 1 or 0)
			write_value(records, strings, record.properties)
			local names = {}

			for name in pairs(record.components) do
				names[#names + 1] = name
			end

			table.sort(names)
			records:WriteVariableSizedInteger(#names)

			for _, name in ipairs(names) do
				records:WriteVariableSizedInteger(intern(strings, name))
				write_value(records, strings, record.components[name])
			end
		end

		local payload = Buffer.New(nil, 65536):MakeWritable()
		write_strings(payload, strings.list)
		payload:WriteBytes(records:GetStringSlice(0, records:GetPosition() - 1))
		local payload_string = payload:GetStringSlice(0, payload:GetPosition() - 1)
		local header = Buffer.New(nil, HEADER_SIZE):MakeWritable()
		header:WriteBytes(MAGIC)
		header:WriteByte(FORMAT_VERSION)
		header:WriteU32(crypto.CRC32Bytes(ffi.cast("const uint8_t *", payload_string), #payload_string))
		header:WriteU32(#payload_string)
		return header:GetString() .. payload_string
	end

	function scene.GetChecksum(str)
		assert(str:sub(1, #MAGIC) == MAGIC, "not a scene")
		local buffer = Buffer.New(str)
		buffer:SetPosition(#MAGIC + 1)
		return buffer:ReadU32()
	end

	function scene.Decode(str)
		local buffer = Buffer.New(str)
		assert(buffer:ReadBytes(#MAGIC) == MAGIC, "not a scene")
		local version = buffer:ReadByte()
		assert(version == FORMAT_VERSION, "unsupported scene format version " .. version)
		local checksum = buffer:ReadU32()
		local size = buffer:ReadU32()
		assert(#str == HEADER_SIZE + size, "truncated scene")
		assert(
			crypto.CRC32Bytes(buffer:GetBuffer() + HEADER_SIZE, size) == checksum,
			"scene checksum mismatch"
		)
		local strings = read_strings(buffer)
		local records = {}

		for i = 1, buffer:ReadULEB128() do
			local record = {guid = strings[buffer:ReadULEB128() + 1]}
			local parent = buffer:ReadULEB128()
			record.parent = parent > 0 and strings[parent] or nil
			record.properties = read_value(buffer, strings)
			record.components = {}

			for _ = 1, buffer:ReadULEB128() do
				local name = strings[buffer:ReadULEB128() + 1]
				record.components[name] = read_value(buffer, strings)
			end

			records[i] = record
		end

		return {version = scene.Version, entities = records}, checksum
	end
end

function scene.Save(name)
	local data = scene.Serialize()
	local path = scene.GetPath(name)
	vfs.CreateDirectoriesFromPath(path, true)
	local ok, err = vfs.Write(path, scene.Encode(data))

	if not ok then
		error("failed to save scene " .. name .. ": " .. tostring(err), 0)
	end

	return #data.entities
end

local function read_scene(name)
	local str, err = vfs.Read(scene.GetPath(name))

	if not str then
		error("failed to read scene " .. name .. ": " .. tostring(err), 0)
	end

	local data, decode_err = scene.Decode(str)

	if not data then
		error("failed to decode scene " .. name .. ": " .. tostring(decode_err), 0)
	end

	return data
end

local function reset_unloaded_singletons(spawned)
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

function scene.Load(name)
	local data = read_scene(name)
	scene.Clear()
	local _, spawned = scene.Deserialize(data, Entity.World)
	reset_unloaded_singletons(spawned)
end

local spawning = 0
local idle_callbacks = {}

function scene.IsSpawning()
	return spawning > 0
end

function scene.BeginSpawning()
	spawning = spawning + 1
end

function scene.EndSpawning()
	spawning = spawning - 1

	if spawning == 0 then
		local callbacks = idle_callbacks
		idle_callbacks = {}

		for _, callback in ipairs(callbacks) do
			callback()
		end
	end
end

function scene.WhenIdle(callback)
	if spawning == 0 then
		callback()
	else
		idle_callbacks[#idle_callbacks + 1] = callback
	end
end

function scene.SpawnAsync(data, parent, options, done)
	options = options or {}
	options.yield_every = options.yield_every or 256
	local task = tasks.CreateTask()
	scene_loading.HoldTask(task)
	scene.BeginSpawning()

	function task:OnStart()
		local ok, roots, spawned = pcall(scene.Deserialize, data, parent, options)
		scene.EndSpawning()

		if not ok then error(roots, 0) end

		if done then done(roots, spawned) end
	end

	task:Start()
	return task
end

function scene.LoadAsync(name, done)
	local data = read_scene(name)
	scene.Clear()
	return scene.SpawnAsync(
		data,
		Entity.World,
		nil,
		function(roots, spawned)
			reset_unloaded_singletons(spawned)

			if done then done() end
		end
	)
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
