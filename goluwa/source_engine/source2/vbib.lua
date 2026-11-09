local ffi = require("ffi")
local meshopt = import("goluwa/codecs/meshopt.lua")
local vbib = {}
local u32_t = ffi.typeof("const uint32_t *")
local i32_t = ffi.typeof("const int32_t *")
local u8_t = ffi.typeof("const uint8_t *")
vbib.FORMAT = {
	R32G32B32A32_FLOAT = 2,
	R32G32B32_FLOAT = 6,
	R16G16B16A16_FLOAT = 10,
	R16G16B16A16_UNORM = 11,
	R16G16B16A16_UINT = 12,
	R32G32_FLOAT = 16,
	R8G8B8A8_UNORM = 28,
	R8G8B8A8_UINT = 30,
	R16G16_FLOAT = 34,
	R16G16_UNORM = 35,
	R16G16_SNORM = 37,
	R32_UINT = 42,
}

local function read_buffer(src, p, is_vertex)
	local header = ffi.cast(u32_t, src + p)
	local size = ffi.cast(i32_t, src + p + 4)[0]
	local buffer = {
		element_count = header[0],
		element_size = bit.band(size, 0x3FFFFFF),
		fields = {},
	}
	local field_pos = p + 8 + header[2]
	local field_count = header[3]

	for i = 0, field_count - 1 do
		local f = field_pos + i * 56
		local fields = ffi.cast(u32_t, src + f + 32)
		buffer.fields[#buffer.fields + 1] = {
			name = ffi.string(src + f):upper(),
			index = fields[0],
			format = fields[1],
			offset = fields[2],
		}
	end

	local data_pos = p + 16 + header[4]
	local total = ffi.cast(i32_t, src + p + 20)[0]
	buffer.data = src + data_pos
	buffer.size = total

	if buffer.element_count * buffer.element_size > total then
		if is_vertex then
			buffer.data = meshopt.DecodeVertexBuffer(buffer.element_count, buffer.element_size, src + data_pos, total)
		else
			buffer.data = meshopt.DecodeIndexBuffer(buffer.element_count, buffer.element_size, src + data_pos, total)
		end

		buffer.size = buffer.element_count * buffer.element_size
	end

	return buffer
end

function vbib.Parse(str, offset)
	local src = ffi.cast(u8_t, str)
	local header = ffi.cast(u32_t, src + offset)
	local out = {vertex = {}, index = {}, keep = str}
	local vertex_pos = offset + header[0]

	for i = 0, header[1] - 1 do
		out.vertex[i] = read_buffer(src, vertex_pos + i * 24, true)
	end

	local index_pos = offset + 8 + header[2]

	for i = 0, header[3] - 1 do
		out.index[i] = read_buffer(src, index_pos + i * 24, false)
	end

	return out
end

function vbib.GetField(buffer, name, index)
	for _, field in ipairs(buffer.fields) do
		if field.name == name and field.index == (index or 0) then return field end
	end
end

local f32_t = ffi.typeof("const float *")
local u16_t = ffi.typeof("const uint16_t *")
local i16_t = ffi.typeof("const int16_t *")

local function half(h)
	local e = bit.band(bit.rshift(h, 10), 31)
	local m = bit.band(h, 1023)
	local s = bit.band(h, 0x8000) ~= 0 and -1 or 1

	if e == 0 then return s * m * 2 ^ -24 end

	if e == 31 then return m == 0 and s * math.huge or 0 / 0 end

	return s * (1 + m / 1024) * 2 ^ (e - 15)
end

-- returns the value of an attribute of one vertex as up to 4 numbers
function vbib.Read(buffer, field, vertex)
	local p = buffer.data + vertex * buffer.element_size + field.offset
	local f = field.format
	local F = vbib.FORMAT

	if f == F.R32G32B32_FLOAT then
		local v = ffi.cast(f32_t, p)
		return v[0], v[1], v[2]
	elseif f == F.R32G32_FLOAT then
		local v = ffi.cast(f32_t, p)
		return v[0], v[1]
	elseif f == F.R32G32B32A32_FLOAT then
		local v = ffi.cast(f32_t, p)
		return v[0], v[1], v[2], v[3]
	elseif f == F.R16G16_FLOAT then
		local v = ffi.cast(u16_t, p)
		return half(v[0]), half(v[1])
	elseif f == F.R16G16B16A16_FLOAT then
		local v = ffi.cast(u16_t, p)
		return half(v[0]), half(v[1]), half(v[2]), half(v[3])
	elseif f == F.R16G16_UNORM then
		local v = ffi.cast(u16_t, p)
		return v[0] / 65535, v[1] / 65535
	elseif f == F.R16G16_SNORM then
		local v = ffi.cast(i16_t, p)
		return v[0] / 32767, v[1] / 32767
	elseif f == F.R8G8B8A8_UNORM then
		return p[0] / 255, p[1] / 255, p[2] / 255, p[3] / 255
	elseif f == F.R32_UINT then
		return ffi.cast(u32_t, p)[0]
	end

	error("unsupported vertex format " .. f)
end

local function decompress_normal(x, y)
	x = x - 128
	y = y - 128
	local z_sign_bit = x < 0 and 1 or 0
	local t_sign_bit = y < 0 and 1 or 0
	local z_sign = -(2 * z_sign_bit - 1)
	local t_sign = -(2 * t_sign_bit - 1)
	x = x * z_sign - z_sign_bit
	y = y * t_sign - t_sign_bit
	x = x - 64
	y = y - 64
	local x_sign_bit = x < 0 and 1 or 0
	local y_sign_bit = y < 0 and 1 or 0
	local x_sign = -(2 * x_sign_bit - 1)
	local y_sign = -(2 * y_sign_bit - 1)
	x = (x * x_sign - x_sign_bit) / 63
	y = (y * y_sign - y_sign_bit) / 63
	local z = 1 - x - y
	local inv = 1 / math.sqrt(x * x + y * y + z * z)
	return x * inv * x_sign, y * inv * y_sign, z * inv * z_sign
end

-- normal x y z, tangent x y z, tangent sign (v1 compressed R8G8B8A8, or raw floats)
function vbib.ReadNormalTangent(buffer, field, vertex)
	local F = vbib.FORMAT
	local p = buffer.data + vertex * buffer.element_size + field.offset

	if field.format == F.R32G32B32_FLOAT then
		local v = ffi.cast(f32_t, p)
		return v[0], v[1], v[2], 1, 0, 0, 1
	elseif field.format == F.R8G8B8A8_UNORM then
		local nx, ny, nz = decompress_normal(p[0], p[1])
		local tx, ty, tz = decompress_normal(p[2], p[3])
		return nx, ny, nz, tx, ty, tz, p[3] < 128 and -1 or 1
	elseif field.format == F.R32_UINT then
		local packed = ffi.cast(u32_t, p)[0]
		local sign_bit = bit.band(packed, 1)
		local t_bits = bit.band(bit.rshift(packed, 1), 0x7ff)
		local x_bits = bit.band(bit.rshift(packed, 12), 0x3ff)
		local y_bits = bit.rshift(packed, 22)
		local x = x_bits / 1023 * 2 - 1
		local y = y_bits / 1023 * 2 - 1
		local z = 1 - math.abs(x) - math.abs(y)
		local comp = math.min(math.max(-z, 0), 1)
		x = x + (x >= 0 and -comp or comp)
		y = y + (y >= 0 and -comp or comp)
		local len = math.sqrt(x * x + y * y + z * z)
		x, y, z = x / len, y / len, z / len
		local ts = z >= 0 and 1 or -1
		local rcp = 1 / (ts + z)
		local ux = -ts * x * x * rcp + 1
		local uy = -ts * (x * y * rcp)
		local uz = -ts * x
		local angle = t_bits / 2047 * math.pi * 2
		local c, s = math.cos(angle), math.sin(angle)
		local cx, cy, cz = y * uz - z * uy, z * ux - x * uz, x * uy - y * ux
		return x,
		y,
		z,
		ux * c + cx * s,
		uy * c + cy * s,
		uz * c + cz * s,
		sign_bit == 0 and -1 or 1
	end

	error("unsupported normal format " .. field.format)
end

return vbib
