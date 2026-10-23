local objects = import("goluwa/objects/objects.lua")
local History = import("goluwa/history.lua")
local scene = import("goluwa/entities/scene.lua")
local game_history = {}
game_history.history = History.New()

local function resolve_entity(guid)
	local entity = objects.GetObjectByGUID(guid)
	assert(entity:IsValid(), "history: the entity " .. guid .. " no longer exists")
	return entity
end

local function snapshot(entity)
	local data = scene.SerializeEntities({entity})
	assert(data.entities[1], "history: the entity cannot be serialized")
	return {
		data = data,
		parent = entity:GetParent():GetGUID(),
		guid = entity:GetGUID(),
		owner = entity:GetOwnedBy(),
	}
end

local function restore(snap)
	local root = scene.Deserialize(snap.data, resolve_entity(snap.parent))[1]
	root:SetOwnedBy(snap.owner)
	return root
end

function game_history.Spawned(name, entity)
	local snap = snapshot(entity)
	local guid = snap.guid
	return {
		Name = name,
		Undo = function()
			local target = objects.GetObjectByGUID(guid)

			if not target:IsValid() then return end

			snap = snapshot(target)
			target:Remove()
		end,
		Redo = function()
			restore(snap)
		end,
	}
end

function game_history.RecordSpawn(name, entity)
	game_history.history:Push(game_history.Spawned(name, entity))
	return entity
end

function game_history.Remove(name, entities)
	local snaps = {}

	for i, entity in ipairs(entities) do
		snaps[i] = snapshot(entity)
	end

	for _, entity in ipairs(entities) do
		if entity:IsValid() then entity:Remove() end
	end

	return {
		Name = name,
		Undo = function()
			for _, snap in ipairs(snaps) do
				if not objects.GetObjectByGUID(snap.guid):IsValid() then restore(snap) end
			end
		end,
		Redo = function()
			local targets = {}

			for i, snap in ipairs(snaps) do
				local target = objects.GetObjectByGUID(snap.guid)

				if target:IsValid() then
					snaps[i] = snapshot(target)
					targets[#targets + 1] = target
				end
			end

			for _, target in ipairs(targets) do
				if target:IsValid() then target:Remove() end
			end
		end,
	}
end

do
	local function apply(changes, field)
		for _, change in ipairs(changes) do
			local entity = resolve_entity(change.guid)
			local target = change.component and entity[change.component] or entity
			target["Set" .. change.key](target, change[field])
		end
	end

	function game_history.Change(name, entity, component, values)
		local target = component and entity[component] or entity
		local keys = {}

		for key in pairs(values) do
			keys[#keys + 1] = key
		end

		table.sort(keys)
		local changes = {}

		for _, key in ipairs(keys) do
			changes[#changes + 1] = {
				guid = entity:GetGUID(),
				component = component,
				key = key,
				old = target["Get" .. key](target),
				new = values[key],
			}
		end

		apply(changes, "new")
		return {
			Name = name,
			Undo = function()
				apply(changes, "old")
			end,
			Redo = function()
				apply(changes, "new")
			end,
		}
	end
end

function game_history.Group(name, entries)
	return {
		Name = name,
		Undo = function()
			for i = #entries, 1, -1 do
				entries[i].Undo()
			end
		end,
		Redo = function()
			for i = 1, #entries do
				entries[i].Redo()
			end
		end,
	}
end

return game_history
