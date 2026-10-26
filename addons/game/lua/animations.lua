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

do
	local EASES = {
		smooth = function(t)
			return t * t * (3 - 2 * t)
		end,
		linear = function(t)
			return t
		end,
		["in"] = function(t)
			return t * t * t
		end,
		out = function(t)
			return 1 - (1 - t) ^ 3
		end,
	}

	function animations.SampleKeys(keys, f, out, count)
		local last = #keys

		if f <= keys[1][1] then
			for i = 1, count do
				out[i] = keys[1][i + 1] or 0
			end

			return out
		end

		for k = 2, last do
			local key = keys[k]

			if f <= key[1] then
				local previous = keys[k - 1]
				local t = EASES[key.ease or "smooth"]((f - previous[1]) / (key[1] - previous[1]))

				for i = 1, count do
					local a = previous[i + 1] or 0
					out[i] = a + ((key[i + 1] or 0) - a) * t
				end

				return out
			end
		end

		for i = 1, count do
			out[i] = keys[last][i + 1] or 0
		end

		return out
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
		duration = def.Duration and def.Duration * (def.Cutoff and def.Cutoff(weight or 1) or 1),
	}
end

function animations.GetWeight(pose, name)
	local anims = pose.anims

	for i = 1, #anims do
		if anims[i].def.Name == name then return anims[i].weight end
	end

	return 0
end

function animations.PosesWeapon(pose)
	local anims = pose.anims

	for i = 1, #anims do
		if anims[i].def.PoseWeapon then return true end
	end

	return false
end

return animations
