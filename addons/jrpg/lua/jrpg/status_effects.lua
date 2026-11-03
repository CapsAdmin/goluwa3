local network = import("goluwa/network/network.lua")
local data_files = import("goluwa/data_files.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/actors.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local status_effects = {}
status_effects.Files = data_files.New("lua/jrpg/status_effects/", {"Name", "Label", "Color", "Think"})
status_effects.Registered = {}
status_effects.List = {}
status_effects.Names = {"fire", "frozen", "lightning", "poison", "decay", "confused"}

local function compile_think(name, think)
	local damage_info = think.Damage
	local force = think.Force
	local spread = think.Spread
	local attributes = think.Attributes
	return function(entity, amount, source)
		if think.Gate and math.random() ^ amount <= think.Gate then return end

		local rpg = entity.rpg

		if think.DrainMana and rpg then
			rpg:SetMana(math.max(rpg:GetMana() - amount * think.DrainMana, 0))
		end

		local center = actors.GetCenter(entity)
		local info = {
			Attacker = source,
			Damage = damage_info.Base + math.ceil(amount * damage_info.PerAmount),
			Type = think.Type,
			Attributes = attributes,
			Status = name,
			Position = center,
		}

		if force then
			info.Force = Vec3(
					math.randomf(force.Min[1], force.Max[1]),
					math.randomf(force.Min[2], force.Max[2]),
					math.randomf(force.Min[3], force.Max[3])
				) * amount * force.Scale
		end

		if spread and amount > spread.Above then
			for _, other in ipairs(actors.Find(center, spread.Radius, entity)) do
				damage.Deal(other, table.shallow_copy(info))
			end
		end

		damage.Deal(entity, info)
	end
end

function status_effects.Register(name, data)
	status_effects.Files:Remember(name, data)
	local definition = data_files.Realize(table.copy(data))
	definition.Name = name
	definition.Rate = definition.Rate or 0.5
	definition.Decay = definition.Decay or 0.15
	definition.Max = definition.Max or 1
	definition.Label = definition.Label or name:sub(1, 2):upper()

	if definition.Think then
		definition.Think = compile_think(name, definition.Think)
	end

	local solid = definition.Solid

	if solid then
		local slope = definition.SlowSlope
		local animation_slope = definition.AnimationSlope
		definition.Speed = function(amount)
			if amount >= solid then return 0 end

			return 1 - amount * slope
		end
		definition.CanAttack = function(amount)
			return amount < solid
		end
		definition.AnimationSpeed = function(amount)
			if amount >= solid then return 0 end

			return 1 - amount * animation_slope
		end
	end

	local fail = definition.AttackFail

	if fail then
		definition.CanAttack = function(amount)
			return math.random() > amount * fail
		end
	end

	local wobble = definition.Wobble

	if wobble then
		definition.Wobble = function(amount, time)
			local sum = 0

			for i = 1, #wobble do
				sum = sum + math.sin(time * wobble[i][1]) * amount * wobble[i][2]
			end

			return sum
		end
	end

	if not status_effects.Registered[name] then
		status_effects.List[#status_effects.List + 1] = definition
	else
		for i, existing in ipairs(status_effects.List) do
			if existing.Name == name then status_effects.List[i] = definition end
		end
	end

	status_effects.Registered[name] = definition
	return definition
end

function status_effects.Update(name, data)
	return status_effects.Register(name, data)
end

function status_effects.Reload(name)
	return status_effects.Register(name, status_effects.Files:Read(name))
end

function status_effects.Save(name)
	return status_effects.Files:Save(name)
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
	status_effects.Register(name, import("lua/jrpg/status_effects/" .. name .. ".lua"))
end

return status_effects
