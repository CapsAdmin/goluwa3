local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local world_pack = {}
local float_array_t = ffi.typeof("float[?]")
local float_ptr_t = ffi.typeof("const float *")

function world_pack.PackFloats(values)
	local count = #values
	local array = float_array_t(count)

	for i = 1, count do
		array[i - 1] = values[i]
	end

	return ffi.string(array, count * 4)
end

function world_pack.UnpackFloats(data)
	local count = #data / 4
	local array = ffi.cast(float_ptr_t, data)
	local values = {}

	for i = 1, count do
		values[i] = array[i - 1]
	end

	return values
end

function world_pack.PackBrushes(brushes)
	local counts, flags, sides = {}, {}, {}

	for i, brush in ipairs(brushes) do
		counts[i] = #brush.Sides
		flags[i] = (brush.Collide and 1 or 0) + (brush.Sky and 2 or 0)

		for _, value in ipairs(brush.Sides) do
			sides[#sides + 1] = value
		end
	end

	return {
		counts = world_pack.PackFloats(counts),
		flags = world_pack.PackFloats(flags),
		sides = world_pack.PackFloats(sides),
	}
end

function world_pack.UnpackBrushes(packed)
	local counts = world_pack.UnpackFloats(packed.counts)
	local flags = world_pack.UnpackFloats(packed.flags)
	local sides = world_pack.UnpackFloats(packed.sides)
	local brushes = {}
	local position = 1

	for i, count in ipairs(counts) do
		local brush_sides = {}

		for k = 1, count do
			brush_sides[k] = sides[position + k - 1]
		end

		position = position + count
		brushes[i] = {
			Sides = brush_sides,
			Collide = flags[i] % 2 == 1 or nil,
			Sky = flags[i] >= 2 or nil,
		}
	end

	return brushes
end

local DISPLACEMENT_HEADER = 19

function world_pack.PackDisplacements(displacements)
	local values = {}

	for _, displacement in ipairs(displacements) do
		local normal = displacement.Normal
		values[#values + 1] = displacement.Power
		values[#values + 1] = displacement.Texinfo
		values[#values + 1] = displacement.Group
		values[#values + 1] = displacement.Sky and 1 or 0
		values[#values + 1] = normal.x
		values[#values + 1] = normal.y
		values[#values + 1] = normal.z

		for _, corner in ipairs(displacement.Corners) do
			values[#values + 1] = corner.x
			values[#values + 1] = corner.y
			values[#values + 1] = corner.z
		end

		for _, value in ipairs(displacement.Positions) do
			values[#values + 1] = value
		end

		for _, value in ipairs(displacement.Alphas) do
			values[#values + 1] = value
		end
	end

	return {count = #displacements, data = world_pack.PackFloats(values)}
end

function world_pack.UnpackDisplacements(packed)
	local values = world_pack.UnpackFloats(packed.data)
	local displacements = {}
	local position = 1

	for i = 1, packed.count do
		local power = values[position]
		local vertex_count = (2 ^ power + 1) ^ 2
		local corners = {}

		for k = 1, 4 do
			local o = position + 7 + (k - 1) * 3
			corners[k] = Vec3(values[o], values[o + 1], values[o + 2])
		end

		local positions, alphas = {}, {}
		local positions_start = position + DISPLACEMENT_HEADER - 1

		for k = 1, vertex_count * 3 do
			positions[k] = values[positions_start + k]
		end

		local alphas_start = positions_start + vertex_count * 3

		for k = 1, vertex_count do
			alphas[k] = values[alphas_start + k]
		end

		displacements[i] = {
			Power = power,
			Texinfo = values[position + 1],
			Group = values[position + 2],
			Sky = values[position + 3] == 1 or nil,
			Normal = Vec3(values[position + 4], values[position + 5], values[position + 6]),
			Corners = corners,
			Positions = positions,
			Alphas = alphas,
		}
		position = alphas_start + vertex_count + 1
	end

	return displacements
end

return world_pack
