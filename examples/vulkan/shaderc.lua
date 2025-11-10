
local shaderc = require("shaderc")

-- GLSL vertex shader source code
local data, size = shaderc.compile[[
    #version 450
    layout(location = 0) in vec3 inPosition;
    void main() {
        gl_Position = vec4(inPosition, 1.0);
    }
]]
print("SPIR-V size:", size, "bytes")
--local spirv_uint32_ptr = ffi.cast("const uint32_t*", spirv_data)