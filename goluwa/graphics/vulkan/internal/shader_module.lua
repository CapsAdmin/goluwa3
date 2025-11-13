local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local shaderc = require("bindings.shaderc")
local ShaderModule = {}
ShaderModule.__index = ShaderModule

function ShaderModule.New(device, glsl, type)
	local spirv_data, spirv_size = shaderc.compile(glsl, type)
	local shaderModuleCreateInfo = vulkan.vk.VkShaderModuleCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO",
			codeSize = spirv_size,
			pCode = ffi.cast("const uint32_t*", spirv_data),
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkShaderModule)()
	vulkan.assert(
		vulkan.lib.vkCreateShaderModule(device.ptr[0], shaderModuleCreateInfo, nil, ptr),
		"failed to create shader module"
	)
	return setmetatable({ptr = ptr, device = device}, ShaderModule)
end

function ShaderModule:__gc()
	vulkan.lib.vkDestroyShaderModule(self.device.ptr[0], self.ptr[0], nil)
end

return ShaderModule
