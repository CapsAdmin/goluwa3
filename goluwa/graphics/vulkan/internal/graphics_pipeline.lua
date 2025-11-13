local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local GraphicsPipeline = {}
GraphicsPipeline.__index = GraphicsPipeline

function GraphicsPipeline.New(device, config, render_passes, pipelineLayout)
	local stageArrayType = ffi.typeof("$ [" .. #config.shaderModules .. "]", vulkan.vk.VkPipelineShaderStageCreateInfo)
	local shaderStagesArray = ffi.new(stageArrayType)

	for i, stage in ipairs(config.shaderModules) do
		shaderStagesArray[i - 1] = vulkan.vk.VkPipelineShaderStageCreateInfo(
			{
				sType = "VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO",
				stage = vulkan.enums.VK_SHADER_STAGE_(stage.type),
				module = stage.module.ptr[0],
				pName = "main",
			}
		)
	end

	-- Vertex input state
	local bindingArray = nil
	local attributeArray = nil
	local bindingCount = 0
	local attributeCount = 0

	if config.vertexBindings then
		bindingCount = #config.vertexBindings
		bindingArray = vulkan.T.Array(vulkan.vk.VkVertexInputBindingDescription)(bindingCount)

		for i, binding in ipairs(config.vertexBindings) do
			bindingArray[i - 1].binding = binding.binding
			bindingArray[i - 1].stride = binding.stride
			bindingArray[i - 1].inputRate = vulkan.enums.VK_VERTEX_INPUT_RATE_(binding.input_rate or "vertex")
		end
	end

	if config.vertexAttributes then
		attributeCount = #config.vertexAttributes
		attributeArray = vulkan.T.Array(vulkan.vk.VkVertexInputAttributeDescription)(attributeCount)

		for i, attr in ipairs(config.vertexAttributes) do
			attributeArray[i - 1].location = attr.location
			attributeArray[i - 1].binding = attr.binding
			attributeArray[i - 1].format = vulkan.enums.VK_FORMAT_(attr.format)
			attributeArray[i - 1].offset = attr.offset
		end
	end

	local vertexInputInfo = vulkan.vk.VkPipelineVertexInputStateCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO",
			vertexBindingDescriptionCount = bindingCount,
			pVertexBindingDescriptions = bindingArray,
			vertexAttributeDescriptionCount = attributeCount,
			pVertexAttributeDescriptions = attributeArray,
		}
	)
	config.input_assembly = config.input_assembly or {}
	local inputAssembly = vulkan.vk.VkPipelineInputAssemblyStateCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO",
			topology = vulkan.enums.VK_PRIMITIVE_TOPOLOGY_(config.input_assembly.topology or "triangle_list"),
			primitiveRestartEnable = config.input_assembly.primitive_restart or 0,
		}
	)
	config.viewport = config.viewport or {}
	local viewport = vulkan.vk.VkViewport(
		{
			x = config.viewport.x or 0.0,
			y = config.viewport.y or 0.0,
			width = config.viewport.w or 800,
			height = config.viewport.h or 600,
			minDepth = config.viewport.min_depth or 0.0,
			maxDepth = config.viewport.max_depth or 1.0,
		}
	)
	config.scissor = config.scissor or {}
	local scissor = vulkan.vk.VkRect2D(
		{
			offset = {x = config.scissor.x or 0, y = config.scissor.y or 0},
			extent = {
				width = config.scissor.w or 800,
				height = config.scissor.h or 600,
			},
		}
	)
	-- TODO: support more than one viewport/scissor
	local viewportState = vulkan.vk.VkPipelineViewportStateCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO",
			viewportCount = 1,
			pViewports = viewport,
			scissorCount = 1,
			pScissors = scissor,
		}
	)
	config.rasterizer = config.rasterizer or {}
	local rasterizer = vulkan.vk.VkPipelineRasterizationStateCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO",
			depthClampEnable = config.rasterizer.depth_clamp or 0,
			rasterizerDiscardEnable = config.rasterizer.discard or 0,
			polygonMode = vulkan.enums.VK_POLYGON_MODE_(config.rasterizer.polygon_mode or "fill"),
			lineWidth = config.rasterizer.line_width or 1.0,
			cullMode = vulkan.enums.VK_CULL_MODE_(config.rasterizer.cull_mode or "back"),
			frontFace = vulkan.enums.VK_FRONT_FACE_(config.rasterizer.front_face or "clockwise"),
			depthBiasEnable = config.rasterizer.depth_bias or 0,
		}
	)
	config.multisampling = config.multisampling or {}
	local multisampling = vulkan.vk.VkPipelineMultisampleStateCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO",
			sampleShadingEnable = config.multisampling.sample_shading or 0,
			rasterizationSamples = vulkan.enums.VK_SAMPLE_COUNT_(config.multisampling.rasterization_samples or "1"),
		}
	)
	config.color_blend = config.color_blend or {}
	config.color_blend.attachments = config.color_blend.attachments or {}
	local colorBlendAttachments = {}

	for i, color_blend_attachment in ipairs(config.color_blend.attachments) do
		colorBlendAttachments[i] = vulkan.vk.VkPipelineColorBlendAttachmentState(
			{
				colorWriteMask = vulkan.enums.VK_COLOR_COMPONENT_(color_blend_attachment.color_write_mask or {"R", "G", "B", "A"}),
				blendEnable = color_blend_attachment.blend or 0,
				srcColorBlendFactor = color_blend_attachment.src_color_blend_factor and
					vulkan.enums.VK_BLEND_FACTOR_(color_blend_attachment.src_color_blend_factor) or
					vulkan.enums.VK_BLEND_FACTOR_("one"),
				dstColorBlendFactor = color_blend_attachment.dst_color_blend_factor and
					vulkan.enums.VK_BLEND_FACTOR_(color_blend_attachment.dst_color_blend_factor) or
					vulkan.enums.VK_BLEND_FACTOR_("zero"),
				colorBlendOp = color_blend_attachment.color_blend_op and
					vulkan.enums.VK_BLEND_OP_(color_blend_attachment.color_blend_op) or
					vulkan.enums.VK_BLEND_OP_("add"),
				srcAlphaBlendFactor = color_blend_attachment.src_alpha_blend_factor and
					vulkan.enums.VK_BLEND_FACTOR_(color_blend_attachment.src_alpha_blend_factor) or
					vulkan.enums.VK_BLEND_FACTOR_("one"),
				dstAlphaBlendFactor = color_blend_attachment.dst_alpha_blend_factor and
					vulkan.enums.VK_BLEND_FACTOR_(color_blend_attachment.dst_alpha_blend_factor) or
					vulkan.enums.VK_BLEND_FACTOR_("zero"),
				alphaBlendOp = color_blend_attachment.alpha_blend_op and
					vulkan.enums.VK_BLEND_OP_(color_blend_attachment.alpha_blend_op) or
					vulkan.enums.VK_BLEND_OP_("add"),
			}
		)
	end

	local colorBlendAttachment = vulkan.T.Array(vulkan.vk.VkPipelineColorBlendAttachmentState)(#colorBlendAttachments)

	-- Copy attachments to array
	for i = 1, #colorBlendAttachments do
		colorBlendAttachment[i - 1] = colorBlendAttachments[i]
	end

	local colorBlending = vulkan.vk.VkPipelineColorBlendStateCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO",
			logicOpEnable = config.color_blend.logic_op_enabled or 0,
			logicOp = vulkan.enums.VK_LOGIC_OP_(config.color_blend.logic_op or "copy"),
			attachmentCount = #colorBlendAttachments,
			pAttachments = colorBlendAttachment,
			blendConstants = config.color_blend.constants or {0.0, 0.0, 0.0, 0.0},
		}
	)
	config.depth_stencil = config.depth_stencil or {}
	local depthStencilState = vulkan.vk.VkPipelineDepthStencilStateCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO",
			depthTestEnable = config.depth_stencil.depth_test or 0,
			depthWriteEnable = config.depth_stencil.depth_write or 0,
			depthCompareOp = vulkan.enums.VK_COMPARE_OP_(config.depth_stencil.depth_compare_op or "less"),
			depthBoundsTestEnable = config.depth_stencil.depth_bounds_test or 0,
			stencilTestEnable = config.depth_stencil.stencil_test or 0,
		}
	)
	-- Dynamic state configuration
	local dynamicStateInfo = nil

	if config.dynamic_states then
		local dynamicStateCount = #config.dynamic_states
		local dynamicStateArray = vulkan.T.Array(vulkan.vk.VkDynamicState)(dynamicStateCount)

		for i, state in ipairs(config.dynamic_states) do
			dynamicStateArray[i - 1] = vulkan.enums.VK_DYNAMIC_STATE_(state)
		end

		dynamicStateInfo = vulkan.vk.VkPipelineDynamicStateCreateInfo(
			{
				sType = "VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO",
				dynamicStateCount = dynamicStateCount,
				pDynamicStates = dynamicStateArray,
			}
		)
	end

	if render_passes[2] or (config.subpass and config.subpass ~= 0) then
		error("multiple render passes not supported yet")
	end

	local pipelineInfo = vulkan.vk.VkGraphicsPipelineCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO",
			stageCount = #config.shaderModules,
			pStages = shaderStagesArray,
			pVertexInputState = vertexInputInfo,
			pInputAssemblyState = inputAssembly,
			pViewportState = viewportState,
			pRasterizationState = rasterizer,
			pMultisampleState = multisampling,
			pDepthStencilState = depthStencilState,
			pColorBlendState = colorBlending,
			pDynamicState = dynamicStateInfo,
			layout = pipelineLayout.ptr[0],
			renderPass = render_passes[1].ptr[0],
			subpass = config.subpass or 0,
			basePipelineHandle = nil,
			basePipelineIndex = -1,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkPipeline)()
	vulkan.assert(
		vulkan.lib.vkCreateGraphicsPipelines(device.ptr[0], nil, 1, pipelineInfo, nil, ptr),
		"failed to create graphics pipeline"
	)
	return setmetatable({device = device, ptr = ptr, config = config}, GraphicsPipeline)
end

function GraphicsPipeline:__gc()
	vulkan.lib.vkDestroyPipeline(self.device.ptr[0], self.ptr[0], nil)
end

return GraphicsPipeline
