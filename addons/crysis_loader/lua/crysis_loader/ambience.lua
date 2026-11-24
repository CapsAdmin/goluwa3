local units = import("lua/crysis_loader/units.lua")
local ambience = {}

local function to_engine(position)
	local p = units.PositionToEngine(position)
	return {p.x, p.y, p.z}
end

function ambience.ConvertArea(area)
	local out = {kind = area.kind, group = area.group, priority = area.priority}

	if area.kind == "sphere" then
		out.center = to_engine(area.center)
		out.radius = area.radius
	elseif area.kind == "box" then
		local origin = to_engine(area.corners[1])
		out.origin = origin
		out.edges = {}

		for i = 2, 4 do
			local corner = to_engine(area.corners[i])
			out.edges[i - 1] = {corner[1] - origin[1], corner[2] - origin[2], corner[3] - origin[3]}
		end
	else
		local bottom = math.huge
		out.points = {}

		for i, point in ipairs(area.points) do
			local p = to_engine(point)
			out.points[i] = {p[1], p[3]}
			bottom = math.min(bottom, p[2])
		end

		out.bottom = bottom
		out.top = area.height > 0 and bottom + area.height or nil
	end

	return out
end

function ambience.BuildRecords(entities)
	local areas_by_id = {}

	for _, entity in ipairs(entities) do
		if entity.area then
			for _, id in ipairs(entity.area.links) do
				areas_by_id[id] = areas_by_id[id] or {}
				list.insert(areas_by_id[id], entity.area)
			end
		end
	end

	local records = {}

	for _, entity in ipairs(entities) do
		local properties = entity.properties
		local random = entity.class == "RandomSoundVolume"
		local areas = entity.id and areas_by_id[entity.id]

		if
			(
				random or
				entity.class == "AmbientVolume"
			)
			and
			areas and
			properties.bEnabled ~= "0" and
			(
				properties.soundName or
				""
			) ~= ""
		then
			local converted = {}

			for i, area in ipairs(areas) do
				converted[i] = ambience.ConvertArea(area)
			end

			records[#records + 1] = {
				name = entity.name or entity.class,
				world_matrix = entity.world_matrix,
				component = {
					Sound = properties.soundName,
					Random = random,
					OuterRadius = tonumber(properties.OuterRadius) or 10,
					DiscRadius = tonumber(properties.DiscRadius) or 10,
					MinWait = tonumber(properties.MinWaitTime) or 2,
					MaxWait = tonumber(properties.MaxWaitTime) or 5,
					RandomPosition = properties.bRandomPosition ~= "0",
					Areas = converted,
				},
			}
		end
	end

	return records
end

return ambience
