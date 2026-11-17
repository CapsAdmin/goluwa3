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
	},
	{name = "uv", alias = "UV", count = 2, glsl = "vec2", format = "r32g32_sfloat"},
	{
		name = "tangent",
		alias = "TANGENT",
		count = 4,
		glsl = "vec4",
		format = "r32g32b32a32_sfloat",
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
	field.group_offset = group_bytes[field.group]
	field.group_float_offset = field.group_offset / FLOAT_SIZE
	group_bytes[field.group] = group_bytes[field.group] + field.count * FLOAT_SIZE
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
assert(
	vertex_layout.CoreStride + vertex_layout.ExtrasStride == vertex_layout.Stride,
	"the vertex groups do not add up to the vertex"
)

do
	local core_stride, extras_stride, stride = vertex_layout.CoreStride, vertex_layout.ExtrasStride, vertex_layout.Stride
	local extras_words = extras_stride / 4
	local word_stride = stride / 4
	local core_words = core_stride / 4
	local reference = ffi.new("uint32_t[?]", extras_words)

	function vertex_layout.SplitInto(vertices, count, core, extras)
		local bytes = ffi.cast("const uint8_t *", vertices)

		for i = 0, count - 1 do
			ffi.copy(core + i * core_stride, bytes + i * stride, core_stride)
		end

		if extras then
			for i = 0, count - 1 do
				ffi.copy(extras + i * extras_stride, bytes + i * stride + core_stride, extras_stride)
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
		local uniform = type(extras) == "string"

		for i = 0, count - 1 do
			ffi.copy(bytes + i * stride, core + i * core_stride, core_stride)
			ffi.copy(
				bytes + i * stride + core_stride,
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
			reference[w] = words[core_words + w]
		end

		for i = 1, count - 1 do
			local at = words + i * word_stride + core_words

			for w = 0, extras_words - 1 do
				if at[w] ~= reference[w] then return nil end
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
				format = field.format,
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

function vertex_layout.BuildGlslAccessors(prefix, type_name, writable)
	local lines = {}

	for _, field in ipairs(FIELDS) do
		local name = field.alias:lower()
		local components = {}
		local assignments = {}

		for i = 0, field.count - 1 do
			local stride = field.group == "core" and
				vertex_layout.CoreFloatStride or
				vertex_layout.ExtrasFloatStride
			local at = ("vertex * %du + %du"):format(stride, field.group_float_offset + i)
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
			"%s %s_%s(%s b, uint vertex) {\n\treturn %s;\n}\n"
		):format(field.glsl, prefix, name, type_name, value)

		if writable then
			lines[#lines + 1] = (
				"void %s_set_%s(%s b, uint vertex, %s value) {\n%s\n}\n"
			):format(
				prefix,
				name,
				type_name,
				field.glsl,
				table.concat(assignments, "\n")
			)
		end
	end

	return table.concat(lines, "\n")
end

return vertex_layout
