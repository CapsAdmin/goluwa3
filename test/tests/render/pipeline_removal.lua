local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
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

T.Test("Removing a pipeline keeps the shared bindless layout and set alive", function()
	local first = create_compute_pipeline()
	local second = create_compute_pipeline()
	local state = second.pipeline.bindless
	T(first.pipeline.bindless == state)["=="](true)
	first:Remove()
	second:Remove()
	T(state.layout:IsValid())["=="](true)
	T(state.layout.ptr[0] ~= nil)["=="](true)
	local third = create_compute_pipeline()
	T(third.pipeline.bindless == state)["=="](true)
	third:Remove()
end)
