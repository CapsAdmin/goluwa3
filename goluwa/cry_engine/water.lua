local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local units = import("goluwa/cry_engine/units.lua")
local water = import("goluwa/render3d/water.lua")
local cry_water = {}

local WATER_ALBEDO_SCALE = 4
local RIVER_PIECE_LENGTH = 16

function cry_water.GetMedium(fog_color, fog_color_multiplier, fog_density)
	if not fog_color or not fog_density then
		return water.presets.lake.Absorption:Copy(),
		water.presets.lake.ParticleScattering:Copy()
	end

	return water.MediumFromFog(
		Vec3(fog_color.x ^ 2.2, fog_color.y ^ 2.2, fog_color.z ^ 2.2) * fog_color_multiplier,
		math.max(fog_density, 0.02),
		WATER_ALBEDO_SCALE
	)
end

local function yaw_towards(dir)
	return QuatDeg3(0, math.deg(math.atan2(-dir.z, dir.x)), 0)
end

local function fit_rectangle(points)
	local hull = {}

	do
		local sorted = {}

		for i, p in ipairs(points) do
			sorted[i] = p
		end

		table.sort(sorted, function(a, b)
			return a.x < b.x or (a.x == b.x and a.z < b.z)
		end)

		local function cross(o, a, b)
			return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
		end

		for pass = 1, 2 do
			local start = #hull

			for i = pass == 1 and 1 or #sorted, pass == 1 and #sorted or 1, pass == 1 and 1 or -1 do
				local p = sorted[i]

				while #hull >= start + 2 and cross(hull[#hull - 1], hull[#hull], p) <= 0 do
					list.remove(hull)
				end

				list.insert(hull, p)
			end

			list.remove(hull)
		end
	end

	local best

	for i = 1, #hull do
		local a, b = hull[i], hull[i % #hull + 1]
		local edge = Vec3(b.x - a.x, 0, b.z - a.z)

		if edge:GetLength() > 1e-4 then
			local u = edge:GetNormalized()
			local v = Vec3(-u.z, 0, u.x)
			local min_u, max_u, min_v, max_v = math.huge, -math.huge, math.huge, -math.huge

			for _, p in ipairs(hull) do
				local du = p.x * u.x + p.z * u.z
				local dv = p.x * v.x + p.z * v.z
				min_u, max_u = math.min(min_u, du), math.max(max_u, du)
				min_v, max_v = math.min(min_v, dv), math.max(max_v, dv)
			end

			local area = (max_u - min_u) * (max_v - min_v)

			if not best or area < best.area then
				local cu, cv = (min_u + max_u) / 2, (min_v + max_v) / 2
				best = {
					area = area,
					center = u * cu + v * cv,
					axis = u,
					length = max_u - min_u,
					width = max_v - min_v,
				}
			end
		end
	end

	return best
end

local function bezier(a, b, c, d, t)
	local s = 1 - t
	return a * (s * s * s) + b * (3 * s * s * t) + c * (3 * s * t * t) + d * (t * t * t)
end

function cry_water.BuildVolumes(object)
	local absorption, scattering = cry_water.GetMedium(object.fog_color, object.fog_color_multiplier, object.fog_density)
	local out = {}

	local function add(position, axis, length, width, flow_speed)
		out[#out + 1] = {
			position = position,
			rotation = yaw_towards(axis),
			config = {
				Size = Vec3(length, object.depth, width),
				Absorption = absorption:Copy(),
				ParticleScattering = scattering:Copy(),
				Flow = Vec2(axis.x, axis.z) * flow_speed,
				WaveHeight = flow_speed ~= 0 and 0.05 or 0.03,
				WaveLength = 1.2,
				Roughness = 0.02,
				Foam = 0.3,
			},
		}
	end

	if object.type == "WaterVolume" then
		local points = {}
		local height = 0

		for i, point in ipairs(object.points) do
			points[i] = units.ToEngine(point.pos)
			height = height + points[i].y
		end

		local rect = fit_rectangle(points)

		if rect then
			add(
				Vec3(rect.center.x, height / #points, rect.center.z),
				rect.axis,
				rect.length,
				rect.width,
				object.stream_speed
			)
		end

		return out
	end

	for i = 1, #object.points - 1 do
		local p0, p1 = object.points[i], object.points[i + 1]
		local a = units.ToEngine(p0.pos)
		local b = units.ToEngine(p0.forw)
		local c = units.ToEngine(p1.back)
		local d = units.ToEngine(p1.pos)
		local width_a = p0.width > 0 and p0.width or object.width
		local width_b = p1.width > 0 and p1.width or object.width
		local pieces = math.max(math.ceil((d - a):GetLength() / RIVER_PIECE_LENGTH), 1)
		local previous = a

		for piece = 1, pieces do
			local t = piece / pieces
			local current = bezier(a, b, c, d, t)
			local along = Vec3(current.x - previous.x, 0, current.z - previous.z)
			local length = along:GetLength()

			if length > 1e-3 then
				local width = math.lerp(t - 0.5 / pieces, width_a, width_b)
				add(
					(previous + current) / 2,
					along / length,
					length + width * 0.3,
					width,
					object.stream_speed
				)
			end

			previous = current
		end
	end

	return out
end


return cry_water
