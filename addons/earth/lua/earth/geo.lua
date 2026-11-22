local planet = import("goluwa/planet.lua")
local geo = {}
local R = planet.RADIUS
local rad, deg = math.rad, math.deg
local sin, cos, asin, atan2, sqrt, log, tan, exp, atan, pi = math.sin,
math.cos,
math.asin,
math.atan2,
math.sqrt,
math.log,
math.tan,
math.exp,
math.atan,
math.pi
geo.MAX_LATITUDE = 85.0511287798066

-- the world origin stands on the anchor, +x is east, -z is north and the planet's center is RADIUS below the origin
function geo.NewAnchor(lat, lon)
	local phi, lambda = rad(lat), rad(lon)
	local sp, cp, sl, cl = sin(phi), cos(phi), sin(lambda), cos(lambda)
	return {
		lat = lat,
		lon = lon,
		ex = -sl,
		ey = cl,
		ez = 0,
		nx = -sp * cl,
		ny = -sp * sl,
		nz = cp,
		ux = cp * cl,
		uy = cp * sl,
		uz = sp,
	}
end

local function wrap_degrees(a)
	return (a + 180) % 360 - 180
end

-- the latitude and longitude under a world x, z (on the sphere straight below the tangent plane, as planet.GetDrop),
-- the longitude is unwrapped to be within 180 degrees of the anchor's
function geo.WorldToLatLon(anchor, x, z)
	local e, n = x / R, -z / R
	local u = sqrt(math.max(1 - e * e - n * n, 0))
	local vx = e * anchor.ex + n * anchor.nx + u * anchor.ux
	local vy = e * anchor.ey + n * anchor.ny + u * anchor.uy
	local vz = e * anchor.ez + n * anchor.nz + u * anchor.uz
	local lat = deg(asin(math.clamp(vz, -1, 1)))
	local lon = deg(atan2(vy, vx))
	return lat, anchor.lon + wrap_degrees(lon - anchor.lon)
end

-- the world x, z of a latitude and longitude, nil on the far hemisphere
function geo.LatLonToWorld(anchor, lat, lon)
	local phi, lambda = rad(lat), rad(lon)
	local cp = cos(phi)
	local vx, vy, vz = cp * cos(lambda), cp * sin(lambda), sin(phi)
	local u = vx * anchor.ux + vy * anchor.uy + vz * anchor.uz

	if u < 0 then return nil end

	local e = vx * anchor.ex + vy * anchor.ey + vz * anchor.ez
	local n = vx * anchor.nx + vy * anchor.ny + vz * anchor.nz
	return e * R, -n * R
end

-- the global web mercator position at a zoom in pixels of tile_size, x is not wrapped
function geo.ToMercator(lat, lon, zoom, tile_size)
	local world = tile_size * 2 ^ zoom
	local phi = rad(math.clamp(lat, -geo.MAX_LATITUDE, geo.MAX_LATITUDE))
	return (lon / 360 + 0.5) * world,
	(0.5 - log(tan(pi / 4 + phi / 2)) / (2 * pi)) * world
end

function geo.FromMercator(x, y, zoom, tile_size)
	local world = tile_size * 2 ^ zoom
	local lon = (x / world - 0.5) * 360
	local lat = deg(2 * atan(exp((0.5 - y / world) * 2 * pi)) - pi / 2)
	return lat, lon
end

-- meters of ground per mercator pixel at a latitude
function geo.GetPixelSize(lat, zoom, tile_size)
	return 2 * pi * R * cos(rad(math.min(math.abs(lat), geo.MAX_LATITUDE))) / (
			tile_size * 2 ^ zoom
		)
end

-- the zoom whose pixels are no larger than meters, clamped to max_zoom
function geo.GetZoomFor(lat, meters, tile_size, max_zoom)
	local zoom = math.ceil(
		math.log(
				2 * pi * R * cos(rad(math.min(math.abs(lat), geo.MAX_LATITUDE))) / (
						tile_size * meters
					)
			) / math.log(2)
	)
	return math.clamp(zoom, 0, max_zoom)
end

-- the rigid transform from one anchor's world to another's (both on the same sphere): p' = M p + t,
-- with M as rows m[1..9], its quaternion and t
function geo.Relate(from, to)
	local axes_from = {
		{from.ex, from.ey, from.ez},
		{from.ux, from.uy, from.uz},
		{-from.nx, -from.ny, -from.nz},
	}
	local axes_to = {
		{to.ex, to.ey, to.ez},
		{to.ux, to.uy, to.uz},
		{-to.nx, -to.ny, -to.nz},
	}
	local m = {}

	for i = 1, 3 do
		for j = 1, 3 do
			local a, b = axes_to[i], axes_from[j]
			m[(i - 1) * 3 + j] = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
		end
	end

	local x, y, z, w
	local trace = m[1] + m[5] + m[9]

	if trace > 0 then
		local s = 0.5 / math.sqrt(trace + 1)
		w, x, y, z = 0.25 / s, (m[8] - m[6]) * s, (m[3] - m[7]) * s, (m[4] - m[2]) * s
	elseif m[1] > m[5] and m[1] > m[9] then
		local s = 2 * math.sqrt(1 + m[1] - m[5] - m[9])
		w, x, y, z = (m[8] - m[6]) / s, 0.25 * s, (m[2] + m[4]) / s, (m[3] + m[7]) / s
	elseif m[5] > m[9] then
		local s = 2 * math.sqrt(1 + m[5] - m[1] - m[9])
		w, x, y, z = (m[3] - m[7]) / s, (m[2] + m[4]) / s, 0.25 * s, (m[6] + m[8]) / s
	else
		local s = 2 * math.sqrt(1 + m[9] - m[1] - m[5])
		w, x, y, z = (m[4] - m[2]) / s, (m[3] + m[7]) / s, (m[6] + m[8]) / s, 0.25 * s
	end

	return {
		m = m,
		quat = {x, y, z, w},
		tx = R * m[2],
		ty = R * m[5] - R,
		tz = R * m[8],
	}
end

function geo.TransformPoint(relation, x, y, z)
	local m = relation.m
	return m[1] * x + m[2] * y + m[3] * z + relation.tx,
	m[4] * x + m[5] * y + m[6] * z + relation.ty,
	m[7] * x + m[8] * y + m[9] * z + relation.tz
end

return geo
