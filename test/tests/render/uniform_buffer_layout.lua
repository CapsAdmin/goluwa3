local T = import("test/environment.lua")
local ffi = require("ffi")
local glsl_meta = import("goluwa/render/glsl_metadata.lua")

T.Test("uniform buffer uint64 members start on 16 byte boundaries", function()
	local padded = glsl_meta.pad_uniform_buffer_uint64{
		{"a", "uint64_t"},
		{"b", "uint64_t"},
		{"c", "int"},
		{"d", "uint64_t"},
		{"e", "vec3"},
		{"f", "uint64_t"},
	}
	local struct = glsl_meta.typeof(glsl_meta.build_ffi_struct("scalar", padded))

	for _, name in ipairs{"a", "b", "d", "f"} do
		T(ffi.offsetof(struct, name) % 16)["=="](0)
	end

	T(ffi.offsetof(struct, "c"))["=="](ffi.offsetof(struct, "b") + 8)
	T(ffi.offsetof(struct, "e"))["=="](ffi.offsetof(struct, "d") + 8)
end)

T.Test("uniform buffer padding leaves blocks without uint64 members alone", function()
	local fields = {{"a", "int"}, {"b", "vec3"}, {"c", "float"}}
	T(#glsl_meta.pad_uniform_buffer_uint64(fields))["=="](3)
end)

T.Test("uniform buffer padding is idempotent", function()
	local once = glsl_meta.pad_uniform_buffer_uint64{{"a", "int"}, {"b", "uint64_t"}, {"c", "uint64_t"}}
	T(#glsl_meta.pad_uniform_buffer_uint64(once))["=="](#once)
end)
