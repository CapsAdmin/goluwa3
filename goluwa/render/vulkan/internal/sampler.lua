local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Sampler = prototype.CreateTemplate("vulkan", "sampler")

function Sampler.New(config)
	config = config or {}
	assert(config.device)
	local ptr = vulkan.T.Box(vulkan.vk.VkSampler)()
	local anisotropy = nil
	local anisotropyEnable = nil

	if config.anisotropy then
		assert(type(config.anisotropy) == "number")
		anisotropyEnable = assert(
			config.anisotropy >= 1 and config.anisotropy <= 16,
			"anisotropy must be between 1 and 16"
		)
		anisotropy = config.anisotropy
	end

	vulkan.assert(
		vulkan.lib.vkCreateSampler(
			config.device.ptr[0],
			vulkan.vk.s.SamplerCreateInfo(
				{
					flags = config.flags,
					magFilter = config.mag_filter or "linear",
					minFilter = config.min_filter or "linear",
					mipmapMode = config.mipmap_mode or "linear",
					addressModeU = config.wrap_s or "repeat",
					addressModeV = config.wrap_t or "repeat",
					addressModeW = config.wrap_r or "repeat",
					anisotropyEnable = anisotropy and 1 or 0,
					maxAnisotropy = anisotropy or 0,
					borderColor = config.border_color or "int_opaque_black",
					unnormalizedCoordinates = config.unnormalized_coordinates and 1 or 0,
					compareEnable = config.compare_enable and 1 or 0,
					compareOp = config.compare_op or "always",
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
	return Sampler:CreateObject({
		ptr = ptr,
		device = config.device,
	})
end

function Sampler:__gc()
	vulkan.lib.vkDestroySampler(self.device.ptr[0], self.ptr[0], nil)
end

return Sampler:Register()
