local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")

local function create_pipeline(extra)
	local config = {
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450
					void main() {
						vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
						gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
					}
				]],
			},
			{
				type = "fragment",
				code = [[
					#version 450
					layout(location = 0) out vec4 out_color;
					void main() {
						out_color = vec4(1.0, 1.0, 1.0, 1.0);
					}
				]],
			},
		},
	}

	for key, value in pairs(extra or {}) do
		config[key] = value
	end

	return render.CreateGraphicsPipeline(config)
end

local function expect_error(callback)
	local ok = pcall(callback)

	if ok then error("expected failure") end
end

local function create_easy_pipeline(extra)
	local config = {
		fragment = {
			shader = [[
				void main() {
					out_color = vec4(1.0, 1.0, 1.0, 1.0);
				}
			]],
		},
	}

	for key, value in pairs(extra or {}) do
		config[key] = value
	end

	return EasyPipeline.New(config)
end

T.Test3D("GraphicsPipeline property validation and reset", function()
	local pipeline = create_pipeline()
	pipeline:SetTopology("line_strip")
	pipeline:SetPolygonMode("line")
	pipeline:SetFrontStencilReference(4)
	pipeline:SetBackStencilReference(4)
	pipeline:SetBlendConstants{0.1, 0.2, 0.3, 0.4}
	T(pipeline:GetTopology())["=="]("line_strip")
	T(pipeline:GetPolygonMode())["=="]("line")
	T(pipeline:GetFrontStencilReference())["=="](4)
	T(pipeline:GetBackStencilReference())["=="](4)
	T(pipeline:GetBlendConstants()[1])["=="](0.1)

	expect_error(function()
		pipeline:SetTopology("triangles")
	end)

	expect_error(function()
		pipeline:SetPolygonMode("LINE")
	end)

	expect_error(function()
		pipeline:SetBlend("true")
	end)

	expect_error(function()
		pipeline:SetColorWriteMask({"r", "invalid"})
	end)

	expect_error(function()
		pipeline:SetBlendConstants({1, 2, 3})
	end)

	pipeline:ResetToBase()
	T(pipeline:GetTopology())["=="]("triangle_list")
	T(pipeline:GetPolygonMode())["=="]("fill")
	T(pipeline:GetFrontStencilReference())["=="](0)
	T(pipeline:GetBackStencilReference())["=="](0)
	T(pipeline:GetBlendConstants()[1])["=="](0)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline constructor PascalCase properties", function()
	local supports_sample_shading = render.GetDevice().physical_device:GetFeatures().sampleRateShading ~= 0
	local pipeline = create_pipeline{
		Topology = "line_list",
		ViewportWidth = 123,
		ViewportHeight = 45,
		ScissorWidth = 67,
		ScissorHeight = 23,
		SampleShading = supports_sample_shading,
		MinSampleShading = 0.5,
		Blend = true,
		SrcColorBlendFactor = "src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		FrontStencilReference = 9,
		BackStencilReference = 9,
		CullMode = "front",
	}
	T(pipeline:GetTopology())["=="]("line_list")
	T(pipeline:GetViewportWidth())["=="](123)
	T(pipeline:GetViewportHeight())["=="](45)
	T(pipeline:GetScissorWidth())["=="](67)
	T(pipeline:GetScissorHeight())["=="](23)
	T(pipeline:GetSampleShading())["=="](supports_sample_shading)
	T(pipeline:GetMinSampleShading())["=="](0.5)
	T(pipeline:GetBlend())["=="](true)
	T(pipeline:GetSrcColorBlendFactor())["=="]("src_alpha")
	T(pipeline:GetDstColorBlendFactor())["=="]("one_minus_src_alpha")
	T(pipeline:GetFrontStencilReference())["=="](9)
	T(pipeline:GetBackStencilReference())["=="](9)
	T(pipeline:GetCullMode())["=="]("front")
	T(pipeline.static_variant_dirty)["=="](false)
	T(pipeline.bind_state_dirty)["=="](false)
	pipeline:Remove()

	if not supports_sample_shading then
		expect_error(function()
			create_pipeline{
				SampleShading = true,
			}
		end)
	end
end)

T.Test3D("GraphicsPipeline constructor PascalCase config aliases", function()
	local color_format = render.target:GetColorFormat()
	local depth_format = render.target:GetDepthFormat()
	local samples = render.target:GetSamples()
	local pipeline = create_pipeline{
		ColorFormat = color_format,
		DepthFormat = depth_format,
		RasterizationSamples = samples,
		DescriptorSetCount = 1,
	}
	T(pipeline:GetColorFormat())["=="](color_format)
	T(pipeline:GetDepthFormat())["=="](depth_format)
	T(pipeline:GetRasterizationSamples())["=="](samples)
	T(pipeline:GetDescriptorSetCount())["=="](1)
	pipeline:Remove()
end)

T.Test3D("GraphicsPipeline rejects snake case top-level config aliases", function()
	expect_error(function()
		create_pipeline{
			color_format = render.target:GetColorFormat(),
		}
	end)

	expect_error(function()
		create_pipeline{
			depth_format = render.target:GetDepthFormat(),
		}
	end)

	expect_error(function()
		create_pipeline{
			Samples = render.target:GetSamples(),
		}
	end)

	expect_error(function()
		create_pipeline{
			samples = render.target:GetSamples(),
		}
	end)

	expect_error(function()
		create_pipeline{
			rasterization_samples = render.target:GetSamples(),
		}
	end)

	expect_error(function()
		create_pipeline{
			descriptor_set_count = 1,
		}
	end)

	expect_error(function()
		create_pipeline{
			dynamic_states = {"viewport"},
		}
	end)

	expect_error(function()
		create_pipeline{
			dynamic_state = {"viewport"},
		}
	end)

	expect_error(function()
		create_pipeline{
			DynamicStates = {"viewport"},
		}
	end)

	expect_error(function()
		create_pipeline{
			static = true,
		}
	end)

	expect_error(function()
		create_pipeline{
			input_assembly = {
				topology = "triangle_list",
			},
		}
	end)

	expect_error(function()
		create_pipeline{
			input_assembly = {
				primitive_restart = true,
			},
		}
	end)

	expect_error(function()
		create_pipeline{
			viewport = {
				w = 32,
			},
		}
	end)

	expect_error(function()
		create_pipeline{
			scissor = {
				w = 32,
			},
		}
	end)

	expect_error(function()
		create_pipeline{
			multisampling = {
				rasterization_samples = "4",
			},
		}
	end)

	expect_error(function()
		create_pipeline{
			multisampling = {
				sample_shading = true,
			},
		}
	end)

	expect_error(function()
		create_pipeline{
			multisampling = {
				min_sample_shading = 0.5,
			},
		}
	end)
end)

T.Test3D("GraphicsPipeline dirty tracking uses property dynamic state metadata", function()
	local pipeline = create_pipeline()
	pipeline.dynamic_states = {
		polygon_mode_ext = true,
		stencil_reference = true,
	}
	pipeline:SetPolygonMode("line")
	T(pipeline.bind_state_dirty)["=="](true)
	T(pipeline.static_variant_dirty)["=="](false)
	pipeline:ResetToBase()
	pipeline:SetFrontStencilReference(7)
	T(pipeline.bind_state_dirty)["=="](true)
	T(pipeline.static_variant_dirty)["=="](false)
	pipeline:ResetToBase()
	pipeline:SetFrontStencilFailOp("replace")
	T(pipeline.bind_state_dirty)["=="](true)
	T(pipeline.static_variant_dirty)["=="](true)
	pipeline:ResetToBase()
	pipeline:SetBlendConstants{0.4, 0.3, 0.2, 0.1}
	T(pipeline.bind_state_dirty)["=="](true)
	T(pipeline.static_variant_dirty)["=="](true)
	pipeline:ResetToBase()
	pipeline:SetRasterizationSamples("4")
	T(pipeline.bind_state_dirty)["=="](true)
	T(pipeline.static_variant_dirty)["=="](true)
	pipeline:ResetToBase()
	pipeline:SetSampleShading(true)
	T(pipeline.bind_state_dirty)["=="](true)
	T(pipeline.static_variant_dirty)["=="](true)
	pipeline:Remove()
end)

T.Test3D("EasyPipeline rejects nested public property config", function()
	expect_error(function()
		create_easy_pipeline{
			input_assembly = {
				topology = "triangle_list",
			},
		}
	end)

	expect_error(function()
		create_easy_pipeline{
			rasterizer = {
				cull_mode = "none",
			},
		}
	end)

	expect_error(function()
		create_easy_pipeline{
			depth_stencil = {
				front = {
					fail_op = "replace",
				},
			},
		}
	end)

	expect_error(function()
		create_easy_pipeline{
			color_blend = {
				attachments = {
					{blend = true},
				},
			},
		}
	end)

	expect_error(function()
		create_easy_pipeline{
			multisampling = {
				rasterization_samples = "4",
			},
		}
	end)

	expect_error(function()
		create_easy_pipeline{
			multisampling = {
				sample_shading = true,
			},
		}
	end)

	expect_error(function()
		create_easy_pipeline{
			multisampling = {
				min_sample_shading = 0.5,
			},
		}
	end)

	expect_error(function()
		create_easy_pipeline{
			viewport = {
				w = 32,
			},
		}
	end)

	expect_error(function()
		create_easy_pipeline{
			scissor = {
				w = 32,
			},
		}
	end)

	local pipeline = create_easy_pipeline{
		ColorFormat = {render.target:GetColorFormat(), render.target:GetColorFormat()},
		color_blend = {
			attachments = {
				{},
				{},
			},
		},
	}
	pipeline:Remove()
end)

T.Test3D("EasyPipeline rejects legacy snake_case top-level config", function()
	local ok, err = pcall(function()
		EasyPipeline.New{
			mesh_layout = {render.mesh2d_layout},
			VertexShader = "#version 450\nvoid main() { gl_Position = vec4(0.0); }",
			FragmentShader = "#version 450\nlayout(location = 0) out vec4 out_color; void main() { out_color = vec4(1.0); }",
			color_format = {"r8g8b8a8_unorm"},
		}
	end)
	assert(not ok)
	assert(
		tostring(err):find("use PascalCase ColorFormat instead of snake_case color_format")
	)
	ok, err = pcall(function()
		EasyPipeline.New{
			mesh_layout = {render.mesh2d_layout},
			VertexShader = "#version 450\nvoid main() { gl_Position = vec4(0.0); }",
			FragmentShader = "#version 450\nlayout(location = 0) out vec4 out_color; void main() { out_color = vec4(1.0); }",
			Samples = "1",
		}
	end)
	assert(not ok)
	assert(tostring(err):find("use RasterizationSamples instead of Samples"))
end)
