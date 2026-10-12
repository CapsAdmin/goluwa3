local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local sizes = {{8, 6}, {9, 6}, {8, 7}, {9, 7}, {1, 1}, {801, 481}, {3440, 1369}}
local mapping_pass = {
	name = "ssr_mapping_test",
	ComputePass = true,
	ColorFormat = {{"r32g32b32a32_sfloat", {"mapped", "rgba"}}},
	FramebufferSize = {x = 9, y = #sizes * 4},
	framebuffer_count = 1,
	LocalSize = {x = 1, y = 1, z = 1},
	storage_images = {{binding_index = 0, dst_stage = "compute"}},
	custom_declarations = [[layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_mapped;]],
	shader = ibl.GetSSRQuadGLSL() .. [[
		void main() {
			ivec2 output_pos = ivec2(gl_GlobalInvocationID.xy);
			const ivec2 sizes[7] = ivec2[7](ivec2(8,6), ivec2(9,6), ivec2(8,7), ivec2(9,7), ivec2(1,1), ivec2(801,481), ivec2(3440,1369));
			ivec2 full_size = sizes[output_pos.y / 4];
			ivec2 half_size = (full_size + 1) / 2;
			ivec2 pos = ivec2(output_pos.x % 3, output_pos.x / 3) * (half_size - 1) / 2;
			imageStore(out_mapped, output_pos, vec4(get_ssr_gbuffer_pos(pos, output_pos.y % 4, full_size, half_size), pos));
		}
	]],
}

T.Test3D("Graphics render3d reflection sampling covers resized odd dimensions", function(draw)
	render3d.Initialize{passes = {import("goluwa/render3d/passes/gbuffer.lua"), mapping_pass, import("goluwa/render3d/passes/blit.lua")}}
	local ok, err = pcall(draw)
	local downloaded = ok and render3d.pipelines.ssr_mapping_test:GetFramebuffer(1):GetAttachment(1):Download()
	render3d.Initialize{passes = {import("goluwa/render3d/passes/gbuffer.lua"), import("goluwa/render3d/passes/blit.lua")}}
	if not ok then error(err, 0) end
	local offsets = {{0, 0}, {1, 1}, {1, 0}, {0, 1}}
	for index, size in ipairs(sizes) do
		for phase = 0, 3 do
			for sample = 0, 8 do
				local x, y, sx, sy = downloaded:GetPixelFloat(sample, (index - 1) * 4 + phase)
				for axis, value in ipairs({x, y}) do
					local half_size = math.floor((size[axis] + 1) / 2)
					local pos = axis == 1 and sx or sy
					local first = math.floor(pos * size[axis] / half_size)
					local last = math.floor((pos + 1) * size[axis] / half_size)
					T(value)["=="](first + math.min(offsets[phase + 1][axis], last - first - 1))
					if sample == 8 and phase == 1 then T(value)["=="](size[axis] - 1) end
				end
			end
		end
	end
end)
