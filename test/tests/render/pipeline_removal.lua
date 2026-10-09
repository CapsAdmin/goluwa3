local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local event = import("goluwa/event.lua")
test_render.Init()

local function create_compute_pipeline()
	return EasyPipeline.New{
		name = "pipeline_removal_test",
		ComputePass = true,
		ColorFormat = {{"r8g8b8a8_unorm", {"color", "rgba"}}},
		FramebufferSize = {x = 4, y = 4},
		framebuffer_count = 1,
		LocalSize = {x = 4, y = 4, z = 1},
		storage_images = {{binding_index = 0, dst_stage = "compute"}},
		custom_declarations = [[
			layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_color;
		]],
		shader = [[
			void main() {
				imageStore(out_color, ivec2(gl_GlobalInvocationID.xy), vec4(1.0));
			}
		]],
	}
end

T.Test("Graphics compute pipeline stops listening to textures when it is removed", function()
	local pipeline = create_compute_pipeline()
	local internal = pipeline.pipeline
	T(event.IsListenerActive("TextureViewChanged", internal))["=="](true)
	T(event.IsListenerActive("TextureRemoved", internal))["=="](true)
	pipeline:Remove()
	T(event.IsListenerActive("TextureViewChanged", internal))["=="](false)
	T(event.IsListenerActive("TextureRemoved", internal))["=="](false)
end)
