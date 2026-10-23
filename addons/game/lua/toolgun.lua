local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local message = import("goluwa/network/message.lua")
local clients = import("goluwa/network/clients.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local game_history = import("lua/game_history.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local Constraint = import("lua/components/constraint.lua")
Entity.RegisterComponent("constraint", Constraint)
local toolgun = {}
import.loaded["lua/toolgun.lua"] = toolgun
toolgun.Range = 200
toolgun.Tools = {}
toolgun.List = {}
toolgun.Categories = {"Constraints", "Construction", "Physics"}
toolgun.state = {tool = "weld", settings = {}}
local player_states = table.weak("k")

function toolgun.Register(tool)
	assert(
		tool.Name and tool.DisplayName and tool.Category and tool.Description,
		"a tool needs Name, DisplayName, Category and Description"
	)
	tool.Settings = tool.Settings or {}
	tool.Instructions = tool.Instructions or {}
	tool.SettingsByKey = {}

	for _, setting in ipairs(tool.Settings) do
		tool.SettingsByKey[setting.Key] = setting
	end

	local existing = toolgun.Tools[tool.Name]

	if existing then
		toolgun.List[list.get_index(toolgun.List, existing)] = tool
	else
		toolgun.List[#toolgun.List + 1] = tool
	end

	toolgun.Tools[tool.Name] = tool
	return tool
end

function toolgun.GetTools(category)
	local found = {}

	for _, tool in ipairs(toolgun.List) do
		if tool.Category == category then found[#found + 1] = tool end
	end

	return found
end

local function get_state(player)
	return player_states[player] or toolgun.state
end

function toolgun.GetSelected(player)
	return get_state(player).tool
end

function toolgun.GetSetting(player, tool_name, key)
	local values = get_state(player).settings[tool_name]
	local value = values and values[key]

	if value ~= nil then return value end

	return toolgun.Tools[tool_name].SettingsByKey[key].Default
end

local function send_state(tool_name)
	if network.HasAuthority() then return end

	message.Send(
		"toolgun_state",
		toolgun.state.tool,
		tool_name,
		toolgun.state.settings[tool_name] or {}
	)
end

function toolgun.Select(tool_name)
	assert(toolgun.Tools[tool_name], "unknown tool " .. tostring(tool_name))
	toolgun.state.tool = tool_name
	send_state(tool_name)
	event.Call("ToolgunChanged", tool_name)
end

function toolgun.SetSetting(tool_name, key, value)
	local settings = toolgun.state.settings
	settings[tool_name] = settings[tool_name] or {}
	settings[tool_name][key] = value
	send_state(tool_name)
	event.Call("ToolgunChanged", tool_name, key)
end

if SERVER then
	message.AddListener("toolgun_state", function(client, selected, tool_name, settings)
		local player = _G.GetPlayerEntity(client)
		local tool = toolgun.Tools[tool_name]

		if not (player and player:IsValid() and tool and toolgun.Tools[selected]) then
			return
		end

		local state = player_states[player] or {settings = {}}
		player_states[player] = state
		state.tool = selected
		local clean = {}

		for _, setting in ipairs(tool.Settings) do
			local value = settings[setting.Key]

			if typex(value) == typex(setting.Default) then
				if type(value) == "number" then
					value = math.clamp(value, setting.Min or -math.huge, setting.Max or math.huge)
				end

				clean[setting.Key] = value
			end
		end

		state.settings[tool_name] = clean
	end)
end

function toolgun.IsProp(entity)
	return entity ~= nil and
		entity:IsValid() and
		entity.rigid_body ~= nil and
		not entity.rigid_body.WorldGeometry and
		not entity.character_movement and
		not entity.ragdoll_part and
		not entity:GetTransient()
end

function toolgun.GetClient(player)
	if player == _G.PLAYER_RIG or not player.network then
		return clients.GetLocalClient()
	end

	return clients.GetByUniqueID(player.network:GetNetworkOwner())
end

do
	local OPTIONS = {IncludeRigidBodies = true}

	function toolgun.Trace(player, view)
		local origin = player.transform:GetPosition() + player.character_movement:GetViewOffset()
		local forward = view:GetForward()
		local hit = physics.RayCast(origin, forward, toolgun.Range, player, nil, OPTIONS)

		if not hit then return nil end

		local entity = hit.entity
		local world = not (entity and entity:IsValid()) or hit.rigid_body.WorldGeometry == true
		return {
			entity = not world and entity or nil,
			world = world,
			position = hit.position,
			normal = hit.normal,
			distance = hit.distance,
			origin = origin,
			forward = forward,
		}
	end
end

function toolgun.MakeTarget(trace)
	local target = {
		entity = trace.entity,
		position = trace.position:Copy(),
		normal = trace.normal:Copy(),
	}

	if trace.entity then
		local body = trace.entity.rigid_body
		target.local_position = body:WorldToLocal(trace.position)
		target.local_normal = body.Rotation:GetConjugated():VecMul(trace.normal)
	end

	return target
end

function toolgun.GetTargetPosition(target)
	if target.entity then
		return target.entity.rigid_body:LocalToWorld(target.local_position)
	end

	return target.position
end

function toolgun.GetTargetNormal(target)
	if target.entity then
		return target.entity.rigid_body.Rotation:VecMul(target.local_normal)
	end

	return target.normal
end

function toolgun.GetConstraints(entity, kind)
	local found = {}

	for _, component in ipairs(Constraint.Instances) do
		if
			component:IsValid() and
			component:References(entity) and
			(
				not kind or
				component.Kind == kind
			)
		then
			found[#found + 1] = component.Owner
		end
	end

	return found
end

function toolgun.GetContraption(entity)
	local entities = {entity}
	local seen = {[entity] = true}
	local links = {}
	local linked = {}
	local i = 1

	while entities[i] do
		for _, constraint in ipairs(toolgun.GetConstraints(entities[i])) do
			if not linked[constraint] then
				linked[constraint] = true
				links[#links + 1] = constraint
			end

			for _, other in ipairs{constraint.constraint:GetEntities()} do
				if other:IsValid() and not seen[other] then
					seen[other] = true
					entities[#entities + 1] = other
				end
			end
		end

		i = i + 1
	end

	return entities, links
end

function toolgun.CreateConstraint(player, first, second, properties, anchor0, anchor1, axis)
	if not first.entity then
		first, second = second, first
		anchor0, anchor1 = anchor1, anchor0
	end

	local body0 = first.entity.rigid_body
	properties.Entity0 = first.entity:GetGUID()
	properties.Anchor0 = body0:WorldToLocal(anchor0)

	if second.entity then
		properties.Entity1 = second.entity:GetGUID()
		properties.Anchor1 = second.entity.rigid_body:WorldToLocal(anchor1)
	else
		properties.Anchor1 = anchor1:Copy()
	end

	if axis then
		properties.Axis = body0.Rotation:GetConjugated():VecMul(axis):GetNormalized()
	end

	local entity = Entity.New{
		Name = "constraint_" .. properties.Kind,
		Transient = false,
		network = SERVER and {} or nil,
		constraint = properties,
	}
	entity:SetOwnedBy(toolgun.GetClient(player))
	return entity
end

local function is_local(player)
	return not SERVER or player == _G.PLAYER_RIG
end

local Context = {}
Context.__index = Context

function toolgun.NewContext(weapon)
	return setmetatable({weapon = weapon, targets = {}, tool_name = nil}, Context)
end

function Context:GetPlayer()
	return self.weapon:GetParent()
end

function Context:GetTool()
	return toolgun.Tools[self.tool_name]
end

function Context:GetSetting(key)
	return toolgun.GetSetting(self:GetPlayer(), self.tool_name, key)
end

function Context:GetStage()
	return #self.targets
end

function Context:AddTarget(trace)
	local target = toolgun.MakeTarget(trace)
	self.targets[#self.targets + 1] = target
	return target
end

function Context:ClearTargets()
	list.clear(self.targets)
end

function Context:Record(entry)
	if is_local(self:GetPlayer()) then game_history.history:Push(entry) end
end

function Context:Refresh()
	local name = toolgun.GetSelected(self:GetPlayer())

	if self.tool_name ~= name then
		self.tool_name = name
		self:ClearTargets()
	end

	for _, target in ipairs(self.targets) do
		if target.entity and not target.entity:IsValid() then
			self:ClearTargets()

			break
		end
	end
end

function toolgun.Fire(context, cmd, action)
	context:Refresh()
	local callback = context:GetTool()[action]

	if not callback then return false end

	local trace = toolgun.Trace(context:GetPlayer(), cmd.view)

	if not trace then return false end

	if not callback(context, trace) then return false end

	weapon_effects.ToolTrace(context.weapon, trace.position, trace.normal)
	return true
end

function toolgun.ConstraintTool(tool)
	tool.Category = "Constraints"
	tool.Instructions = tool.Instructions or {}
	tool.Instructions.Stages = tool.Instructions.Stages or
		{"select the first object", "select the second object"}
	tool.Instructions.Reload = tool.Instructions.Reload or
		"remove " .. tool.DisplayName:lower() .. " constraints from an object"

	function tool.LeftClick(context, trace)
		if not (toolgun.IsProp(trace.entity) or (trace.world and not tool.NoWorld)) then
			return false
		end

		if context:GetStage() == 0 then
			context:AddTarget(trace)
			return true
		end

		local first = context.targets[1]

		if trace.entity == first.entity then return false end

		local second = toolgun.MakeTarget(trace)
		context:ClearTargets()

		if not (first.entity or second.entity) then return false end

		local entity = toolgun.CreateConstraint(context:GetPlayer(), first, second, tool.Build(context, first, second))
		context:Record(game_history.Spawned(tool.DisplayName:lower(), entity))
		return true
	end

	tool.Reload = toolgun.RemoveConstraintsReload
	return toolgun.Register(tool)
end

function toolgun.RemoveConstraintsReload(context, trace)
	context:ClearTargets()

	if not toolgun.IsProp(trace.entity) then return false end

	local tool = context:GetTool()
	local found = toolgun.GetConstraints(trace.entity, tool.Kind)

	if not found[1] then return false end

	context:Record(game_history.Remove("remove " .. tool.DisplayName:lower(), found))
	return true
end

for _, name in ipairs{
	"weld",
	"axis",
	"ball_socket",
	"rope",
	"elastic",
	"slider",
	"motor",
	"no_collide",
	"keep_upright",
	"remover",
	"duplicator",
	"balloon",
	"light",
	"weight",
	"physical_properties",
} do
	import("lua/tools/" .. name .. ".lua")
end

return toolgun
