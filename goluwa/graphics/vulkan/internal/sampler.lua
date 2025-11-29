local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local ffi_helpers = require("helpers.ffi_helpers")
local e = ffi_helpers.translate_enums(
	{
		{vulkan.vk.VkSamplerAddressMode, "VK_SAMPLER_ADDRESS_MODE_"},
		{vulkan.vk.VkSamplerMipmapMode, "VK_SAMPLER_MIPMAP_MODE_"},
		{vulkan.vk.VkFilter, "VK_FILTER_"},
		{vulkan.vk.VkSamplerCreateFlagBits, "VK_SAMPLER_CREATE_", "_BIT"},
		{vulkan.vk.VkCompareOp, "VK_COMPARE_OP_"},
		{vulkan.vk.VkBorderColor, "VK_BORDER_COLOR_"},
	}
)
local Sampler = {}
Sampler.__index = Sampler

function Sampler.New(config)
	config = config or {}
	assert(config.device)
	local ptr = vulkan.T.Box(vulkan.vk.VkSampler)()
	local anisotropy = nil

	if config.anisotropy then
		assert(type(config.anisotropy) == "number")
		anisotropy = assert(
			config.anisotropy >= 1 and config.anisotropy <= 16,
			"anisotropy must be between 1 and 16"
		)
	end

	vulkan.assert(
		vulkan.lib.vkCreateSampler(
			config.device.ptr[0],
			vulkan.vk.VkSamplerCreateInfo(
				{
					sType = "VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO",
					flags = config.flags and e.VK_SAMPLER_CREATE_(config.flags) or 0,
					magFilter = e.VK_FILTER_(config.mag_filter or "linear"),
					minFilter = e.VK_FILTER_(config.min_filter or "linear"),
					mipmapMode = e.VK_SAMPLER_MIPMAP_MODE_(config.mipmap_mode or "linear"),
					addressModeU = e.VK_SAMPLER_ADDRESS_MODE_(config.wrap_s or "repeat"),
					addressModeV = e.VK_SAMPLER_ADDRESS_MODE_(config.wrap_t or "repeat"),
					addressModeW = e.VK_SAMPLER_ADDRESS_MODE_(config.wrap_r or "repeat"),
					anisotropyEnable = anisotropy and 1 or 0,
					maxAnisotropy = anisotropy or 0,
					borderColor = e.VK_BORDER_COLOR_(config.border_color or "int_opaque_black"),
					unnormalizedCoordinates = config.unnormalized_coordinates and 1 or 0,
					compareEnable = config.compare_enable and 1 or 0,
					compareOp = e.VK_COMPARE_OP_(config.compare_op or "always"),
					mipLodBias = config.mip_lod_bias or 0.0,
					minLod = config.min_lod or 0,
					maxLod = config.max_lod or 1000.0,
				}
			),
			nil,
			ptr
		),
		"failed to create sampler"
	)
	return setmetatable({
		ptr = ptr,
		device = config.device,
	}, Sampler)
end

function Sampler:__gc()
	vulkan.lib.vkDestroySampler(self.device.ptr[0], self.ptr[0], nil)
end

return Sampler
