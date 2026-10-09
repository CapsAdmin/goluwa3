local ffi = require("ffi")
local Vec3 = import("goluwa/structs/vec3.lua")
local world_pack = {}
local float_array_t = ffi.typeof("float[?]")
local float_ptr_t = ffi.typeof("const float *")

-- big numeric tables are stored as float32 strings, plain nested tables would exceed what a luadata chunk can hold
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

local SIDE_FLOATS = 13

-- the sides of a brush as {data = packed floats, textures = a texture name per side}
function world_pack.PackSides(sides)
	local flat, textures = {}, {}

	for i, side in ipairs(sides) do
		local o = (i - 1) * SIDE_FLOATS
		flat[o + 1], flat[o + 2], flat[o + 3] = side.normal.x, side.normal.y, side.normal.z
		flat[o + 4] = side.dist

		for k = 1, 8 do
			flat[o + 4 + k] = side.vecs and side.vecs[k] or 0
		end

		flat[o + 13] = side.visible and 1 or 0
		textures[i] = side.texname or ""
	end

	return {data = world_pack.PackFloats(flat), textures = textures}
end

function world_pack.UnpackSides(value)
	local flat = world_pack.UnpackFloats(value.data)
	local sides = {}

	for i, texname in ipairs(value.textures) do
		local o = (i - 1) * SIDE_FLOATS
		local vecs

		if texname ~= "" then
			vecs = {}

			for k = 1, 8 do
				vecs[k] = flat[o + 4 + k]
			end
		end

		sides[i] = {
			normal = Vec3(flat[o + 1], flat[o + 2], flat[o + 3]),
			dist = flat[o + 4],
			texname = texname ~= "" and texname or nil,
			vecs = vecs,
			visible = flat[o + 13] == 1,
		}
	end

	return sides
end

return world_pack
