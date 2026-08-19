local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local module = {}

-- Full shader_stages config for a trivial fullscreen white pipeline.
-- Extra keys are merged on top.
function module.CreatePipeline(extra)
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

-- EasyPipeline equivalent of CreatePipeline.
function module.CreateEasyPipeline(extra)
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

return module
