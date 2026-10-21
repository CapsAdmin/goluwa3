local vfs = import("goluwa/vfs.lua")
local nav = import("goluwa/codecs/nav.lua")
local navmesh = import("goluwa/navigation/navmesh.lua")
local units = import("goluwa/source_engine/units.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local bit = require("bit")
local nav_mesh = {}
nav_mesh.AVOID_COST = 5
local BLOCKED_ATTRIBUTES = bit.bor(nav.ATTRIBUTE.JUMP, nav.ATTRIBUTE.CROUCH)

function nav_mesh.GetPath(map_name)
	return "maps/" .. map_name .. ".nav"
end

local function get_height(area, x, y)
	local nw, se = area.nw, area.se
	local width, depth = se[1] - nw[1], se[2] - nw[2]
	local u = width > 0 and math.clamp((x - nw[1]) / width, 0, 1) or 0
	local v = depth > 0 and math.clamp((y - nw[2]) / depth, 0, 1) or 0
	local north = nw[3] + u * (area.ne_z - nw[3])
	local south = area.sw_z + u * (se[3] - area.sw_z)
	return north + v * (south - north)
end

local function to_engine(x, y, z)
	return Vec3(-y * units.meters, z * units.meters, -x * units.meters)
end

local function get_portal(area, direction, other)
	local first, last, fixed

	if direction == nav.NORTH or direction == nav.SOUTH then
		first = math.max(area.nw[1], other.nw[1])
		last = math.min(area.se[1], other.se[1])
		fixed = direction == nav.NORTH and area.nw[2] or area.se[2]
	else
		first = math.max(area.nw[2], other.nw[2])
		last = math.min(area.se[2], other.se[2])
		fixed = direction == nav.EAST and area.se[1] or area.nw[1]
	end

	if first > last then
		first = (first + last) / 2
		last = first
	end

	if direction == nav.NORTH or direction == nav.SOUTH then
		return first, fixed, last, fixed
	end

	return fixed, first, fixed, last
end

function nav_mesh.FromData(data)
	local mesh = navmesh.New()
	local sources = {}

	for _, source in ipairs(data.areas) do
		local nw, se = source.nw, source.se
		local flags = source.flags
		sources[source.id] = source
		mesh:AddArea{
			Id = source.id,
			Flags = flags,
			Blocked = bit.band(flags, BLOCKED_ATTRIBUTES) ~= 0,
			Cost = bit.band(flags, nav.ATTRIBUTE.AVOID) ~= 0 and nav_mesh.AVOID_COST or 1,
			Data = source,
			Polygon = {
				to_engine(nw[1], nw[2], nw[3]),
				to_engine(se[1], nw[2], source.ne_z),
				to_engine(se[1], se[2], se[3]),
				to_engine(nw[1], se[2], source.sw_z),
			},
		}
	end

	for _, source in ipairs(data.areas) do
		local area = mesh:GetArea(source.id)

		for direction = 0, 3 do
			for _, id in ipairs(source.connections[direction]) do
				local other = sources[id]

				if other then
					local x1, y1, x2, y2 = get_portal(source, direction, other)
					mesh:Connect(
						area,
						mesh:GetArea(id),
						to_engine(x1, y1, get_height(source, x1, y1)),
						to_engine(x2, y2, get_height(source, x2, y2))
					)
				end
			end
		end
	end

	mesh:Build()
	return mesh
end

function nav_mesh.Load(path)
	local str = assert(vfs.Read(path))
	return nav_mesh.FromData(assert(nav.Decode(str, path)))
end

return nav_mesh
