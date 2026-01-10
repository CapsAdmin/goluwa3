local prototype = require("prototype")
local event = require("event")
local ecs = library()
ecs.registered_components = {}

function ecs.RegisterComponent(component_meta)
	local name = component_meta.ComponentName or component_meta.ClassName
	ecs.registered_components[name] = component_meta
	return component_meta
end

function ecs.GetComponent(name)
	return ecs.registered_components[name]
end

local ENTITY = prototype.CreateTemplate("ecs", "entity")
prototype.ParentingTemplate(ENTITY)
ENTITY:GetSet("ComponentsHash", {})

function ENTITY:Initialize()
	self.ComponentsHash = {}
end

function ENTITY:AddComponent(name_or_meta)
	local meta = name_or_meta

	if type(name_or_meta) == "string" then
		meta = ecs.GetComponent(name_or_meta)

		if not meta then error("Unknown component: " .. name_or_meta) end
	end

	local component_name = meta.ComponentName or meta.ClassName

	if self.ComponentsHash[component_name] then
		return self.ComponentsHash[component_name]
	end

	if meta.Require then
		for _, required_name in ipairs(meta.Require) do
			if not self:HasComponent(required_name) then
				self:AddComponent(required_name)
			end
		end
	end

	local component = prototype.CreateObject(meta)
	component.Entity = self
	self.ComponentsHash[component_name] = component
	self[component_name] = component

	if component.Initialize then component:Initialize() end

	if component.OnAdd then component:OnAdd(self) end

	if meta.Events then
		for _, event_type in ipairs(meta.Events) do
			component:AddEvent(event_type)
		end
	end

	for name, other_component in pairs(self.ComponentsHash) do
		if other_component ~= component and other_component.OnEntityAddComponent then
			other_component:OnEntityAddComponent(component)
		end
	end

	return component
end

function ENTITY:RemoveComponent(name)
	local component = self.ComponentsHash[name]

	if not component then return end

	if component.added_events then
		for event_type in pairs(component.added_events) do
			component:RemoveEvent(event_type)
		end
	end

	if component.OnRemove then component:OnRemove() end

	self.ComponentsHash[name] = nil
	self[name] = nil
end

function ENTITY:GetComponent(name)
	return self.ComponentsHash[name]
end

function ENTITY:HasComponent(name)
	return self.ComponentsHash[name] ~= nil
end

function ENTITY:OnRemove()
	for name, component in pairs(self.ComponentsHash) do
		if component.added_events then
			for event_type in pairs(component.added_events) do
				component:RemoveEvent(event_type)
			end
		end

		if component.OnRemove then component:OnRemove() end
	end

	self.ComponentsHash = {}

	-- Unparent
	if self:HasParent() then self:UnParent() end

	-- Remove children
	if self:HasChildren() then
		local children = self:GetChildren()

		for i = #children, 1, -1 do
			children[i]:Remove()
		end
	end
end

ENTITY:Register()

function ecs.CreateEntity(name, parent)
	if name ~= "world" then parent = parent or ecs.GetWorld() end

	local entity = ENTITY:CreateObject()
	entity:Initialize()
	entity:SetName(name or "")

	if parent and parent:IsValid() then entity:SetParent(parent) end

	return entity
end

function ecs.CreateFromTable(config)
	local entity = ecs.CreateEntity(config.Name, config.Parent)

	for component_name, component_data in pairs(config) do
		if component_name == "Name" or component_name == "Parent" then

		else
			local component = entity:AddComponent(component_name)

			for key, value in pairs(component_data) do
				component["Set" .. key](component, value)
			end
		end
	end

	return entity
end

local world_entity = nil

function ecs.GetWorld()
	if not world_entity or not world_entity:IsValid() then
		world_entity = ecs.CreateEntity("world")
	end

	return world_entity
end

function ecs.ClearWorld()
	if world_entity and world_entity:IsValid() then world_entity:Remove() end

	world_entity = nil
end

do
	local function collect(entity, component_name, result)
		if entity:HasComponent(component_name) then table.insert(result, entity) end

		for _, child in ipairs(entity:GetChildren()) do
			collect(child, component_name, result)
		end
	end

	function ecs.GetEntitiesWithComponent(component_name)
		local result = {}
		collect(ecs.GetWorld(), component_name, result)
		return result
	end
end

function ecs.GetComponents(component_name)
	local result = {}

	for i, entity in ipairs(ecs.GetEntitiesWithComponent(component_name)) do
		result[i] = entity:GetComponent(component_name)
	end

	return result
end

return ecs
