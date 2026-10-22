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

function game_history.RecordSpawn(name, entity)
	local snap = snapshot(entity)
	local guid = snap.guid
	game_history.history:Push{
		Name = name,
		Undo = function()
			local target = objects.GetObjectByGUID(guid)

			if not target:IsValid() then return end

			snap = snapshot(target)
			target:Remove()
		end,
		Redo = function()
			local root = scene.Deserialize(snap.data, resolve_entity(snap.parent))[1]
			root:SetOwnedBy(snap.owner)
		end,
	}
	return entity
end

return game_history
