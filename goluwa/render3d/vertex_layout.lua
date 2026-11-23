local ffi = require("ffi")
local vertex_layout = {}
local FLOAT_SIZE = ffi.sizeof("float")
local FIELDS = {
	{
		name = "position",
		alias = "POSITION",
		count = 3,
		glsl = "vec3",
		format = "r32g32b32_sfloat",
	},
	{
		name = "normal",
		alias = "NORMAL",
		count = 3,
		glsl = "vec3",
		format = "r32g32b32_sfloat",
		packing = "normal",
	},
	{name = "uv", alias = "UV", count = 2, glsl = "vec2", format = "r32g32_sfloat"},
	{
		name = "tangent",
		alias = "TANGENT",
		count = 4,
		glsl = "vec4",
		format = "r32g32b32a32_sfloat",
		packing = "tangent",
	},
	{
		name = "texture_blend",
		alias = "TEXTURE_BLEND",
		count = 1,
		glsl = "float",
		format = "r32_sfloat",
		scalar = true,
	},
	{
		name = "vertex_color",
		alias = "COLOR",
		count = 4,
		glsl = "vec4",
		format = "r32g32b32a32_sfloat",
	},
	{
		name = "pivot",
		alias = "PIVOT",
		count = 4,
		glsl = "vec4",
		format = "r32g32b32a32_sfloat",
	},
	{
		name = "chain_mid",
		alias = "CHAIN_MID",
		count = 3,
		glsl = "vec3",
		format = "r32g32b32_sfloat",
	},
	{
		name = "chain_tip",
		alias = "CHAIN_TIP",
		count = 3,
		glsl = "vec3",
		format = "r32g32b32_sfloat",
	},
}
local declarations = {}

for i, field in ipairs(FIELDS) do
	declarations[i] = field.scalar and
		(
			"float %s;"
		):format(field.name) or
		(
			"float %s[%d];"
		):format(field.name, field.count)
end

vertex_layout.Type = ffi.typeof("struct { " .. table.concat(declarations, " ") .. " }")
vertex_layout.ArrayType = ffi.typeof("$[?]", vertex_layout.Type)
vertex_layout.PointerType = ffi.typeof("$ *", vertex_layout.Type)
vertex_layout.Stride = ffi.sizeof(vertex_layout.Type)
vertex_layout.FloatStride = vertex_layout.Stride / FLOAT_SIZE
vertex_layout.Fields = FIELDS
local by_name = {}
local expected_floats = 0

for i, field in ipairs(FIELDS) do
	field.index = i
	field.offset = ffi.offsetof(vertex_layout.Type, field.name)
	field.float_offset = field.offset / FLOAT_SIZE
	by_name[field.name] = field
	assert(
		field.float_offset == expected_floats,
		"vertex field " .. field.name .. " is not tightly packed"
	)
	expected_floats = expected_floats + field.count
end

assert(expected_floats == vertex_layout.FloatStride, "vertex struct has padding")
local CORE_FIELDS = {position = true, normal = true, uv = true, tangent = true}
local group_bytes = {core = 0, extras = 0}
local seen_extras = false
vertex_layout.CORE = "core"
vertex_layout.EXTRAS = "extras"
vertex_layout.EXTRAS_BINDING = 3

for _, field in ipairs(FIELDS) do
	field.group = CORE_FIELDS[field.name] and "core" or "extras"
	field.gpu_words = field.packing and 1 or field.count
	field.gpu_format = field.packing and "r32_uint" or field.format
	field.group_offset = group_bytes[field.group]
	field.group_float_offset = field.group_offset / FLOAT_SIZE
	group_bytes[field.group] = group_bytes[field.group] + field.gpu_words * FLOAT_SIZE
	assert(
		field.group == "extras" or not seen_extras,
		"core vertex fields must come before the extras"
	)
	seen_extras = seen_extras or field.group == "extras"
end

vertex_layout.CoreStride = group_bytes.core
vertex_layout.ExtrasStride = group_bytes.extras
vertex_layout.CoreFloatStride = group_bytes.core / FLOAT_SIZE
vertex_layout.ExtrasFloatStride = group_bytes.extras / FLOAT_SIZE
vertex_layout.CPUCoreStride = vertex_layout.Stride - vertex_layout.ExtrasStride
assert(
	FIELDS[#FIELDS].offset + FIELDS[#FIELDS].count * FLOAT_SIZE - vertex_layout.CPUCoreStride == vertex_layout.ExtrasStride,
	"the extras are not stored the same on the cpu and the gpu"
)
vertex_layout.PACKING_GLSL = [[
#ifndef VERTEX_LAYOUT_PACKING
#define VERTEX_LAYOUT_PACKING
vec2 vertex_layout_oct_fold(vec3 n) {
	n /= max(abs(n.x) + abs(n.y) + abs(n.z), 1e-20);
	vec2 p = n.xy;
	if (n.z < 0.0) p = (1.0 - abs(p.yx)) * vec2(p.x >= 0.0 ? 1.0 : -1.0, p.y >= 0.0 ? 1.0 : -1.0);
	return p;
}

vec3 vertex_layout_oct_unfold(vec2 p) {
	vec3 n = vec3(p, 1.0 - abs(p.x) - abs(p.y));
	float t = max(-n.z, 0.0);
	n.xy += vec2(n.x >= 0.0 ? -t : t, n.y >= 0.0 ? -t : t);
	return normalize(n);
}

uint vertex_layout_encode_normal(vec3 n) {
	return packSnorm2x16(vertex_layout_oct_fold(n));
}

vec3 vertex_layout_decode_normal(uint word) {
	return vertex_layout_oct_unfold(unpackSnorm2x16(word));
}

uint vertex_layout_encode_tangent(vec4 t) {
	uvec2 q = uvec2(round(clamp(vertex_layout_oct_fold(t.xyz), -1.0, 1.0) * 8191.0) + 8192.0);
	uint magnitude = uint(clamp(round(abs(t.w)), 1.0, 4.0)) - 1u;
	return q.x | (q.y << 14) | (t.w < 0.0 ? 0x10000000u : 0u) | (magnitude << 29);
}

vec4 vertex_layout_decode_tangent(uint word) {
	vec2 p = clamp((vec2(float(word & 0x3FFFu), float((word >> 14) & 0x3FFFu)) - 8192.0) / 8191.0, -1.0, 1.0);
	float magnitude = float(((word >> 29) & 3u) + 1u);
	return vec4(vertex_layout_oct_unfold(p), (word & 0x10000000u) != 0u ? -magnitude : magnitude);
}
#endif
]]

do
	local floor, abs, min, max, sqrt = math.floor, math.abs, math.min, math.max, math.sqrt

	local function fold(x, y, z)
		local s = abs(x) + abs(y) + abs(z)

		if s == 0 then return 0, 0 end

		x, y, z = x / s, y / s, z / s

		if z < 0 then
			x, y = (1 - abs(y)) * (x >= 0 and 1 or -1), (1 - abs(x)) * (y >= 0 and 1 or -1)
		end

		return x, y
	end

	local function unfold(px, py)
		local x, y, z = px, py, 1 - abs(px) - abs(py)
		local t = max(-z, 0)
		x = x >= 0 and x - t or x + t
		y = y >= 0 and y - t or y + t
		local length = sqrt(x * x + y * y + z * z)
		return x / length, y / length, z / length
	end

	local function round(v)
		return floor(v + 0.5)
	end

	function vertex_layout.EncodeNormal(x, y, z)
		local px, py = fold(x, y, z)
		return round(max(-1, min(1, px)) * 32767) % 65536 + round(max(-1, min(1, py)) * 32767) % 65536 * 65536
	end

	function vertex_layout.DecodeNormal(word)
		local qx, qy = word % 65536, floor(word / 65536) % 65536

		if qx >= 32768 then qx = qx - 65536 end

		if qy >= 32768 then qy = qy - 65536 end

		return unfold(max(qx / 32767, -1), max(qy / 32767, -1))
	end

	function vertex_layout.EncodeTangent(x, y, z, w)
		local px, py = fold(x, y, z)
		local qx = round(max(-1, min(1, px)) * 8191) + 8192
		local qy = round(max(-1, min(1, py)) * 8191) + 8192
		local magnitude = max(1, min(4, round(abs(w)))) - 1
		return qx + qy * 16384 + (w < 0 and 268435456 or 0) + magnitude * 536870912
	end

	function vertex_layout.DecodeTangent(word)
		local px = max(-1, min(1, (word % 16384 - 8192) / 8191))
		local py = max(-1, min(1, (floor(word / 16384) % 16384 - 8192) / 8191))
		local magnitude = floor(word / 536870912) % 4 + 1
		local x, y, z = unfold(px, py)
		return x, y, z, floor(word / 268435456) % 2 == 1 and -magnitude or magnitude
	end
end

do
	local core_stride, extras_stride, stride = vertex_layout.CoreStride, vertex_layout.ExtrasStride, vertex_layout.Stride
	local cpu_core_stride = vertex_layout.CPUCoreStride
	local extras_words = extras_stride / 4
	local word_stride = stride / 4
	local cpu_core_words = cpu_core_stride / 4
	local core_words = core_stride / 4
	local reference = ffi.new("uint32_t[?]", extras_words)
	local encode_normal, encode_tangent = vertex_layout.EncodeNormal, vertex_layout.EncodeTangent
	local decode_normal, decode_tangent = vertex_layout.DecodeNormal, vertex_layout.DecodeTangent
	local POSITION = by_name.position.float_offset
	local NORMAL = by_name.normal.float_offset
	local UV = by_name.uv.float_offset
	local TANGENT = by_name.tangent.float_offset
	local GPU_POSITION = by_name.position.group_float_offset
	local GPU_NORMAL = by_name.normal.group_float_offset
	local GPU_UV = by_name.uv.group_float_offset
	local GPU_TANGENT = by_name.tangent.group_float_offset

	function vertex_layout.SplitInto(vertices, count, core, extras)
		local bytes = ffi.cast("const uint8_t *", vertices)
		local f = ffi.cast("const float *", vertices)
		local out_f = ffi.cast("float *", core)
		local out_u = ffi.cast("uint32_t *", core)

		for i = 0, count - 1 do
			local v = i * word_stride
			local o = i * core_words
			out_f[o + GPU_POSITION] = f[v + POSITION]
			out_f[o + GPU_POSITION + 1] = f[v + POSITION + 1]
			out_f[o + GPU_POSITION + 2] = f[v + POSITION + 2]
			out_u[o + GPU_NORMAL] = encode_normal(f[v + NORMAL], f[v + NORMAL + 1], f[v + NORMAL + 2])
			out_f[o + GPU_UV] = f[v + UV]
			out_f[o + GPU_UV + 1] = f[v + UV + 1]
			out_u[o + GPU_TANGENT] = encode_tangent(f[v + TANGENT], f[v + TANGENT + 1], f[v + TANGENT + 2], f[v + TANGENT + 3])
		end

		if extras then
			for i = 0, count - 1 do
				ffi.copy(extras + i * extras_stride, bytes + i * stride + cpu_core_stride, extras_stride)
			end
		end
	end

	function vertex_layout.Split(vertices, count, with_extras)
		local core = ffi.new("uint8_t[?]", math.max(count * core_stride, 1))
		local extras = with_extras and ffi.new("uint8_t[?]", math.max(count * extras_stride, 1)) or nil
		vertex_layout.SplitInto(vertices, count, core, extras)
		return core, extras
	end

	function vertex_layout.Join(core, extras, count)
		local vertices = vertex_layout.ArrayType(math.max(count, 1))
		local bytes = ffi.cast("uint8_t *", vertices)
		local f = ffi.cast("float *", vertices)
		local in_f = ffi.cast("const float *", core)
		local in_u = ffi.cast("const uint32_t *", core)
		local uniform = type(extras) == "string"

		for i = 0, count - 1 do
			local v = i * word_stride
			local o = i * core_words
			f[v + POSITION] = in_f[o + GPU_POSITION]
			f[v + POSITION + 1] = in_f[o + GPU_POSITION + 1]
			f[v + POSITION + 2] = in_f[o + GPU_POSITION + 2]
			f[v + NORMAL], f[v + NORMAL + 1], f[v + NORMAL + 2] = decode_normal(in_u[o + GPU_NORMAL])
			f[v + UV] = in_f[o + GPU_UV]
			f[v + UV + 1] = in_f[o + GPU_UV + 1]
			f[v + TANGENT], f[v + TANGENT + 1], f[v + TANGENT + 2], f[v + TANGENT + 3] = decode_tangent(in_u[o + GPU_TANGENT])
			ffi.copy(
				bytes + i * stride + cpu_core_stride,
				uniform and extras or extras + i * extras_stride,
				extras_stride
			)
		end

		return vertices
	end

	function vertex_layout.GetUniformExtras(vertices, count)
		if count == 0 then return nil end

		local words = ffi.cast("const uint32_t *", vertices)

		for w = 0, extras_words - 1 do
			reference[w] = words[cpu_core_words + w]
		end

		for i = 1, count - 1 do
			local at = i * word_stride + cpu_core_words

			for w = 0, extras_words - 1 do
				if words[at + w] ~= reference[w] then return nil end
			end
		end

		return ffi.string(reference, extras_stride)
	end
end

function vertex_layout.Get(name)
	return by_name[name] or error("unknown vertex field " .. tostring(name), 2)
end

function vertex_layout.GetOffset(name)
	return vertex_layout.Get(name).offset
end

function vertex_layout.GetFloatOffset(name)
	return vertex_layout.Get(name).float_offset
end

function vertex_layout.GetAttributes(binding, group)
	local attributes = {}

	for i, field in ipairs(FIELDS) do
		if not group or field.group == group then
			attributes[#attributes + 1] = {
				binding = binding or 0,
				location = i - 1,
				format = group and field.gpu_format or field.format,
				offset = group and field.group_offset or field.offset,
			}
		end
	end

	return attributes
end

function vertex_layout.GetShaderAttributes(group)
	local attributes = {}

	for _, field in ipairs(FIELDS) do
		if not group or field.group == group then
			attributes[#attributes + 1] = {field.name, field.glsl, field.format}
		end
	end

	return attributes
end

function vertex_layout.GetInputAttributes(group)
	local attributes = {}

	for _, field in ipairs(FIELDS) do
		if field.group == group then
			if field.packing then
				attributes[#attributes + 1] = {"packed_" .. field.name, "uint", field.gpu_format}
			else
				attributes[#attributes + 1] = {field.name, field.glsl, field.format}
			end
		end
	end

	return attributes
end

function vertex_layout.BuildInputDecodeGlsl()
	local lines = {}

	for _, field in ipairs(FIELDS) do
		if field.packing then
			lines[#lines + 1] = (
				"\t%s in_%s = vertex_layout_decode_%s(in_packed_%s);"
			):format(field.glsl, field.name, field.packing, field.name)
		end
	end

	return table.concat(lines, "\n")
end

function vertex_layout.BuildGlslAccessors(prefix, type_name, writable)
	local lines = {vertex_layout.PACKING_GLSL}

	for _, field in ipairs(FIELDS) do
		local name = field.alias:lower()

		if field.packing then
			local at = (
				"at_vertex * %du + %du"
			):format(vertex_layout.CoreFloatStride, field.group_float_offset)
			lines[#lines + 1] = (
				"%s %s_%s(%s b, uint at_vertex) {\n\treturn vertex_layout_decode_%s(floatBitsToUint(b.v[%s]));\n}\n"
			):format(field.glsl, prefix, name, type_name, field.packing, at)

			if writable then
				lines[#lines + 1] = (
					"void %s_set_%s(%s b, uint at_vertex, %s value) {\n\tb.v[%s] = uintBitsToFloat(vertex_layout_encode_%s(value));\n}\n"
				):format(prefix, name, type_name, field.glsl, at, field.packing)
			end

			goto continue
		end

		local components = {}
		local assignments = {}

		for i = 0, field.count - 1 do
			local stride = field.group == "core" and
				vertex_layout.CoreFloatStride or
				vertex_layout.ExtrasFloatStride
			local at = ("at_vertex * %du + %du"):format(stride, field.group_float_offset + i)
			components[#components + 1] = ("b.v[%s]"):format(at)

			if field.count == 1 then
				assignments[#assignments + 1] = ("\tb.v[%s] = value;"):format(at)
			else
				assignments[#assignments + 1] = ("\tb.v[%s] = value[%d];"):format(at, i)
			end
		end

		local value = field.count == 1 and
			components[1] or
			(
				"%s(%s)"
			):format(field.glsl, table.concat(components, ", "))
		lines[#lines + 1] = (
			"%s %s_%s(%s b, uint at_vertex) {\n\treturn %s;\n}\n"
		):format(field.glsl, prefix, name, type_name, value)

		if writable then
			lines[#lines + 1] = (
				"void %s_set_%s(%s b, uint at_vertex, %s value) {\n%s\n}\n"
			):format(
				prefix,
				name,
				type_name,
				field.glsl,
				table.concat(assignments, "\n")
			)
		end

		::continue::
	end

	return table.concat(lines, "\n")
end

return vertex_layout
