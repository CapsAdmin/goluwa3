local network = import("goluwa/network/network.lua")
local status_effects = {}
status_effects.Registered = {}
status_effects.List = {}
status_effects.Names = {"fire", "frozen", "lightning", "poison", "decay", "confused"}

function status_effects.Register(definition)
	assert(definition.Name, "a status effect needs a name")
	definition.Rate = definition.Rate or 0.5
	definition.Decay = definition.Decay or 0.15
	definition.Max = definition.Max or 1
	definition.Label = definition.Label or definition.Name:sub(1, 2):upper()

	if not status_effects.Registered[definition.Name] then
		status_effects.List[#status_effects.List + 1] = definition
	else
		for i, existing in ipairs(status_effects.List) do
			if existing.Name == definition.Name then status_effects.List[i] = definition end
		end
	end

	status_effects.Registered[definition.Name] = definition
	return definition
end

function status_effects.GetDefinition(name)
	return assert(status_effects.Registered[name], "unknown status effect " .. tostring(name))
end

function status_effects.Get(entity, name)
	local component = entity.status_effects
	return component and component:GetAmount(name) or 0
end

local function get_component(entity)
	assert(network.HasAuthority(), "status effects are only changed by the authority")

	if not entity.health or entity.health:IsDead() then return end

	return entity:EnsureComponent("status_effects")
end

function status_effects.Set(entity, name, amount, source)
	local component = get_component(entity)

	if component then component:SetAmount(name, amount, source) end
end

function status_effects.Add(entity, name, amount, source)
	local component = get_component(entity)

	if component then
		component:SetAmount(name, component:GetAmount(name) + amount, source)
	end
end

function status_effects.Remove(entity, name)
	local component = entity.status_effects

	if component then component:SetAmount(name, 0) end
end

function status_effects.Clear(entity)
	local component = entity.status_effects

	if component then component:Clear() end
end

function status_effects.GetSpeedScale(entity)
	local component = entity.status_effects

	if not component then return 1 end

	local scale = 1

	for name, amount in pairs(component.amounts) do
		local speed = status_effects.Registered[name].Speed

		if speed then scale = scale * speed(amount) end
	end

	return scale
end

function status_effects.CanAttack(entity)
	local component = entity.status_effects

	if not component then return true end

	for name, amount in pairs(component.amounts) do
		local can_attack = status_effects.Registered[name].CanAttack

		if can_attack and not can_attack(amount, entity) then return false end
	end

	return true
end

for _, name in ipairs(status_effects.Names) do
	status_effects.Register(import("lua/jrpg/status_effects/" .. name .. ".lua"))
end

return status_effects
