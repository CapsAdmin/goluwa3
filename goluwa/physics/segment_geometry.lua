local segment_geometry = {}

function segment_geometry.ClosestPointOnSegment(a, b, point, epsilon)
	epsilon = epsilon or 0.000001
	local ab = b - a
	local denom = ab:Dot(ab)

	if denom <= epsilon then return a, 0 end

	local t = math.clamp((point - a):Dot(ab) / denom, 0, 1)
	return a + ab * t, t
end

function segment_geometry.ClosestPointsBetweenSegments(p1, q1, p2, q2, epsilon)
	epsilon = epsilon or 0.000001
	local a = (q1.x - p1.x) * (q1.x - p1.x) + (q1.y - p1.y) * (q1.y - p1.y) + (q1.z - p1.z) * (q1.z - p1.z)
	local e = (q2.x - p2.x) * (q2.x - p2.x) + (q2.y - p2.y) * (q2.y - p2.y) + (q2.z - p2.z) * (q2.z - p2.z)
	local f = (q2.x - p2.x) * (p1.x - p2.x) + (q2.y - p2.y) * (p1.y - p2.y) + (q2.z - p2.z) * (p1.z - p2.z)
	local s
	local t

	if a <= epsilon and e <= epsilon then return p1, p2 end

	if a <= epsilon then
		s = 0
		t = math.clamp(f / e, 0, 1)
	else
		local c = (q1.x - p1.x) * (p1.x - p2.x) + (q1.y - p1.y) * (p1.y - p2.y) + (q1.z - p1.z) * (p1.z - p2.z)

		if e <= epsilon then
			t = 0
			s = math.clamp(-c / a, 0, 1)
		else
			local b = (q1.x - p1.x) * (q2.x - p2.x) + (q1.y - p1.y) * (q2.y - p2.y) + (q1.z - p1.z) * (q2.z - p2.z)
			local denom = a * e - b * b

			if math.abs(denom) > epsilon then
				s = math.clamp((b * f - c * e) / denom, 0, 1)
			else
				s = 0
			end

			t = (b * s + f) / e

			if t < 0 then
				t = 0
				s = math.clamp(-c / a, 0, 1)
			elseif t > 1 then
				t = 1
				s = math.clamp((b - c) / a, 0, 1)
			end
		end
	end

	return p1 + (q1 - p1) * s, p2 + (q2 - p2) * t
end

return segment_geometry
