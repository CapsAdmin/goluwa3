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

function vertex_layout.Get(name)
	return by_name[name] or error("unknown vertex field " .. tostring(name), 2)
end

function vertex_layout.GetOffset(name)
	return vertex_layout.Get(name).offset
end

function vertex_layout.GetFloatOffset(name)
	return vertex_layout.Get(name).float_offset
end

function vertex_layout.GetAttributes(binding)
	local attributes = {}

	for i, field in ipairs(FIELDS) do
		attributes[i] = {
			binding = binding or 0,
			location = i - 1,
			format = field.format,
			offset = field.offset,
		}
	end

	return attributes
end

function vertex_layout.GetShaderAttributes()
	local attributes = {}

	for i, field in ipairs(FIELDS) do
		attributes[i] = {field.name, field.glsl, field.format}
	end

	return attributes
end

function vertex_layout.BuildGlslDefines(prefix)
	local lines = {("#define %s_STRIDE %du"):format(prefix, vertex_layout.FloatStride)}

	for _, field in ipairs(FIELDS) do
		lines[#lines + 1] = ("#define %s_%s %du"):format(prefix, field.alias, field.float_offset)
	end

	return table.concat(lines, "\n")
end

return vertex_layout
