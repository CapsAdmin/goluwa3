local segment_geometry = {}
local trace_break = coroutine.running

function segment_geometry.ClosestPointOnSegment(a, b, point, epsilon)
	epsilon = epsilon or 0.000001
	local ab = b - a
	local denom = ab:Dot(ab)

	if denom <= epsilon then return a, 0 end

	local t = math.clamp((point - a):Dot(ab) / denom, 0, 1)
	return a + ab * t, t
end

do
	local m = {0, 0, 0, 0, 0, 0, 0, 0, 0}

	local function solve_segment_parameters(epsilon)
		local a = m[1] * m[1] + m[2] * m[2] + m[3] * m[3]
		local e = m[4] * m[4] + m[5] * m[5] + m[6] * m[6]

		if a <= epsilon and e <= epsilon then return nil end

		local f = m[4] * m[7] + m[5] * m[8] + m[6] * m[9]

		if a <= epsilon then return 0, math.clamp(f / e, 0, 1) end

		local c = m[1] * m[7] + m[2] * m[8] + m[3] * m[9]

		if e <= epsilon then return math.clamp(-c / a, 0, 1), 0 end

		local b = m[1] * m[4] + m[2] * m[5] + m[3] * m[6]
		local denom = a * e - b * b
		local s = 0

		if math.abs(denom) > epsilon then
			s = math.clamp((b * f - c * e) / denom, 0, 1)
		end

		local t = (b * s + f) / e

		if t < 0 then
			return math.clamp(-c / a, 0, 1), 0
		elseif t > 1 then
			return math.clamp((b - c) / a, 0, 1), 1
		end

		return s, t
	end

	function segment_geometry.ClosestPointsBetweenSegments(p1, q1, p2, q2, epsilon)
		m[1], m[2], m[3] = q1.x - p1.x, q1.y - p1.y, q1.z - p1.z
		m[4], m[5], m[6] = q2.x - p2.x, q2.y - p2.y, q2.z - p2.z
		m[7], m[8], m[9] = p1.x - p2.x, p1.y - p2.y, p1.z - p2.z
		trace_break()
		local s, t = solve_segment_parameters(epsilon or 0.000001)

		if not s then return p1, p2 end

		return p1 + (q1 - p1) * s, p2 + (q2 - p2) * t
	end
end

return segment_geometry
