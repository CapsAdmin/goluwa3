local T = import("test/environment.lua")
local ffi = require("ffi")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")

T.Test("the vertex layout is tightly packed and every consumer reads it from there", function()
	local floats = 0

	for _, field in ipairs(vertex_layout.Fields) do
		T(field.float_offset)["=="](floats)
		T(ffi.offsetof(vertex_layout.Type, field.name))["=="](field.offset)
		floats = floats + field.count
	end

	T(vertex_layout.FloatStride)["=="](floats)
	T(ffi.sizeof(vertex_layout.Type))["=="](vertex_layout.Stride)
	T(vertex_layout.Stride)["=="](floats * 4)
	local binding = model_pipeline.GetVertexBufferBinding(0)
	T(binding.stride)["=="](vertex_layout.Stride)
	T(model_pipeline.GetVertexStride())["=="](vertex_layout.Stride)
	local attributes = model_pipeline.GetVertexAttributeLayout(0)
	T(#attributes)["=="](#vertex_layout.Fields)

	for i, field in ipairs(vertex_layout.Fields) do
		T(attributes[i].offset)["=="](field.offset)
		T(attributes[i].location)["=="](i - 1)
		T(attributes[i].format)["=="](field.format)
		T(model_pipeline.GetVertexAttributes()[i][1])["=="](field.name)
	end

	local defines = vertex_layout.BuildGlslDefines("TEST_VERTEX")
	T(
		defines:find("#define TEST_VERTEX_STRIDE " .. vertex_layout.FloatStride .. "u", 1, true)
	)["~="](nil)

	for _, field in ipairs(vertex_layout.Fields) do
		T(
			defines:find(
				"#define TEST_VERTEX_" .. field.alias .. " " .. field.float_offset .. "u",
				1,
				true
			)
		)["~="](nil)
	end

	local ok, err = pcall(vertex_layout.Get, "nope")
	T(ok)["=="](false)
	T(tostring(err))["contains"]("unknown vertex field")
end)
