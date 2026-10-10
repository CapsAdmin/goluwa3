local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local vfs = import("goluwa/vfs.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local scene = import("goluwa/entities/scene.lua")
local prefab = library()
prefab.definitions = prefab.definitions or {}
local prefabs_category = assets.categories.prefabs
local ROOT = "root"
local VERSION = 1
local SAVE_DELAY = 0.5
-- the root of an instance is the entity that was placed, it keeps its own transform, physics and network state
local INSTANCE_COMPONENTS = {transform = true, prefab = true, network = true, rigid_body = true}
local dirty = {}
local dirty_properties = {}
local pending_saves = {}
local building = 0
local previewing = false
-- what a thumbnail needs, lights, scripts and colliders would act on the real scene
local PREVIEW_COMPONENTS = {transform = true, model = true, visual = true, prefab = true}
local after_build = {}
local suppressed = 0

local function copy_value(value)
	local kind = type(value)

	if kind == "cdata" then return value:Copy() end

	if kind == "table" and not getmetatable(value) then
		local out = {}

		for k, v in pairs(value) do
			out[k] = copy_value(v)
		end

		return out
	end

	return value
end

local function get_input_value(component, input)
	local inputs = component.Inputs
	local value = inputs and inputs[input.Name]

	if value == nil then return input.Default end

	return value
end

-- a key addresses a field of a table valued property, ModelOptions.size for example
local function bind_value(base, key, value)
	if key == nil then return copy_value(value) end

	local out = base == nil and {} or copy_value(base)
	out[key] = copy_value(value)
	return out
end

-- the record's values with every input bound to this object laid over them
local function get_properties(component, record, name)
	local properties = name == "entity" and record.properties or record.components[name]
	local out = properties and copy_value(properties) or {}

	for _, input in ipairs(component.definition.inputs) do
		for _, target in ipairs(input.Targets) do
			if target.Node == record.guid and target.Component == name then
				out[target.Property] = bind_value(out[target.Property], target.Key, get_input_value(component, input))
			end
		end
	end

	return out
end

local function validate(definition)
	local entities = definition.entities
	assert(
		entities[1] and
			entities[1].guid == ROOT and
			entities[1].parent == nil,
		"the first prefab record must be the root with the guid " .. ROOT
	)
	local records = {}

	for i, record in ipairs(entities) do
		assert(type(record.guid) == "string", "prefab record needs a guid")
		assert(not records[record.guid], "duplicate prefab record " .. record.guid)
		assert(i == 1 or records[record.parent], "prefab records must come after their parent")
		assert(type(record.components) == "table", "prefab record needs components")
		records[record.guid] = record
	end

	local names = {}

	for _, input in ipairs(definition.inputs) do
		assert(input.Name and input.Type and input.Targets, "prefab input needs Name, Type and Targets")
		assert(not names[input.Name], "duplicate prefab input " .. input.Name)
		assert(
			input.Name ~= "Path" and input.Name ~= "Inputs",
			input.Name .. " is a property of the prefab component and cannot name an input"
		)
		names[input.Name] = true

		for _, target in ipairs(input.Targets) do
			local record = records[target.Node]
			assert(record, ("prefab input %s targets the missing node %s"):format(input.Name, tostring(target.Node)))
			assert(target.Property, "prefab input target needs a Property")
			assert(
				target.Component == "entity" or record.components[target.Component],
				("prefab input %s targets the missing component %s"):format(input.Name, tostring(target.Component))
			)
			assert(
				target.Node ~= ROOT or
					(
						target.Component ~= "entity" and
						not INSTANCE_COMPONENTS[target.Component]
					),
				"the root of an instance owns its own entity properties, transform and physics, they cannot be bound to an input"
			)
		end
	end
end

function prefab.GetDirectory()
	return vfs.GetStorageDirectory("storage") .. "prefabs/"
end

local function check_name(name)
	assert(name:find("^[%w_%-%. ]+$"), "invalid prefab name: " .. name)
end

-- where a prefab is saved, it is read back through the asset path so prefabs from addons are found as well
function prefab.GetPath(name)
	check_name(name)
	return prefab.GetDirectory() .. name .. ".prefab"
end

function prefab.Encode(definition)
	return scene.EncodeValue({
		version = VERSION,
		inputs = definition.inputs,
		entities = definition.entities,
	})
end

function prefab.Decode(str)
	local data = scene.DecodeValue(str)
	assert(data.version == VERSION, "unsupported prefab version " .. tostring(data.version))
	return data
end

-- data is {inputs = {...}, entities = {...}}, entities use the scene record format with parents before children and the root first
function prefab.Register(name, data)
	check_name(name)
	local inputs = data.inputs or {}
	validate({inputs = inputs, entities = data.entities})
	local definition = prefab.definitions[name]
	local existing = definition ~= nil
	definition = definition or {
		name = name,
		revision = 0,
		instances = table.weak("k"),
	}
	definition.inputs = inputs
	definition.entities = data.entities
	definition.revision = definition.revision + 1
	prefab.definitions[name] = definition

	if existing then
		for component in pairs(definition.instances) do
			component.applied = {}
			prefab.Sync(component)
			objects.NotifyPropertyListeners(component, {var_name = "DynamicProperties"})
		end
	else
		-- a definition that is not a file still shows up in the asset browser
		local asset_path = prefabs_category.get_path(name)

		if not (vfs.IsFile(asset_path) or assets.virtual_assets[asset_path]) then
			assets.RegisterVirtualAsset(
				asset_path,
				{
					category = "prefabs",
					kind = "prefab",
					load = function()
						return prefab.definitions[name]
					end,
				}
			)
		end
	end

	return definition
end

function prefab.Get(name)
	local definition = prefab.definitions[name]

	if definition then return definition end

	check_name(name)
	local str = vfs.Read(prefabs_category.get_path(name))
	assert(str, ("prefab %q does not exist"):format(name))
	definition = prefab.Register(name, prefab.Decode(str))
	definition.saved = true
	return definition
end

function prefab.Save(name)
	local definition = prefab.Get(name)
	local path = prefab.GetPath(name)
	vfs.CreateDirectoriesFromPath(path, true)
	local ok, err = vfs.Write(path, prefab.Encode(definition))

	if not ok then
		error("failed to save prefab " .. name .. ": " .. tostring(err), 0)
	end

	definition.saved = true
	assets.UnregisterVirtualAsset(prefabs_category.get_path(name))
	assets.InvalidateIndex("prefabs")
	return path
end

-- a copy of what the definition holds, Restore puts it back and brings every instance along
function prefab.Snapshot(name)
	local definition = prefab.Get(name)
	return {inputs = copy_value(definition.inputs), entities = copy_value(definition.entities)}
end

function prefab.Restore(name, snapshot)
	local definition = prefab.Register(name, copy_value(snapshot))

	if definition.saved then prefab.Save(name) end

	event.Call("PrefabChanged", definition)
	event.Call("PrefabInputsChanged", definition)
end

function prefab.GetNames()
	local names = {}

	for name in pairs(prefab.definitions) do
		names[name] = true
	end

	for _, entry in ipairs(assets.Enumerate("prefabs")) do
		names[entry.name] = true
	end

	local out = {}

	for name in pairs(names) do
		out[#out + 1] = name
	end

	table.sort(out)
	return out
end

local function push_input(component, input)
	local value = get_input_value(component, input)

	for _, target in ipairs(input.Targets) do
		local entity = component.nodes[target.Node]
		local object = entity and entity:IsValid() and (target.Component == "entity" and entity or entity[target.Component])

		if object then
			objects.SetProperty(
				object,
				target.Property,
				bind_value(target.Key and objects.GetProperty(object, target.Property), target.Key, value)
			)
		end
	end
end

function prefab.AddInput(name, input)
	local definition = prefab.Get(name)
	local inputs = definition.inputs
	inputs[#inputs + 1] = input

	local ok, err = pcall(validate, definition)

	if not ok then
		inputs[#inputs] = nil
		error(err, 0)
	end

	definition.revision = definition.revision + 1

	for component in pairs(definition.instances) do
		objects.NotifyPropertyListeners(component, {var_name = "DynamicProperties"})
	end

	if definition.saved then prefab.Save(name) end

	event.Call("PrefabChanged", definition)
	event.Call("PrefabInputsChanged", definition)
end

-- the nodes the input pushed into go back to the values the definition holds
function prefab.RemoveInput(name, input_name)
	local definition = prefab.Get(name)

	for i, input in ipairs(definition.inputs) do
		if input.Name == input_name then
			table.remove(definition.inputs, i)

			break
		end
	end

	definition.revision = definition.revision + 1

	for component in pairs(definition.instances) do
		if component.Inputs and component.Inputs[input_name] ~= nil then
			local inputs = {}

			for key, value in pairs(component.Inputs) do
				if key ~= input_name then inputs[key] = value end
			end

			component:SetInputs(inputs)
		end

		component.applied = {}
		prefab.Sync(component)
		objects.NotifyPropertyListeners(component, {var_name = "DynamicProperties"})
	end

	if definition.saved then prefab.Save(name) end

	event.Call("PrefabChanged", definition)
	event.Call("PrefabInputsChanged", definition)
end

-- the property follows the input from now on, its instances take the input's value
function prefab.AddTarget(name, input_name, target)
	local definition = prefab.Get(name)

	for _, input in ipairs(definition.inputs) do
		if input.Name == input_name then
			input.Targets[#input.Targets + 1] = target
			local ok, err = pcall(validate, definition)

			if not ok then
				input.Targets[#input.Targets] = nil
				error(err, 0)
			end

			definition.revision = definition.revision + 1

			for component in pairs(definition.instances) do
				push_input(component, input)
				objects.NotifyPropertyListeners(component, {var_name = "DynamicProperties"})
			end

			if definition.saved then prefab.Save(name) end

			event.Call("PrefabChanged", definition)
	event.Call("PrefabInputsChanged", definition)

			return
		end
	end

	error(("prefab %s has no input %s"):format(name, tostring(input_name)), 2)
end

-- the input that pushes into this property
function prefab.FindInput(name, node, component_name, property)
	for _, input in ipairs(prefab.Get(name).inputs) do
		for _, target in ipairs(input.Targets) do
			if
				target.Node == node and
				target.Component == component_name and
				target.Property == property and
				target.Key == nil
			then
				return input
			end
		end
	end
end

function prefab.IsExposed(name, node, component_name, property)
	return prefab.FindInput(name, node, component_name, property) ~= nil
end

-- takes a property out of every input that pushes into it, an input that loses its last target goes with it
function prefab.Unlink(name, node, component_name, property)
	local definition = prefab.Get(name)
	local emptied = {}
	local changed = false

	for _, input in ipairs(definition.inputs) do
		for i = #input.Targets, 1, -1 do
			local target = input.Targets[i]

			if
				target.Node == node and
				target.Component == component_name and
				target.Property == property and
				target.Key == nil
			then
				table.remove(input.Targets, i)
				changed = true

				if #input.Targets == 0 then emptied[#emptied + 1] = input.Name end
			end
		end
	end

	if not changed then return end

	if emptied[1] then
		for _, input_name in ipairs(emptied) do
			prefab.RemoveInput(name, input_name)
		end

		return
	end

	definition.revision = definition.revision + 1

	for component in pairs(definition.instances) do
		component.applied = {}
		prefab.Sync(component)
		objects.NotifyPropertyListeners(component, {var_name = "DynamicProperties"})
	end

	if definition.saved then prefab.Save(name) end

	event.Call("PrefabChanged", definition)
	event.Call("PrefabInputsChanged", definition)
end

-- instances that never set the input follow the new default
function prefab.SetInputDefault(name, input_name, value)
	local definition = prefab.Get(name)

	for _, input in ipairs(definition.inputs) do
		if input.Name == input_name then
			input.Default = copy_value(value)

			for component in pairs(definition.instances) do
				if component.Inputs == nil or component.Inputs[input_name] == nil then
					push_input(component, input)
				end

				objects.NotifyPropertyListeners(component, {var_name = "DynamicProperties"})
			end

			definition.revision = definition.revision + 1

			if definition.saved then prefab.Save(name) end

			event.Call("PrefabChanged", definition)
	event.Call("PrefabInputsChanged", definition)

			return
		end
	end

	error(("prefab %s has no input %s"):format(name, tostring(input_name)), 2)
end

-- the prefabs that nodes of this one are instances of, at any depth
function prefab.GetDependencies(name, out)
	out = out or {}

	for _, record in ipairs(prefab.Get(name).entities) do
		local nested = record.components.prefab

		if nested and nested.Path and nested.Path ~= "" and not out[nested.Path] then
			out[nested.Path] = true
			prefab.GetDependencies(nested.Path, out)
		end
	end

	return out
end

function prefab.GetInput(component, name)
	for _, input in ipairs(component.definition.inputs) do
		if input.Name == name then return get_input_value(component, input) end
	end

	error(("prefab %s has no input %s"):format(component.Path, tostring(name)), 2)
end

function prefab.ApplyInputs(component, old, new)
	for _, input in ipairs(component.definition.inputs) do
		local old_value = old and old[input.Name]
		local new_value = new and new[input.Name]

		if not scene.ValuesEqual(old_value, new_value) then
			push_input(component, input)
			objects.NotifyPropertyListeners(component, {var_name = input.Name}, old_value, new_value)
		end
	end
end

local function apply_record(component, entity, record, is_root)
	local owned = component.owned[entity]
	local valid_components = Entity.GetValidComponents()

	if not is_root then
		scene.SyncProperties(entity, get_properties(component, record, "entity"), "prefab entity", true)
	end

	-- components this process cannot create, a headless server has no render components, are left out
	for _, name in ipairs(scene.SortedComponentNames(record.components)) do
		if
			valid_components[name] and
			not (
				is_root and
				INSTANCE_COMPONENTS[name]
			)
			and
			(
				not previewing or
				PREVIEW_COMPONENTS[name]
			)
		then
			local properties = get_properties(component, record, name)
			local target

			if entity:HasComponent(name) then
				target = entity[name]
				scene.SyncProperties(target, properties, name, true)
			else
				target = entity:AddComponent(name, properties)
			end

			if target.OnDeserialized then target:OnDeserialized() end

			owned[name] = true
		end
	end

	for name in pairs(owned) do
		if not record.components[name] then
			entity:RemoveComponent(name)
			owned[name] = nil
		end
	end
end

-- makes the instance match its definition, nodes whose record did not change since they were applied are left alone
local function sync_nodes(component)
	local definition = component.definition
	local nodes = component.nodes
	local applied = component.applied
	local seen = {}

	for _, record in ipairs(definition.entities) do
		local id = record.guid
		local is_root = record.parent == nil
		local parent = nodes[record.parent]
		local entity = nodes[id]

		if not (entity and entity:IsValid()) then
			entity = Entity.New{Parent = parent}
			entity.prefab_owner = component
			entity.prefab_node = id
			nodes[id] = entity
			component.owned[entity] = {}
			applied[id] = nil
		elseif not is_root and entity:GetParent() ~= parent then
			entity:SetParent(parent)
		end

		seen[id] = true

		if applied[id] ~= record then
			apply_record(component, entity, record, is_root)
			applied[id] = record
		end
	end

	for id, entity in pairs(nodes) do
		if not seen[id] then
			nodes[id] = nil
			applied[id] = nil
			component.owned[entity] = nil

			if entity:IsValid() then entity:Remove() end
		end
	end
end

function prefab.Sync(component)
	building = building + 1
	local ok, err = pcall(sync_nodes, component)
	building = building - 1

	if building == 0 then
		local callbacks = after_build
		after_build = {}

		for _, callback in ipairs(callbacks) do
			callback()
		end
	end

	if not ok then error(err, 0) end
end

-- runs now, or once the outermost instance being built is complete, scripts use it so every node exists when they start
function prefab.WhenBuilt(callback)
	if building == 0 then
		callback()
	else
		after_build[#after_build + 1] = callback
	end
end

-- changes made while this is on come from code, not from someone editing, and are not written back
function prefab.Suppress()
	suppressed = suppressed + 1
end

function prefab.Unsuppress()
	suppressed = suppressed - 1
end

function prefab.Build(component)
	local owner = component.Owner
	local definition = prefab.Get(component.Path)
	component.definition = definition
	component.nodes = {[ROOT] = owner}
	component.owned = {[owner] = {}}
	component.applied = {}
	definition.instances[component] = true
	owner:EnsureComponent("transform")
	prefab.Sync(component)
end

function prefab.Release(component)
	local definition = component.definition

	if not definition then return end

	definition.instances[component] = nil
	dirty[component] = nil
	dirty_properties[component] = nil
	local owner = component.Owner
	local owned = component.owned[owner]

	for _, entity in pairs(component.nodes) do
		if entity ~= owner and entity:IsValid() then entity:Remove() end
	end

	for name in pairs(owned) do
		owner:RemoveComponent(name)
	end

	component.definition = nil
	component.nodes = {}
	component.owned = {}
	component.applied = {}
end

-- turns the instance into plain entities, they are saved with the scene from now on
function prefab.Unpack(entity)
	local component = entity.prefab
	assert(component and component.definition, "entity is not a prefab instance")

	for _, node in pairs(component.nodes) do
		if node ~= entity then
			node.prefab_owner = nil
			node.prefab_node = nil
		end
	end

	component.definition.instances[component] = nil
	dirty[component] = nil
	dirty_properties[component] = nil
	component.definition = nil
	entity:RemoveComponent("prefab")
end

-- the instance whose definition holds this entity or component, nil when it belongs to the entity itself
-- the name of the component an object is on its entity, "entity" for the entity itself, and that entity
function prefab.GetComponentName(object)
	if object.component_map then return "entity", object end

	local entity = object.Owner

	for key, component in pairs(entity.component_map) do
		if component == object then return key, entity end
	end

	return nil, entity
end

function prefab.GetOwner(object)
	local name, entity = prefab.GetComponentName(object)

	if name == "entity" then name = nil end

	local outer, own = entity.prefab_owner, entity.prefab

	if own and own.definition and name and not INSTANCE_COMPONENTS[name] then
		if own.owned[entity][name] or not (outer and outer.owned[entity][name]) then
			return own
		end
	end

	return outer
end

do
	local function capture_entity(state, entity, id, parent_id)
		local component = state.component
		local is_root = parent_id == nil
		local record = scene.SerializeRecord(entity, id, parent_id, is_root)

		if is_root then
			record.properties = nil

			for name in pairs(INSTANCE_COMPONENTS) do
				record.components[name] = nil
			end
		end

		local owned = {}

		for name in pairs(record.components) do
			owned[name] = true
		end

		state.records[#state.records + 1] = record
		state.nodes[id] = entity
		state.owned[entity] = owned
		local generated = scene.GetGeneratedChildren(entity)

		for _, child in ipairs(entity:GetChildren()) do
			local foreign = child.prefab_owner and child.prefab_owner ~= component

			if
				not foreign and
				not (
					generated and
					generated[child]
				)
				and
				not scene.IsTransientEntity(child, true)
			then
				capture_entity(state, child, child.prefab_node or objects.GenerateGUID(), id)
			end
		end
	end

	-- the root and every node below it as records, children the instance generated for another prefab stay with that prefab
	function prefab.Capture(root, component)
		local state = {component = component, records = {}, nodes = {}, owned = {}}
		capture_entity(state, root, ROOT, nil)
		return state
	end
end

-- an input cannot keep pointing at a node or component the editor removed
local function prune_targets(definition, records)
	local by_id = {}
	local pruned = false

	for _, record in ipairs(records) do
		by_id[record.guid] = record
	end

	for _, input in ipairs(definition.inputs) do
		for i = #input.Targets, 1, -1 do
			local target = input.Targets[i]
			local record = by_id[target.Node]

			if
				not record or
				(
					target.Component ~= "entity" and
					not record.components[target.Component]
				)
			then
				table.remove(input.Targets, i)
				pruned = true
			end
		end
	end

	return pruned
end

-- the editor changed a property of an object that belongs to an instance, only this property is written to the definition
function prefab.MarkDirty(object, var_name)
	if suppressed > 0 then return end

	local component = prefab.GetOwner(object)

	if not component then return end

	local objects_edited = dirty_properties[component]

	if not objects_edited then
		objects_edited = {}
		dirty_properties[component] = objects_edited
	end

	local names = objects_edited[object]

	if not names then
		names = {}
		objects_edited[object] = names
	end

	names[var_name] = true
end

-- for entities that gained or lost components or children, the instance they belong to or are the root of is captured again
function prefab.MarkStructureDirty(entity)
	local component = entity.prefab_owner or entity.prefab

	if component and component.definition then dirty[component] = true end
end

-- writes what the instance looks like now into the definition and brings every other instance along
function prefab.Commit(component)
	local definition = component.definition
	local state = prefab.Capture(component.Owner, component)
	local previous = {}

	for _, record in ipairs(definition.entities) do
		previous[record.guid] = record
	end

	local changed = #state.records ~= #definition.entities

	for i, record in ipairs(state.records) do
		local old = previous[record.guid]

		if old then
			-- only the structure of a node that is already there is taken from the entities, its values were written when they were edited
			local merged = {guid = record.guid, parent = record.parent, properties = old.properties, components = {}}

			for name, properties in pairs(record.components) do
				merged.components[name] = old.components[name] or properties
			end

			record = merged
		end

		if old and scene.ValuesEqual(record, old) then
			state.records[i] = old
		else
			state.records[i] = record
			changed = true
		end
	end

	if prune_targets(definition, state.records) then changed = true end

	-- a node that was moved out of the instance is a plain entity again, whatever it was moved into captures it on its own
	for id, entity in pairs(component.nodes) do
		if id ~= ROOT and not state.nodes[id] and entity:IsValid() then
			entity.prefab_owner = nil
			entity.prefab_node = nil
			local parent = entity:GetParent()

			if parent:IsValid() then prefab.MarkStructureDirty(parent) end
		end
	end

	component.nodes = state.nodes
	component.owned = state.owned
	component.applied = {}

	for _, record in ipairs(state.records) do
		local entity = state.nodes[record.guid]
		component.applied[record.guid] = record

		if record.parent then
			entity.prefab_owner = component
			entity.prefab_node = record.guid
		end
	end

	if not changed then return false end

	definition.entities = state.records
	definition.revision = definition.revision + 1

	for other in pairs(definition.instances) do
		if other ~= component then prefab.Sync(other) end
	end

	if definition.saved then
		pending_saves[definition] = system.GetElapsedTime() + SAVE_DELAY
	end

	event.Call("PrefabChanged", definition)

	return true
end

local function copy_record(old)
	local record = {guid = old.guid, parent = old.parent, components = {}}

	if old.properties then record.properties = table.shallow_copy(old.properties) end

	for name, properties in pairs(old.components) do
		record.components[name] = table.shallow_copy(properties)
	end

	return record
end

local function is_bound(definition, node, component_name, property)
	for _, input in ipairs(definition.inputs) do
		for _, target in ipairs(input.Targets) do
			if
				target.Node == node and
				target.Component == component_name and
				target.Property == property
			then
				return true
			end
		end
	end

	return false
end

-- writes the properties that were edited into the records of their nodes and nothing else, what scripts or physics changed on the instance is not an edit
function prefab.CommitProperties(component, edited)
	local definition = component.definition
	local by_id = {}
	local replaced = {}

	for _, record in ipairs(definition.entities) do
		by_id[record.guid] = record
	end

	for object, names in pairs(edited) do
		if object:IsValid() then
			local component_name, entity = prefab.GetComponentName(object)
			local node = entity == component.Owner and ROOT or entity.prefab_node

			for name in pairs(names) do
				local info = objects.GetPropertyInfo(getmetatable(object), name)

				if node and info and info.storable then
					local value = object[info.get_name](object)
					local input = prefab.FindInput(component.Path, node, component_name, name)

					if input then
						-- a linked property shows its input, changing it changes the input of this instance and so every property that follows it
						if not scene.ValuesEqual(value, get_input_value(component, input)) then
							component:SetInput(input.Name, copy_value(value))
						end
					elseif by_id[node] and not is_bound(definition, node, component_name, name) then
						local record = replaced[node]

						if not record then
							record = copy_record(by_id[node])
							replaced[node] = record
						end

						local container

						if component_name == "entity" then
							record.properties = record.properties or {}
							container = record.properties
						else
							container = record.components[component_name]
						end

						if container then
							if
								value == nil or
								scene.ValuesEqual(value, info.default) or
								not scene.IsSerializable(value)
							then
								container[name] = nil
							else
								container[name] = copy_value(value)
							end
						end
					end
				end
			end
		end
	end

	local entities = {}
	local changed = false

	for i, record in ipairs(definition.entities) do
		local new = replaced[record.guid]

		if new then
			if new.properties and next(new.properties) == nil then new.properties = nil end

			if scene.ValuesEqual(new, record) then
				new = nil
			else
				changed = true
				component.applied[record.guid] = new
			end
		end

		entities[i] = new or record
	end

	if not changed then return false end

	definition.entities = entities
	definition.revision = definition.revision + 1

	for other in pairs(definition.instances) do
		if other ~= component then prefab.Sync(other) end
	end

	if definition.saved then
		pending_saves[definition] = system.GetElapsedTime() + SAVE_DELAY
	end

	event.Call("PrefabChanged", definition)

	return true
end

-- what was marked since the last time is written to the definitions
function prefab.Flush()
	if next(dirty) ~= nil then
		local pending = dirty
		dirty = {}

		for component in pairs(pending) do
			if component.definition then prefab.Commit(component) end
		end
	end

	if next(dirty_properties) ~= nil then
		local pending = dirty_properties
		dirty_properties = {}

		for component, edited in pairs(pending) do
			if component.definition then prefab.CommitProperties(component, edited) end
		end
	end
end

event.AddListener("Update", "prefab_commit", function()
	prefab.Flush()

	if next(pending_saves) ~= nil then
		local now = system.GetElapsedTime()

		for definition, due in pairs(pending_saves) do
			if now >= due then
				pending_saves[definition] = nil
				prefab.Save(definition.name)
			end
		end
	end
end)

-- an instance that only has what is drawn, for thumbnails, it is transient and the caller removes it
function prefab.CreatePreview(name)
	previewing = true
	local ok, entity = pcall(Entity.New, {Name = name, Transient = true, prefab = {Path = name}})
	previewing = false

	if not ok then error(entity, 0) end

	return entity
end

-- a plain summary of a definition for the asset browser
function prefab.Describe(name)
	local definition = prefab.Get(name)
	local used = {}
	local scripts = 0

	for _, record in ipairs(definition.entities) do
		for component_name in pairs(record.components) do
			used[component_name] = true
		end

		if record.components.script then scripts = scripts + 1 end
	end

	local components = {}

	for component_name in pairs(used) do
		components[#components + 1] = component_name
	end

	table.sort(components)
	local dependencies = {}

	for dependency in pairs(prefab.GetDependencies(name)) do
		dependencies[#dependencies + 1] = dependency
	end

	table.sort(dependencies)
	local instances = 0

	for _ in pairs(definition.instances) do
		instances = instances + 1
	end

	return {
		nodes = #definition.entities,
		components = components,
		scripts = scripts,
		inputs = definition.inputs,
		dependencies = dependencies,
		instances = instances,
		saved = definition.saved == true,
		builtin = definition.builtin == true,
	}
end

-- the entity and everything below it becomes a prefab and the entity becomes an instance of it
function prefab.CreateFromEntity(entity, name)
	assert(not entity.prefab, "unpack the instance before making a prefab of it")
	assert(not entity.prefab_owner, "a prefab cannot be made from inside another instance")
	assert(not list.has_value(prefab.GetNames(), name), "a prefab named " .. name .. " already exists")
	local state = prefab.Capture(entity)
	local definition = prefab.Register(name, {inputs = {}, entities = state.records})
	prefab.Save(name)

	for _, node in pairs(state.nodes) do
		if node ~= entity and node:IsValid() and node:GetParent() == entity then
			node:Remove()
		end
	end

	for component_name in pairs(state.owned[entity]) do
		entity:RemoveComponent(component_name)
	end

	entity:AddComponent("prefab", {Path = name})
	event.Call("PrefabChanged", definition)
	event.Call("PrefabInputsChanged", definition)

	return definition
end

for name, data in pairs(import("goluwa/entities/prefabs/shapes.lua")) do
	prefab.Register(name, data).builtin = true
end

return prefab
