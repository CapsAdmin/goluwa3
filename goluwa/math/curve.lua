local curve = {}

function curve.Segment(keys, t)
	local count = #keys
	local index = 1

	while index < count and keys[index + 1][1] <= t do
		index = index + 1
	end

	local from, to = keys[index], keys[index + 1]

	if not to or t <= from[1] then return from, from, 0 end

	local fraction = (t - from[1]) / (to[1] - from[1])
	local mode = from[3]

	if mode == "smooth" then
		fraction = fraction * fraction * (3 - 2 * fraction)
	elseif mode == "step" then
		fraction = 0
	end

	return from, to, fraction
end

function curve.Evaluate(keys, t)
	local from, to, fraction = curve.Segment(keys, t)
	return from[2] + (to[2] - from[2]) * fraction
end

return curve
