local prototype = require("prototype")
local event = require("event")
local ecs = library()
ecs.component_instances = ecs.component_instances or {}
ecs.systems = ecs.systems or {}

local function remove_component(component)
	local component_name = component.ComponentName or component.Type
	local instances = ecs.component_instances[component_name]

	if instances then
		for i = #instances, 1, -1 do
			if instances[i] == component then
				table.remove(instances, i)

				break
			end
		end

		if #instances == 0 then
			local system = ecs.systems[component_name]

			if system and system.Stop then system.Stop() end
		end
	end

	if component.Entity then
		component.Entity.ComponentsHash[component_name] = nil
		component.Entity[component_name] = nil
	end
end

local ENTITY = prototype.CreateTemplate("entity")
prototype.ParentingTemplate(ENTITY)
ENTITY:GetSet("ComponentsHash", {})
ecs.focused_entity = NULL

function ecs.SetFocusedEntity(entity)
	if ecs.focused_entity == entity then return end

	local old = ecs.focused_entity

	if old and old:IsValid() then
		if old.OnUnfocus then old:OnUnfocus() end

		for _, comp in pairs(old.ComponentsHash) do
			if comp.OnUnfocus then comp:OnUnfocus() end
		end
	end

	ecs.focused_entity = entity

	if entity and entity:IsValid() then
		if entity.OnFocus then entity:OnFocus() end

		for _, comp in pairs(entity.ComponentsHash) do
			if comp.OnFocus then comp:OnFocus() end
		end
	end
end

function ecs.GetFocusedEntity()
	return ecs.focused_entity
end

function ENTITY:Initialize()
	self.ComponentsHash = {}
	self.Children = {}
	self.ChildrenMap = {}
end

function ENTITY:AddComponent(meta)
	local provider = nil

	if type(meta) == "table" and meta.Component then
		provider = meta
		meta = meta.Component
	end

	if not meta.ComponentName and not meta.Type then debug.trace() end

	local component_name = assert(meta.ComponentName or meta.Type)

	if provider and not ecs.systems[component_name] then
		ecs.systems[component_name] = {
			Start = provider.StartSystem,
			Stop = provider.StopSystem,
		}
		local instances = ecs.component_instances[component_name]

		if instances and #instances > 0 then
			if provider.StartSystem then provider.StartSystem() end
		end
	end

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

	ecs.component_instances[component_name] = ecs.component_instances[component_name] or {}
	local is_first = #ecs.component_instances[component_name] == 0
	list.insert(ecs.component_instances[component_name], component)

	if is_first then
		local system = ecs.systems[component_name]

		if system and system.Start then system.Start() end
	end

	component:CallOnRemove(remove_component)
	return component
end

function ENTITY:RemoveComponent(name)
	local component = self.ComponentsHash[name]

	if not component then return end

	component:Remove()
	self.ComponentsHash[name] = nil
	self[name] = nil
end

function ENTITY:GetComponent(name)
	return self.ComponentsHash[name]
end

function ENTITY:HasComponent(name)
	return self.ComponentsHash[name] ~= nil
end

function ENTITY:RequestFocus()
	ecs.SetFocusedEntity(self)
end

function ENTITY:OnRemove()
	for name, component in pairs(self.ComponentsHash) do
		component:Remove()
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
	if parent == nil and name ~= "world" and name ~= "world_2d" then
		parent = ecs.Get3DWorld()
	end

	local entity = ENTITY:CreateObject()
	entity:Initialize()
	entity:SetName(name or "")

	if parent and parent:IsValid() then entity:SetParent(parent) end

	return entity
end

function ecs.CreateFromTable(config)
	local entity = ecs.CreateEntity(config.Name, config.Parent)

	for component, component_props in pairs(config) do
		if type(component) == "table" then
			local inst = entity:AddComponent(component)

			for key, value in pairs(component_props) do
				inst["Set" .. key](inst, value)
			end
		end
	end

	return entity
end

function ecs.GetComponents(component_name)
	return ecs.component_instances[component_name] or {}
end

do
	local world_entity = nil

	function ecs.Get3DWorld()
		if not world_entity or not world_entity:IsValid() then
			world_entity = ecs.CreateEntity("world")
		end

		return world_entity
	end

	function ecs.Clear3DWorld()
		if world_entity and world_entity:IsValid() then world_entity:Remove() end

		world_entity = nil
	end
end

do
	local world_entity = nil

	function ecs.Get2DWorld()
		if not world_entity or not world_entity:IsValid() then
			world_entity = ecs.CreateEntity("world_2d", false)
		end

		return world_entity
	end

	function ecs.Clear2DWorld()
		if world_entity and world_entity:IsValid() then world_entity:Remove() end

		world_entity = nil
	end
end

return ecs
