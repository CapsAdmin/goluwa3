local ffi = require("ffi")
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

T.Test3D("EasyPipeline exposes push constant layout metadata", function()
	local writes = 0
	local pipeline = EasyPipeline.New{
		ColorFormat = render.target:GetColorFormat(),
		vertex = {
			push_constants = {
				{
					name = "camera",
					block = {
						{"projection_view_world", "mat4"},
					},
				},
			},
			shader = [[
				void main() {
					gl_Position = camera.projection_view_world * vec4(0.0, 0.0, 0.0, 1.0);
				}
			]],
		},
		fragment = {
			push_constants = {
				{
					name = "fragment",
					write = function(self, constants)
						writes = writes + 1
						constants.value = 7
					end,
					block = {
						{"value", "int"},
					},
				},
			},
			shader = [[
				void main() {
					out_color = vec4(float(fragment.value) / 7.0, 1.0, 1.0, 1.0);
				}
			]],
		},
	}
	local camera_type = pipeline:GetPushConstantBlockType("camera")
	local fragment_type = pipeline:GetPushConstantBlockType("fragment")
	T(pipeline:GetPushConstantBlockOffset("camera"))["=="](0)
	T(pipeline:GetPushConstantBlockSize("camera"))["=="](64)
	T(pipeline:GetPushConstantBlockOffset("fragment"))["=="](64)
	T(pipeline:GetPushConstantBlockSize("fragment"))["=="](16)
	T(tonumber(ffi.offsetof(camera_type, "projection_view_world")))["=="](0)
	T(tonumber(ffi.offsetof(fragment_type, "value")))["=="](0)
	local fragment = fragment_type()
	pipeline.push_constant_blocks.fragment.write(pipeline, fragment, pipeline.push_constant_blocks.fragment)
	T(writes)["=="](1)
	T(fragment.value)["=="](7)
	pipeline:Remove()
end)

T.Test3D("EasyPipeline resolves constants storage automatically", function()
	local pipeline = EasyPipeline.New{
		ColorFormat = render.target:GetColorFormat(),
		ConstantPlacement = {
			push_budget = 80,
		},
		vertex = {
			constants = {
				{
					name = "camera",
					storage = "push",
					block = {
						{"projection_view_world", "mat4"},
					},
				},
			},
			shader = [[
				void main() {
					gl_Position = camera.projection_view_world * vec4(0.0, 0.0, 0.0, 1.0);
				}
			]],
		},
		fragment = {
			constants = {
				{
					name = "draw",
					storage = "auto",
					prefer = "push",
					block = {
						{"global_color", "vec4"},
						{"uv_transform", "vec4"},
					},
				},
			},
			shader = [[
				void main() {
					out_color = draw.global_color + draw.uv_transform;
				}
			]],
		},
	}
	local camera = pipeline:GetConstantBlockInfo("camera")
	local draw = pipeline:GetConstantBlockInfo("draw")
	T(camera.storage)["=="]("push")
	T(camera.size)["=="](64)
	T(camera.offset)["=="](0)
	T(draw.storage)["=="]("uniform_buffer")
	T(draw.binding_index)[">="](2)
	T(draw.offset)["=="](nil)
	pipeline:Remove()
end)

T.Test2D("EasyPipeline runs uniform buffer constant write callbacks during upload", function()
	local writes = 0
	local pipeline = EasyPipeline.New{
		ColorFormat = render.target:GetColorFormat(),
		vertex = {
			shader = [[
				void main() {
					gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
				}
			]],
		},
		fragment = {
			constants = {
				{
					name = "draw",
					storage = "uniform_buffer",
					write = function(self, constants)
						writes = writes + 1
						constants.value = 3.5
					end,
					block = {
						{"value", "float"},
					},
				},
			},
			shader = [[
				void main() {
					out_color = vec4(draw.value / 3.5, 1.0, 1.0, 1.0);
				}
			]],
		},
	}
	pipeline:UploadConstants()
	local draw = pipeline:GetConstantBlockInfo("draw")
	local ubo_data = pipeline.uniform_buffers[draw.name]:GetData()
	return function()
		T(writes)["=="](1)
		T(ubo_data.value)["=="](3.5)
		pipeline:Remove()
	end
end)

T.Test2D("EasyPipeline copies constant block source slices before upload", function()
	local aggregate = EasyPipeline.BuildFFIType(
		"scalar",
		"GraphicsPipelinePropertiesAggregate",
		{
			{"padding", "vec4"},
			{"value", "float"},
			{"uv", "vec2"},
		}
	)()
	aggregate.value = 2
	aggregate.uv[0] = 0.25
	aggregate.uv[1] = 0.75
	local pipeline = EasyPipeline.New{
		ColorFormat = render.target:GetColorFormat(),
		vertex = {
			shader = [[
				void main() {
					gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
				}
			]],
		},
		fragment = {
			constants = {
				{
					name = "draw",
					storage = "uniform_buffer",
					source = {
						get = function()
							return aggregate
						end,
						ctype = ffi.typeof(aggregate),
						field = "value",
					},
					write = function(self, constants)
						constants.value = constants.value * 2
					end,
					block = {
						{"value", "float"},
						{"uv", "vec2"},
					},
				},
			},
			shader = [[
				void main() {
					out_color = vec4(draw.value, draw.uv.x, draw.uv.y, 1.0);
				}
			]],
		},
	}
	pipeline:UploadConstants()
	local draw = pipeline.uniform_buffers.draw:GetData()
	return function()
		T(draw.value)["=="](4)
		T(draw.uv[0])["=="](0.25)
		T(draw.uv[1])["=="](0.75)
		pipeline:Remove()
	end
end)

T.Test3D("EasyPipeline auto constants coexist with explicit push constants", function()
	local pipeline = EasyPipeline.New{
		ColorFormat = render.target:GetColorFormat(),
		ConstantPlacement = {
			push_budget = 96,
		},
		vertex = {
			push_constants = {
				{
					name = "camera",
					block = {
						{"projection_view_world", "mat4"},
					},
				},
			},
			shader = [[
				void main() {
					gl_Position = camera.projection_view_world * vec4(0.0, 0.0, 0.0, 1.0);
				}
			]],
		},
		fragment = {
			constants = {
				{
					name = "draw",
					storage = "auto",
					prefer = "push",
					priority = 100,
					block = {
						{"uv_transform", "vec4"},
					},
				},
				{
					name = "shape",
					storage = "auto",
					prefer = "push",
					priority = 50,
					block = {
						{"border_radius", "vec4"},
						{"rect_size", "vec2"},
					},
				},
			},
			shader = [[
				void main() {
					out_color = draw.uv_transform + vec4(shape.border_radius.xy, shape.rect_size);
				}
			]],
		},
	}
	local draw = pipeline:GetConstantBlockInfo("draw")
	local shape = pipeline:GetConstantBlockInfo("shape")
	T(pipeline:GetPushConstantBlockOffset("camera"))["=="](0)
	T(pipeline:GetPushConstantBlockSize("camera"))["=="](64)
	T(draw.storage)["=="]("push")
	T(draw.offset)["=="](64)
	T(shape.storage)["=="]("uniform_buffer")
	T(shape.binding_index)[">="](2)
	pipeline:Remove()
end)

T.Test3D("EasyPipeline rejects push layouts that exceed the configured budget", function()
	local ok, err = pcall(function()
		EasyPipeline.New{
			ColorFormat = render.target:GetColorFormat(),
			ConstantPlacement = {
				push_budget = 64,
			},
			vertex = {
				push_constants = {
					{
						name = "camera",
						block = {
							{"projection_view_world", "mat4"},
						},
					},
				},
				shader = [[
					void main() {
						gl_Position = camera.projection_view_world * vec4(0.0, 0.0, 0.0, 1.0);
					}
				]],
			},
			fragment = {
				constants = {
					{
						name = "draw",
						storage = "push",
						block = {
							{"uv_transform", "vec4"},
						},
					},
				},
				shader = [[
					void main() {
						out_color = draw.uv_transform;
					}
				]],
			},
		}
	end)
	T(ok)["=="](false)
	assert(tostring(err):find("configured budget is 64"))
end)
