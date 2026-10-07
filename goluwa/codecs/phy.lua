local ffi = require("ffi")
local bit = require("bit")
local source = import("goluwa/source_engine/units.lua")
local phy = library()
phy.file_extensions = {"phy"}
local int32_ptr_t = ffi.typeof("const int32_t *")
local int16_ptr_t = ffi.typeof("const int16_t *")
local float_ptr_t = ffi.typeof("const float *")
local uint8_ptr_t = ffi.typeof("const uint8_t *")
local scale = source.phy_to_meters

function phy.Decode(str)
	local length = #str
	local base = ffi.cast(uint8_ptr_t, str)

	local function at(offset, size)
		if offset < 0 or offset + size > length then
			error("phy data is out of range", 3)
		end

		return base + offset
	end

	local header_size = ffi.cast(int32_ptr_t, at(0, 12))[0]
	local solid_count = ffi.cast(int32_ptr_t, at(0, 12))[2]
	local position = header_size
	local solids = {}

	for solid_index = 1, solid_count do
		local surface_size = ffi.cast(int32_ptr_t, at(position, 4))[0]
		local solid_start = position + 4
		local surface_start = solid_start + 28
		local floats = ffi.cast(float_ptr_t, at(surface_start, 24))
		local cx, cy, cz = floats[0], floats[1], floats[2]
		local ix, iy, iz = floats[3], floats[4], floats[5]
		local ledgetree_root = surface_start + ffi.cast(int32_ptr_t, at(surface_start + 32, 4))[0]
		local ledges = {}
		local stack = {ledgetree_root}

		while stack[1] do
			local node_position = table.remove(stack)

			if node_position < solid_start or node_position >= solid_start + surface_size then
				error("phy ledge tree node out of range")
			end

			local node = ffi.cast(int32_ptr_t, at(node_position, 8))
			local right_offset, convex_offset = node[0], node[1]

			if right_offset == 0 then
				local ledge_position = node_position + convex_offset
				local ledge = ffi.cast(int32_ptr_t, at(ledge_position, 16))
				local point_offset = ledge[0]
				local triangle_count = ffi.cast(int16_ptr_t, at(ledge_position + 12, 2))[0]

				if triangle_count <= 0 or triangle_count >= 4096 then
					error("phy ledge triangle count out of range")
				end

				local triangles = ffi.cast(int32_ptr_t, at(ledge_position + 16, triangle_count * 16))
				local used = {}
				local indices = {}

				for i = 0, triangle_count - 1 do
					for edge = 1, 3 do
						local index = bit.band(triangles[i * 4 + edge], 0xffff)

						if not used[index] then
							used[index] = true
							indices[#indices + 1] = index
						end
					end
				end

				local points = {}

				for i, index in ipairs(indices) do
					local point = ffi.cast(float_ptr_t, at(ledge_position + point_offset + index * 16, 12))
					local o = (i - 1) * 3
					points[o + 1] = -point[2] * scale
					points[o + 2] = -point[1] * scale
					points[o + 3] = -point[0] * scale
				end

				ledges[#ledges + 1] = points
			else
				stack[#stack + 1] = node_position + right_offset
				stack[#stack + 1] = node_position + 28
			end
		end

		solids[solid_index] = {
			ledges = ledges,
			mass_center = {-cz * scale, -cy * scale, -cx * scale},
			rotation_inertia = {ix, iy, iz},
		}
		position = solid_start + surface_size
	end

	local text = ffi.string(at(position, 0), length - position)

	for block in text:gmatch("solid%s*(%b{})") do
		local solid = solids[tonumber(block:match("\"index\"%s*\"([^\"]*)\"")) + 1]

		if solid then
			solid.mass = tonumber(block:match("\"mass\"%s*\"([^\"]*)\""))
			solid.surface_property = block:match("\"surfaceprop\"%s*\"([^\"]*)\"")
		end
	end

	return {solids = solids}
end

return phy
