local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local name_prompt = import("lua/name_prompt.lua")
local camera = import("lua/camera.lua")
local editor_history = import("lua/editor_history.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local tools = library()
local PLACE_DISTANCE = 4
local EXPOSABLE_TYPES = {
	number = true,
	boolean = true,
	string = true,
	vec2 = true,
	vec3 = true,
	vec4 = true,
	quat = true,
	ang3 = true,
	color = true,
}
-- what a new input without targets can hold, a script reads and writes it
local INPUT_TYPES = {
	{Text = "number", Type = "number", Default = function() return 0 end},
	{Text = "boolean", Type = "boolean", Default = function() return false end},
	{Text = "string", Type = "string", Default = function() return "" end},
	{Text = "vec3", Type = "vec3", Default = function() return Vec3(0, 0, 0) end},
	{Text = "color", Type = "color", Default = function() return Color(1, 1, 1, 1) end},
}
local removers = {}

local function on_property_changed(object, var_name, _, _, info)
	if info and info.storable then prefab.MarkDirty(object, var_name) end
end

-- edits made to the selected entity of an instance are written back to the prefab, the gizmo and the property editor both end up here
function tools.Watch(target)
	for i = #removers, 1, -1 do
		removers[i]()
		removers[i] = nil
	end

	if not (target and (target.prefab_owner or target.prefab)) then return end

	removers[#removers + 1] = target:AddPropertyListener(on_property_changed, "prefab_editor")

	for _, component in ipairs(target.component_list) do
		removers[#removers + 1] = component:AddPropertyListener(on_property_changed, "prefab_editor")
	end
end

function tools.Place(name)
	local entity = Entity.New{Name = name, prefab = {Path = name}}
	entity:SetTransient(false)
	entity.transform:SetPosition(camera.GetPosition() + camera.GetRotation():GetForward() * PLACE_DISTANCE)
	editor_history.RecordCreate("place " .. name, entity)
	return entity
end

local function get_unique_input_name(definition, base)
	local taken = {}

	for _, input in ipairs(definition.inputs) do
		taken[input.Name] = true
	end

	if base == "Path" or base == "Inputs" then base = base .. " value" end

	local name, n = base, 2

	while taken[name] do
		name = base .. " " .. n
		n = n + 1
	end

	return name
end

local function expose(instance, entity, node, component_name, object, info)
	local name = info.var_name

	for _, input in ipairs(instance.definition.inputs) do
		if input.Name == name then
			name = (entity:GetName() ~= "" and entity:GetName() or node) .. " " .. name

			break
		end
	end

	local value = objects.GetProperty(object, info.var_name)
	editor_history.EditPrefab(
		"expose " .. info.var_name .. " of " .. instance.Path,
		instance.Path,
		function()
			prefab.AddInput(
				instance.Path,
				{
					Name = get_unique_input_name(instance.definition, name),
					Type = info.type,
					Default = type(value) == "cdata" and value:Copy() or value,
					Targets = {{Node = node, Component = component_name, Property = info.var_name}},
				}
			)
		end
	)
end

local function unexpose(instance, node, component_name, info)
	editor_history.EditPrefab(
		"hide " .. info.var_name .. " from " .. instance.Path,
		instance.Path,
		function()
			prefab.Unlink(instance.Path, node, component_name, info.var_name)
		end
	)
end

local function add_input(instance, input_type)
	name_prompt{
		Title = "ADD " .. input_type.Text:upper() .. " INPUT",
		Hint = "input name",
		OnSubmit = function(name)
			editor_history.EditPrefab(
				"add input " .. name .. " to " .. instance.Path,
				instance.Path,
				function()
					prefab.AddInput(
						instance.Path,
						{
							Name = get_unique_input_name(instance.definition, name),
							Type = input_type.Type,
							Default = input_type.Default(),
							Targets = {},
						}
					)
				end
			)
		end,
	}
end

-- right click items for a property: on a prefab instance a new input without targets, on a property of a node the link to an input
function tools.GetPropertyActions(object, info)
	if object.Type == "prefab" and object.definition then
		local type_actions = {}

		for _, input_type in ipairs(INPUT_TYPES) do
			type_actions[#type_actions + 1] = {
				Text = input_type.Text,
				OnClick = function()
					add_input(object, input_type)
				end,
			}
		end

		return {{Text = "Add input", Icon = "plus", Items = type_actions}}
	end

	if
		not (
			info.storable and
			EXPOSABLE_TYPES[info.type]
		)
		or
		not (
			object.component_map or
			object.Owner
		)
	then
		return
	end

	local instance = prefab.GetOwner(object)

	if not instance then return end

	local component_name, entity = prefab.GetComponentName(object)
	local node = instance == entity.prefab and "root" or entity.prefab_node

	if prefab.IsExposed(instance.Path, node, component_name, info.var_name) then
		return {
			{
				Text = "Hide from prefab",
				Icon = "close",
				OnClick = function()
					unexpose(instance, node, component_name, info)
				end,
			},
		}
	end

	local link_actions = {
		{
			Text = "New input",
			Icon = "plus",
			OnClick = function()
				expose(instance, entity, node, component_name, object, info)
			end,
		},
	}

	for _, input in ipairs(instance.definition.inputs) do
		if input.Type == info.type and not input.Hidden then
			link_actions[#link_actions + 1] = {
				Text = "Link to " .. input.Name,
				Icon = "arrow_right",
				OnClick = function()
					editor_history.EditPrefab(
						"link " .. info.var_name .. " to " .. input.Name,
						instance.Path,
						function()
							prefab.AddTarget(
								instance.Path,
								input.Name,
								{Node = node, Component = component_name, Property = info.var_name}
							)
						end
					)
				end,
			}
		end
	end

	if #link_actions == 1 then
		return {{Text = "Show in prefab", Icon = "layers", OnClick = link_actions[1].OnClick}}
	end

	return {{Text = "Show in prefab", Icon = "layers", Items = link_actions}}
end

-- the Tab puts what only this instance has, and the prefab it is an instance of, apart from what is shared with every instance
local SHARED_BADGE = {
	Text = "shared",
	Color = "text_on_accent",
	Tab = "Shared",
	HideWithTabs = true,
	Tooltip = "Edits change the prefab and every instance of it",
}
local INSTANCE_BADGE = {
	Text = "this instance",
	Color = "text_on_accent",
	Tab = "Instance",
	HideWithTabs = true,
	Tooltip = "Only this instance has this, not the prefab",
}
local PREFAB_BADGE = {
	Text = "prefab",
	Color = "text_on_accent",
	Tab = "Instance",
	HideWithTabs = true,
	Tooltip = "The prefab this entity is an instance of",
}

-- a label for the header of a component of something that is part of a prefab: shared with the prefab, only this instance, or a script that failed
function tools.GetCategoryBadge(object, name)
	local entity = object.component_map and object or object.Owner

	if not (entity and (entity.prefab or entity.prefab_owner)) then return end

	if name == "script" and object.Error then
		return {
			Text = "error",
			Color = "text_on_accent",
			HeaderColor = "negative",
			Tab = "Shared",
			Tooltip = object.Error:match("[^\n]*"),
		}
	end

	if name == "prefab" then return PREFAB_BADGE end

	if prefab.GetOwner(object) then return SHARED_BADGE end

	return INSTANCE_BADGE
end

-- a property an input pushes into is marked with the input, its value here is not the one that sticks
function tools.GetPropertyBadge(object, info)
	if not (info.storable and (object.component_map or object.Owner)) then return end

	local instance = prefab.GetOwner(object)

	if not instance then return end

	local component_name, entity = prefab.GetComponentName(object)
	local node = instance == entity.prefab and "root" or entity.prefab_node
	local input = prefab.FindInput(instance.Path, node, component_name, info.var_name)

	if input then
		return {
			Text = "<- " .. input.Name,
			Color = "positive",
			Tooltip = "Linked to the prefab input " .. input.Name .. ", changing it here changes the input of this instance",
		}
	end
end

function tools.GetMenuItems(entity, select)
	local items = {}

	if entity.prefab and entity.prefab.definition then
		items[#items + 1] = MenuItem{
			Text = "Unpack",
			Icon = "expand",
			OnClick = function()
				editor_history.ReplaceEntity("unpack " .. entity:GetName(), entity, function()
					prefab.Unpack(entity)
				end)
			end,
		}
	elseif not entity.prefab_owner then
		items[#items + 1] = MenuItem{
			Text = "Make prefab",
			Icon = "layers",
			OnClick = function()
				name_prompt{
					Title = "MAKE PREFAB",
					Text = entity:GetName(),
					OnSubmit = function(name)
						editor_history.ReplaceEntity("make prefab " .. name, entity, function()
							prefab.CreateFromEntity(entity, (name:gsub("[^%w_%-%. ]", "_")))
						end)
						select(entity)
					end,
				}
			end,
		}
	end

	local place_items = tools.GetPlaceItems(select)

	if place_items[1] then
		items[#items + 1] = MenuItem{
			Text = "Place",
			Icon = "place",
			Items = function()
				return place_items
			end,
		}
	end

	return items
end

function tools.GetPlaceItems(select)
	local items = {}

	for _, name in ipairs(prefab.GetNames()) do
		items[#items + 1] = MenuItem{
			Text = name,
			Icon = "layers",
			OnClick = function()
				select(tools.Place(name))
			end,
		}
	end

	return items
end

return tools
