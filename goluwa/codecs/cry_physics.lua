local ffi = require("ffi")
local bit = require("bit")
local cry_physics = library()
local int32_ptr_t = ffi.typeof("const int32_t *")
local uint16_ptr_t = ffi.typeof("const uint16_t *")
local float_ptr_t = ffi.typeof("const float *")
local uint8_ptr_t = ffi.typeof("const uint8_t *")
local PHYS_GEOM_VER = 1
local GEOM_BOX = 0
local GEOM_TRIMESH = 1
local GEOM_SPHERE = 4
local GEOM_CYLINDER = 5
local GEOM_CAPSULE = 6
local MESH_SHARED_VTX = 1
local MESH_FULL_SERIALIZATION = 0x400000

local function check(length, offset, size)
	if offset < 0 or offset + size > length then
		error("cry physics data is out of range", 3)
	end
end

local function read_vec3(base, offset)
	local f = ffi.cast(float_ptr_t, base + offset)
	return {x = f[0], y = f[1], z = f[2]}
end

-- CryPhysics' serialized phys_geometry, the payload of a cgf MeshPhysicsData chunk. A trimesh saved
-- with foreign indices stores only triangle ids of the render mesh, so the render mesh streams
-- (1 based, like the cgf decoder produces them) are needed to resolve its vertices and triangles.
function cry_physics.Decode(str, positions, indices)
	local length = #str
	local base = ffi.cast(uint8_ptr_t, str)
	check(length, 0, 72)

	if ffi.cast(int32_ptr_t, base)[0] ~= PHYS_GEOM_VER then
		error("unsupported cry physics geometry version " .. ffi.cast(int32_ptr_t, base)[0])
	end

	local floats = ffi.cast(float_ptr_t, base + 8)
	local geometry = {
		inertia = {floats[0], floats[1], floats[2]},
		origin = {x = floats[7], y = floats[8], z = floats[9]},
		volume = floats[10],
		surface_index = ffi.cast(int32_ptr_t, base + 56)[0],
	}
	local geom_type = ffi.cast(int32_ptr_t, base + 68)[0]
	local offset = 72

	if geom_type == GEOM_BOX then
		check(length, offset, 60)
		local basis = ffi.cast(float_ptr_t, base + offset)
		geometry.type = "box"
		geometry.oriented = ffi.cast(int32_ptr_t, base + offset + 36)[0] ~= 0
		geometry.basis = {
			basis[0],
			basis[1],
			basis[2],
			basis[3],
			basis[4],
			basis[5],
			basis[6],
			basis[7],
			basis[8],
		}
		geometry.center = read_vec3(base, offset + 40)
		geometry.size = read_vec3(base, offset + 52)
	elseif geom_type == GEOM_SPHERE then
		check(length, offset, 16)
		geometry.type = "sphere"
		geometry.center = read_vec3(base, offset)
		geometry.radius = ffi.cast(float_ptr_t, base + offset + 12)[0]
	elseif geom_type == GEOM_CYLINDER or geom_type == GEOM_CAPSULE then
		check(length, offset, 32)
		geometry.type = geom_type == GEOM_CAPSULE and "capsule" or "cylinder"
		geometry.center = read_vec3(base, offset)
		geometry.axis = read_vec3(base, offset + 12)
		geometry.radius = ffi.cast(float_ptr_t, base + offset + 24)[0]
		geometry.half_height = ffi.cast(float_ptr_t, base + offset + 28)[0]
	elseif geom_type == GEOM_TRIMESH then
		check(length, offset, 18)
		local header = ffi.cast(int32_ptr_t, base + offset)
		local vertex_count, triangle_count, flags = header[0], header[1], header[3]
		offset = offset + 16
		local has_vertex_map = base[offset] ~= 0
		offset = offset + 1

		if has_vertex_map then offset = offset + vertex_count * 2 end

		check(length, offset, 1)
		local has_foreign = base[offset] ~= 0
		offset = offset + 1
		local foreign_offset
		local resolved_indices = {}
		local vertices

		if has_foreign then
			check(length, offset, triangle_count * 2)
			foreign_offset = offset
			offset = offset + triangle_count * 2
		end

		if has_foreign and bit.band(flags, MESH_FULL_SERIALIZATION) == 0 then
			assert(positions[1], "cry physics mesh needs the render mesh vertices")
			local foreign = ffi.cast(uint16_ptr_t, base + foreign_offset)
			vertices = positions

			for triangle = 0, triangle_count - 1 do
				local first = foreign[triangle] * 3

				for corner = 1, 3 do
					resolved_indices[triangle * 3 + corner] = indices[first + corner]
				end
			end
		else
			if bit.band(flags, MESH_SHARED_VTX) ~= 0 then
				vertices = positions
			else
				check(length, offset, vertex_count * 12)
				local raw = ffi.cast(float_ptr_t, base + offset)
				vertices = {}

				for i = 0, vertex_count - 1 do
					vertices[i + 1] = {x = raw[i * 3], y = raw[i * 3 + 1], z = raw[i * 3 + 2]}
				end

				offset = offset + vertex_count * 12
			end

			check(length, offset, triangle_count * 6)
			local raw = ffi.cast(uint16_ptr_t, base + offset)

			for i = 0, triangle_count * 3 - 1 do
				resolved_indices[i + 1] = raw[i] + 1
			end

			offset = offset + triangle_count * 6
			check(length, offset, 1)
			offset = offset + 1 + (base[offset] ~= 0 and triangle_count or 0)
		end

		check(length, offset, 40)
		geometry.type = "trimesh"
		geometry.vertices = vertices
		geometry.indices = resolved_indices
		geometry.convex = ffi.cast(int32_ptr_t, base + offset + 20)[0] ~= 0
	else
		error("unsupported cry physics geometry type " .. geom_type)
	end

	return geometry
end

return cry_physics
