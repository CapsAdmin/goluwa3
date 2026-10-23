local toolgun = import("lua/toolgun.lua")
local game_history = import("lua/game_history.lua")
return toolgun.Register{
	Name = "remover",
	DisplayName = "Remover",
	Category = "Construction",
	Description = "Removes objects and the constraints attached to them.",
	Instructions = {
		Left = "remove an object",
		Right = "remove an object and everything constrained to it",
		Reload = "remove every constraint from an object",
	},
	LeftClick = function(context, trace)
		local entity = trace.entity

		if not entity then return false end

		if entity.ragdoll_part then entity = entity.ragdoll_part.Character end

		if entity:GetTransient() or entity.player_controller then return false end

		local entities = toolgun.GetConstraints(entity)
		list.insert(entities, 1, entity)
		context:Record(game_history.Remove("remove " .. entity:GetName(), entities))
		return true
	end,
	RightClick = function(context, trace)
		if not toolgun.IsProp(trace.entity) then return false end

		local entities, links = toolgun.GetContraption(trace.entity)
		list.extend(entities, links)
		context:Record(game_history.Remove("remove contraption", entities))
		return true
	end,
	Reload = function(context, trace)
		if not toolgun.IsProp(trace.entity) then return false end

		local found = toolgun.GetConstraints(trace.entity)

		if not found[1] then return false end

		context:Record(game_history.Remove("remove constraints", found))
		return true
	end,
}
