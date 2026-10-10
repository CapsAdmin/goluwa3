local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local History = import("goluwa/history.lua")
local scene = import("goluwa/entities/scene.lua")
local prefab = import("goluwa/entities/prefab.lua")
local ops = library()
local history = History.New()
ops.history = history

local function copy_value(value)
	local kind = type(value)

	if kind == "cdata" then return value:Copy() end

	if kind == "table" and not getmetatable(value) then return table.copy(value) end

	return value
end

local function values_equal(a, b)
	if type(a) == "cdata" and type(b) == "cdata" then
		return ffi.string(a, ffi.sizeof(a)) == ffi.string(b, ffi.sizeof(b))
	end

	return scene.ValuesEqual(a, b)
end

local function resolve_entity(guid)
	local entity = objects.GetObjectByGUID(guid)
	assert(entity:IsValid(), "history: the entity " .. guid .. " no longer exists")
	return entity
end

-- an object is addressed by the guid of its entity and the name of its component, so it can be found again after the entity was removed and restored
local function get_ref(object)
	if object.component_map then return {guid = object:GetGUID()} end

	if not object.Owner then return {object = object} end

	local name, entity = prefab.GetComponentName(object)

	if not name then return {object = object} end

	return {guid = entity:GetGUID(), component = name}
end

local function resolve_ref(ref)
	if ref.object then return ref.object end

	local entity = resolve_entity(ref.guid)

	if ref.component then return entity.component_map[ref.component] end

	return entity
end

local function select_entity(guid)
	event.Call("EditorSelect", resolve_entity(guid))
end

local function get_entity_label(object)
	local entity = object.component_map and object or object.Owner

	if entity and entity.GetName and entity:GetName() ~= "" then
		return entity:GetName()
	end

	return object.Type or "object"
end

local function set_property(target, info, value)
	objects.SetProperty(target, info.var_name, value)
end

-- an entity and everything below it as a scene record, an entity that was never meant to be saved is serialized anyway
local function snapshot(entity)
	local transient = entity.Transient
	entity.Transient = false
	local data = scene.SerializeEntities({entity})
	entity.Transient = transient
	assert(data.entities[1], "history: the entity cannot be serialized")
	return {
		data = data,
		parent = entity:GetParent():GetGUID(),
		guid = entity:GetGUID(),
		transient = transient,
	}
end

local function restore(snap)
	local parent = resolve_entity(snap.parent)
	local roots = scene.Deserialize(snap.data, parent)
	roots[1].Transient = snap.transient
	prefab.MarkStructureDirty(roots[1])
	return roots[1]
end

local function remove(guid)
	local entity = resolve_entity(guid)
	local parent = entity:GetParent()
	prefab.MarkStructureDirty(entity)
	entity:Remove()

	if parent:IsValid() then prefab.MarkStructureDirty(parent) end
end

function ops.Begin(name)
	history:Begin(name)
end

function ops.End()
	history:End()
end

-- for edits that cannot be undone, what came before them can no longer be applied
function ops.Barrier(reason)
	history:Clear()
	logn("editor history cleared: ", reason)
end

-- a property of an object was changed from old_value to new_value, set(target, info, value) applies a value
function ops.RecordProperty(target, info, old_value, new_value, set)
	if values_equal(old_value, new_value) then return end

	old_value = copy_value(old_value)
	new_value = copy_value(new_value)
	set = set or set_property
	local ref = get_ref(target)
	local var_name = info.var_name
	history:Push{
		Name = var_name .. " of " .. get_entity_label(target),
		Key = (ref.guid or tostring(ref.object)) .. "/" .. (ref.component or "") .. "/" .. var_name,
		Undo = function()
			if ref.guid then select_entity(ref.guid) end

			set(resolve_ref(ref), info, copy_value(old_value))
		end,
		Redo = function()
			if ref.guid then select_entity(ref.guid) end

			set(resolve_ref(ref), info, copy_value(new_value))
		end,
	}
end

function ops.SetProperty(target, var_name, value)
	local info = {var_name = var_name}
	local old_value = objects.GetProperty(target, var_name)
	set_property(target, info, value)
	ops.RecordProperty(target, info, old_value, objects.GetProperty(target, var_name))
end

function ops.AddComponent(entity, name)
	local guid = entity:GetGUID()
	local component = entity:AddComponent(name)
	prefab.MarkStructureDirty(entity)
	history:Push{
		Name = "add " .. name .. " to " .. get_entity_label(entity),
		Undo = function()
			select_entity(guid)
			local target = resolve_entity(guid)
			target:RemoveComponent(name)
			prefab.MarkStructureDirty(target)
		end,
		Redo = function()
			select_entity(guid)
			local target = resolve_entity(guid)
			target:AddComponent(name)
			prefab.MarkStructureDirty(target)
		end,
	}
	return component
end

function ops.EnsureComponent(entity, name)
	if entity:HasComponent(name) then return entity[name] end

	return ops.AddComponent(entity, name)
end

function ops.RemoveComponent(entity, name)
	local guid = entity:GetGUID()
	local properties = scene.SerializeProperties(entity[name]) or {}
	entity:RemoveComponent(name)
	prefab.MarkStructureDirty(entity)
	history:Push{
		Name = "remove " .. name .. " from " .. get_entity_label(entity),
		Undo = function()
			select_entity(guid)
			local target = resolve_entity(guid)
			local component = target:AddComponent(name)
			scene.SyncProperties(component, properties, name)

			if component.OnDeserialized then component:OnDeserialized() end

			prefab.MarkStructureDirty(target)
		end,
		Redo = function()
			select_entity(guid)
			local target = resolve_entity(guid)
			properties = scene.SerializeProperties(target[name]) or {}
			target:RemoveComponent(name)
			prefab.MarkStructureDirty(target)
		end,
	}
end

-- an entity that was just created
function ops.RecordCreate(name, entity)
	local snap = snapshot(entity)
	local guid = snap.guid
	prefab.MarkStructureDirty(entity:GetParent())
	history:Push{
		Name = name,
		Undo = function()
			local target = resolve_entity(guid)
			snap = snapshot(target)
			local parent = target:GetParent()
			remove(guid)

			if parent:IsValid() then event.Call("EditorSelect", parent) end
		end,
		Redo = function()
			event.Call("EditorSelect", restore(snap))
		end,
	}
	return entity
end

function ops.RemoveEntity(entity)
	local snap = snapshot(entity)
	local guid = snap.guid
	remove(guid)
	history:Push{
		Name = "remove " .. get_entity_label(entity),
		Undo = function()
			event.Call("EditorSelect", restore(snap))
		end,
		Redo = function()
			snap = snapshot(resolve_entity(guid))
			remove(guid)
		end,
	}
end

-- the entity was already moved from old_parent to new_parent
function ops.RecordReparent(entity, old_parent, new_parent)
	local guid = entity:GetGUID()
	local old_guid, new_guid = old_parent:GetGUID(), new_parent:GetGUID()
	prefab.MarkStructureDirty(old_parent)
	prefab.MarkStructureDirty(new_parent)

	local function move(parent_guid, from_guid)
		local target = resolve_entity(guid)
		local parent = resolve_entity(parent_guid)
		target:SetParent(parent)
		prefab.MarkStructureDirty(parent)
		prefab.MarkStructureDirty(resolve_entity(from_guid))
		select_entity(guid)
	end

	history:Push{
		Name = "move " .. get_entity_label(entity) .. " to " .. get_entity_label(new_parent),
		Undo = function()
			move(old_guid, new_guid)
		end,
		Redo = function()
			move(new_guid, old_guid)
		end,
	}
end

-- the entity is rebuilt from a scene record, for edits that replace or restructure the entity itself
function ops.ReplaceEntity(name, entity, edit)
	local before = snapshot(entity)
	edit()
	local after = snapshot(entity)
	local guid = before.guid

	local function replace(snap)
		remove(guid)
		event.Call("EditorSelect", restore(snap))
	end

	history:Push{
		Name = name,
		Undo = function()
			replace(before)
		end,
		Redo = function()
			replace(after)
		end,
	}
end

-- edits the definition of a prefab, its inputs and the nodes it is made of
function ops.EditPrefab(name, prefab_name, edit)
	local before = prefab.Snapshot(prefab_name)
	edit()
	local after = prefab.Snapshot(prefab_name)
	history:Push{
		Name = name,
		Undo = function()
			prefab.Restore(prefab_name, before)
		end,
		Redo = function()
			prefab.Restore(prefab_name, after)
		end,
	}
end

function ops.CaptureTransform(entity)
	local transform = entity.transform
	return {
		position = transform:GetPosition():Copy(),
		rotation = transform:GetRotation():Copy(),
		scale = transform:GetScale():Copy(),
	}
end

-- before is what CaptureTransform returned when the edit began
function ops.RecordTransform(name, entity, before)
	local after = ops.CaptureTransform(entity)

	if
		values_equal(before.position, after.position) and
		values_equal(before.rotation, after.rotation) and
		values_equal(before.scale, after.scale)
	then
		return
	end

	local guid = entity:GetGUID()

	local function apply(state)
		select_entity(guid)
		local transform = resolve_entity(guid).transform
		transform:SetPosition(state.position:Copy())
		transform:SetRotation(state.rotation:Copy())
		transform:SetScale(state.scale:Copy())
	end

	history:Push{
		Name = name .. " " .. get_entity_label(entity),
		Undo = function()
			apply(before)
		end,
		Redo = function()
			apply(after)
		end,
	}
end

function ops.CaptureBrush(brush)
	return {
		sides = brush:GetSides(),
		position = brush.Owner.transform:GetPosition():Copy(),
	}
end

function ops.RecordBrush(name, brush, before)
	local after = ops.CaptureBrush(brush)

	if
		values_equal(before.sides, after.sides) and
		values_equal(before.position, after.position)
	then
		return
	end

	local entity = brush.Owner
	local guid = entity:GetGUID()

	local function apply(state)
		select_entity(guid)
		local target = resolve_entity(guid)
		target.transform:SetPosition(state.position:Copy())
		target.brush.last_matrix = target.transform:GetWorldMatrix():Copy()
		target.brush:SetSides(state.sides)
	end

	history:Push{
		Name = name .. " " .. get_entity_label(entity),
		Undo = function()
			apply(before)
		end,
		Redo = function()
			apply(after)
		end,
	}
end

return ops
