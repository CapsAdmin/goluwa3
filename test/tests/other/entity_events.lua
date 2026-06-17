local T = import("test/environment.lua")
local Entity = import("goluwa/ecs/entity.lua")

T.Test("entity world hierarchy change events", function()
	local events = {}
	local parent_a = Entity.New({Name = "entity_event_parent_a"})
	local parent_b = Entity.New({Name = "entity_event_parent_b"})
	local remove_listener = Entity.World:AddLocalListener("OnEntityHierarchyChanged", function(_, entity, action, parent)
		events[#events + 1] = {
			entity = entity,
			action = action,
			parent = parent,
		}
	end)
	local child = Entity.New{Name = "entity_event_child", Parent = parent_a}
	T(#events)["=="](1)
	T(events[1].entity)["=="](child)
	T(events[1].action)["=="]("parented")
	T(events[1].parent)["=="](parent_a)
	events = {}
	child:SetParent(parent_b)
	T(#events)["=="](2)
	T(events[1].entity)["=="](child)
	T(events[1].action)["=="]("unparented")
	T(events[1].parent)["=="](parent_a)
	T(events[2].entity)["=="](child)
	T(events[2].action)["=="]("parented")
	T(events[2].parent)["=="](parent_b)
	remove_listener()
	child:Remove()
	parent_a:Remove()
	parent_b:Remove()
end)

T.Test("entity component change events and bookkeeping", function()
	local events = {}
	local entity = Entity.New({Name = "entity_component_events"})
	local remove_listener = Entity.World:AddLocalListener("OnEntityComponentChanged", function(_, changed_entity, action, name, component)
		events[#events + 1] = {
			entity = changed_entity,
			action = action,
			name = name,
			component = component,
		}
	end)
	local transform = entity:AddComponent("transform")
	T(#events)["=="](1)
	T(events[1].entity)["=="](entity)
	T(events[1].action)["=="]("added")
	T(events[1].name)["=="]("transform")
	T(events[1].component)["=="](transform)
	T(#entity.component_list)["=="](1)
	events = {}
	entity:RemoveComponent("transform")
	T(#events)["=="](1)
	T(events[1].entity)["=="](entity)
	T(events[1].action)["=="]("removed")
	T(events[1].name)["=="]("transform")
	T(events[1].component)["=="](transform)
	T(entity:HasComponent("transform"))["=="](false)
	T(#entity.component_list)["=="](0)
	remove_listener()
	entity:Remove()
end)
