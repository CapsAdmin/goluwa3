local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Sampler = {}
Sampler.__index = Sampler

function Sampler.New(device, config)
	config = config or {}
	-- Default values
	local min_filter = config.min_filter or "linear"
	local mag_filter = config.mag_filter or "linear"
	local mipmap_mode = config.mipmap_mode or "linear"
	local wrap_s = config.wrap_s or "repeat"
	local wrap_t = config.wrap_t or "repeat"
	local wrap_r = config.wrap_r or "repeat"
	local anisotropy = config.anisotropy or 1.0
	local max_lod = config.max_lod or 1000.0
	local samplerInfo = vulkan.vk.VkSamplerCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO",
			magFilter = vulkan.enums.VK_FILTER_(mag_filter),
			minFilter = vulkan.enums.VK_FILTER_(min_filter),
			mipmapMode = vulkan.enums.VK_SAMPLER_MIPMAP_MODE_(mipmap_mode),
			addressModeU = vulkan.enums.VK_SAMPLER_ADDRESS_MODE_(wrap_s),
			addressModeV = vulkan.enums.VK_SAMPLER_ADDRESS_MODE_(wrap_t),
			addressModeW = vulkan.enums.VK_SAMPLER_ADDRESS_MODE_(wrap_r),
			anisotropyEnable = anisotropy > 1.0 and 1 or 0,
			maxAnisotropy = anisotropy,
			borderColor = "VK_BORDER_COLOR_INT_OPAQUE_BLACK",
			unnormalizedCoordinates = 0,
			compareEnable = 0,
			compareOp = "VK_COMPARE_OP_ALWAYS",
			mipLodBias = 0.0,
			minLod = 0.0,
			maxLod = max_lod,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkSampler)()
	vulkan.assert(
		vulkan.lib.vkCreateSampler(device.ptr[0], samplerInfo, nil, ptr),
		"failed to create sampler"
	)
	return setmetatable(
		{
			ptr = ptr,
			device = device,
			min_filter = min_filter,
			mag_filter = mag_filter,
			mipmap_mode = mipmap_mode,
			wrap_s = wrap_s,
			wrap_t = wrap_t,
			wrap_r = wrap_r,
			anisotropy = anisotropy,
		},
		Sampler
	)
end

function Sampler:__gc()
	vulkan.lib.vkDestroySampler(self.device.ptr[0], self.ptr[0], nil)
end

return Sampler
