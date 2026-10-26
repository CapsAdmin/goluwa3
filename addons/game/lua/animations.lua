local animations = {}
animations.Definitions = {}
animations.Triggers = {}
local triggers_by_counter = {}
local KINDS = {action = true, state = true, impulse = true}

function animations.Register(name, def)
	assert(KINDS[def.Kind], name .. " has an invalid kind")
	def.Name = name
	animations.Definitions[name] = def

	if def.Trigger then
		local trigger = triggers_by_counter[def.Trigger]

		if not trigger then
			trigger = {Counter = def.Trigger, Seen = "seen_" .. def.Trigger:lower(), Defs = {}}
			triggers_by_counter[def.Trigger] = trigger
			table.insert(animations.Triggers, trigger)
		end

		table.insert(trigger.Defs, def)
	end
end

function animations.Get(name)
	return assert(animations.Definitions[name], "unknown animation " .. name)
end

function animations.NewInstance(name, weight)
	local def = animations.Get(name)
	return {
		def = def,
		weight = weight or 1,
		strength = weight or 1,
		raw = weight or 1,
		time = 0,
		phase = 0,
		cycle = 0,
		duration = def.Duration,
	}
end

function animations.GetWeight(pose, name)
	local anims = pose.anims

	for i = 1, #anims do
		if anims[i].def.Name == name then return anims[i].weight end
	end

	return 0
end

return animations
