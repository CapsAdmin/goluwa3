local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local GraphicsPipeline = prototype.CreateTemplate("vulkan", "graphics_pipeline")
local EnumArray = ffi.typeof("uint32_t[?]")

function GraphicsPipeline.New(device, config, render_passes, pipelineLayout)
	local stageArrayType = ffi.typeof("$ [" .. #config.shaderModules .. "]", vulkan.vk.VkPipelineShaderStageCreateInfo)
	local shaderStagesArray = ffi.new(stageArrayType)

	for i, stage in ipairs(config.shaderModules) do
		shaderStagesArray[i - 1] = vulkan.vk.s.PipelineShaderStageCreateInfo(
			{
				stage = stage.type,
				module = stage.module.ptr[0],
				pName = "main",
				flags = 0,
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
			bindingArray[i - 1].inputRate = vulkan.vk.e.VkVertexInputRate(binding.input_rate or "vertex")
		end
	end

	if config.vertexAttributes then
		attributeCount = #config.vertexAttributes
		attributeArray = vulkan.T.Array(vulkan.vk.VkVertexInputAttributeDescription)(attributeCount)

		for i, attr in ipairs(config.vertexAttributes) do
			attributeArray[i - 1].location = attr.location
			attributeArray[i - 1].binding = attr.binding
			attributeArray[i - 1].format = vulkan.vk.e.VkFormat(attr.format)
			attributeArray[i - 1].offset = attr.offset
		end
	end

	local vertexInputInfo = vulkan.vk.s.PipelineVertexInputStateCreateInfo(
		{
			vertexBindingDescriptionCount = bindingCount,
			pVertexBindingDescriptions = bindingArray,
			vertexAttributeDescriptionCount = attributeCount,
			pVertexAttributeDescriptions = attributeArray,
			flags = 0,
		}
	)
	config.input_assembly = config.input_assembly or {}
	local inputAssembly = vulkan.vk.s.PipelineInputAssemblyStateCreateInfo(
		{
			topology = config.input_assembly.topology or "triangle_list",
			primitiveRestartEnable = config.input_assembly.primitive_restart or 0,
			flags = 0,
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
	local viewportState = vulkan.vk.s.PipelineViewportStateCreateInfo(
		{
			viewportCount = 1,
			pViewports = viewport,
			scissorCount = 1,
			pScissors = scissor,
			flags = 0,
		}
	)
	config.rasterizer = config.rasterizer or {}
	local rasterizer = vulkan.vk.s.PipelineRasterizationStateCreateInfo(
		{
			depthClampEnable = config.rasterizer.depth_clamp or 0,
			rasterizerDiscardEnable = config.rasterizer.discard or 0,
			polygonMode = config.rasterizer.polygon_mode or "fill",
			lineWidth = config.rasterizer.line_width or 1.0,
			cullMode = config.rasterizer.cull_mode or "back",
			frontFace = config.rasterizer.front_face or "clockwise",
			depthBiasEnable = (config.rasterizer.depth_bias and config.rasterizer.depth_bias ~= 0) and 1 or 0,
			-- 
			flags = 0,
			depthBiasConstantFactor = config.rasterizer.depth_bias_constant_factor or 0,
			depthBiasClamp = config.rasterizer.depth_bias_clamp or 0,
			depthBiasSlopeFactor = config.rasterizer.depth_bias_slope_factor or 0,
		}
	)
	config.multisampling = config.multisampling or {}
	local multisampling = vulkan.vk.s.PipelineMultisampleStateCreateInfo(
		{
			sampleShadingEnable = config.multisampling.sample_shading or 0,
			rasterizationSamples = config.multisampling.rasterization_samples or "1",
			--
			flags = 0,
			minSampleShading = 0,
			pSampleMask = nil,
			alphaToCoverageEnable = 0,
			alphaToOneEnable = 0,
		}
	)
	config.color_blend = config.color_blend or {}
	config.color_blend.attachments = config.color_blend.attachments or {}
	local colorBlendAttachments = {}

	for i, color_blend_attachment in ipairs(config.color_blend.attachments) do
		colorBlendAttachments[i] = vulkan.vk.s.PipelineColorBlendAttachmentState(
			{
				colorWriteMask = color_blend_attachment.color_write_mask or {"R", "G", "B", "A"},
				blendEnable = color_blend_attachment.blend or 0,
				srcColorBlendFactor = color_blend_attachment.src_color_blend_factor and
					color_blend_attachment.src_color_blend_factor or
					"one",
				dstColorBlendFactor = color_blend_attachment.dst_color_blend_factor and
					color_blend_attachment.dst_color_blend_factor or
					"zero",
				colorBlendOp = color_blend_attachment.color_blend_op and
					color_blend_attachment.color_blend_op or
					"add",
				srcAlphaBlendFactor = color_blend_attachment.src_alpha_blend_factor and
					color_blend_attachment.src_alpha_blend_factor or
					"one",
				dstAlphaBlendFactor = color_blend_attachment.dst_alpha_blend_factor and
					color_blend_attachment.dst_alpha_blend_factor or
					"zero",
				alphaBlendOp = color_blend_attachment.alpha_blend_op and
					color_blend_attachment.alpha_blend_op or
					"add",
			}
		)
	end

	local colorBlendAttachment = vulkan.T.Array(vulkan.vk.VkPipelineColorBlendAttachmentState)(#colorBlendAttachments)

	-- Copy attachments to array
	for i = 1, #colorBlendAttachments do
		colorBlendAttachment[i - 1] = colorBlendAttachments[i]
	end

	local blend_constants_data = (config.color_blend and config.color_blend.constants) or {0.0, 0.0, 0.0, 0.0}
	local blend_constants = ffi.new("float[4]", blend_constants_data)
	local colorBlending = vulkan.vk.s.PipelineColorBlendStateCreateInfo(
		{
			logicOpEnable = config.color_blend.logic_op_enabled or 0,
			logicOp = config.color_blend.logic_op or "copy",
			attachmentCount = #colorBlendAttachments,
			pAttachments = colorBlendAttachment,
			blendConstants = blend_constants,
			flags = 0,
		}
	)
	config.depth_stencil = config.depth_stencil or {}
	local defaultStencilOpState = vulkan.vk.s.StencilOpState(
		{
			failOp = "keep",
			passOp = "keep",
			depthFailOp = "keep",
			compareOp = "always",
			compareMask = 0,
			writeMask = 0,
			reference = 0,
		}
	)
	local depthStencilState = vulkan.vk.s.PipelineDepthStencilStateCreateInfo(
		{
			depthTestEnable = config.depth_stencil.depth_test or 0,
			depthWriteEnable = config.depth_stencil.depth_write or 0,
			depthCompareOp = config.depth_stencil.depth_compare_op or "less",
			depthBoundsTestEnable = config.depth_stencil.depth_bounds_test or 0,
			stencilTestEnable = config.depth_stencil.stencil_test or 0,
			flags = 0,
			front = defaultStencilOpState,
			back = defaultStencilOpState,
			minDepthBounds = 0,
			maxDepthBounds = 0,
		}
	)
	-- Dynamic state configuration
	local dynamicStateInfo = nil

	if config.dynamic_states then
		local dynamicStateCount = #config.dynamic_states
		local dynamicStateArray = EnumArray(dynamicStateCount)

		for i, state in ipairs(config.dynamic_states) do
			dynamicStateArray[i - 1] = vulkan.vk.e.VkDynamicState(state)
		end

		dynamicStateInfo = vulkan.vk.s.PipelineDynamicStateCreateInfo(
			{
				pNext = nil,
				flags = 0,
				dynamicStateCount = dynamicStateCount,
				pDynamicStates = dynamicStateArray,
			}
		)
	end

	if render_passes[2] or (config.subpass and config.subpass ~= 0) then
		error("multiple render passes not supported yet")
	end

	-- Handle depth-only pipelines (no color attachment)
	local colorAttachmentCount = 0
	local pColorAttachmentFormats = nil

	if render_passes[1].format then
		if type(render_passes[1].format) == "table" then
			colorAttachmentCount = #render_passes[1].format
			pColorAttachmentFormats = EnumArray(colorAttachmentCount)

			for i = 1, colorAttachmentCount do
				pColorAttachmentFormats[i - 1] = vulkan.vk.e.VkFormat(render_passes[1].format[i])
			end
		else
			colorAttachmentCount = 1
			pColorAttachmentFormats = EnumArray(1, {vulkan.vk.e.VkFormat(render_passes[1].format)})
		end
	end

	local pipelineRenderingCreateInfo = vulkan.vk.s.PipelineRenderingCreateInfo(
		{
			pNext = nil,
			viewMask = 0,
			colorAttachmentCount = colorAttachmentCount,
			pColorAttachmentFormats = pColorAttachmentFormats,
			depthAttachmentFormat = (
					render_passes[1].depth_format and
					render_passes[1].depth_format ~= false
				)
				and
				render_passes[1].depth_format or
				"undefined",
			stencilAttachmentFormat = "undefined",
		}
	)
	local pipelineInfo = vulkan.vk.s.GraphicsPipelineCreateInfo(
		{
			pNext = pipelineRenderingCreateInfo,
			flags = 0,
			stageCount = #config.shaderModules,
			pStages = shaderStagesArray,
			pVertexInputState = vertexInputInfo,
			pInputAssemblyState = inputAssembly,
			pTessellationState = nil,
			pViewportState = viewportState,
			pRasterizationState = rasterizer,
			pMultisampleState = multisampling,
			pDepthStencilState = depthStencilState,
			pColorBlendState = colorBlending,
			pDynamicState = dynamicStateInfo,
			layout = pipelineLayout.ptr[0],
			renderPass = nil,
			subpass = 0,
			basePipelineHandle = nil,
			basePipelineIndex = -1,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkPipeline)()
	vulkan.assert(
		vulkan.lib.vkCreateGraphicsPipelines(device.ptr[0], nil, 1, pipelineInfo, nil, ptr),
		"failed to create graphics pipeline"
	)
	return GraphicsPipeline:CreateObject({device = device, ptr = ptr, config = config})
end

function GraphicsPipeline:__gc()
	self.device:WaitIdle()
	vulkan.lib.vkDestroyPipeline(self.device.ptr[0], self.ptr[0], nil)
end

return GraphicsPipeline:Register()
