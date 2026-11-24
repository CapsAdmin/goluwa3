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

function curve.MonotoneTangents(points)
	local count = #points
	local slopes = {}
	local tangents = {}

	if count < 2 then
		tangents[1] = 0
		return tangents
	end

	for i = 1, count - 1 do
		slopes[i] = (points[i + 1][2] - points[i][2]) / (points[i + 1][1] - points[i][1])
	end

	tangents[1] = slopes[1]
	tangents[count] = slopes[count - 1]

	for i = 2, count - 1 do
		tangents[i] = slopes[i - 1] * slopes[i] <= 0 and 0 or (slopes[i - 1] + slopes[i]) / 2
	end

	for i = 1, count - 1 do
		if slopes[i] == 0 then
			tangents[i] = 0
			tangents[i + 1] = 0
		else
			local a, b = tangents[i] / slopes[i], tangents[i + 1] / slopes[i]
			local length = a * a + b * b

			if length > 9 then
				local scale = 3 / math.sqrt(length)
				tangents[i] = scale * a * slopes[i]
				tangents[i + 1] = scale * b * slopes[i]
			end
		end
	end

	return tangents
end

function curve.EvaluateMonotone(points, tangents, x, end_slope)
	local count = #points

	if x <= points[1][1] then
		return points[1][2] + (end_slope and (x - points[1][1]) * end_slope or 0)
	end

	if x >= points[count][1] then
		return points[count][2] + (end_slope and (x - points[count][1]) * end_slope or 0)
	end

	local i = 1

	while points[i + 1][1] < x do
		i = i + 1
	end

	local x0, y0, x1, y1 = points[i][1], points[i][2], points[i + 1][1], points[i + 1][2]
	local h = x1 - x0
	local t = (x - x0) / h
	local t2, t3 = t * t, t * t * t
	return (
			2 * t3 - 3 * t2 + 1
		) * y0 + (
			t3 - 2 * t2 + t
		) * h * tangents[i] + (
			-2 * t3 + 3 * t2
		) * y1 + (
			t3 - t2
		) * h * tangents[i + 1]
end

return curve
