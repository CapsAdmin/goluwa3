local voxel_gi = import("goluwa/render3d/voxel_gi.lua")
-- Refreshes the voxel gi probe grids. The pass owns no screen sized output,
-- the 1x1 framebuffer only exists to satisfy the compute pass plumbing.
return {
	{
		name = "voxel_gi",
		ComputePass = true,
		ColorFormat = {{"r8_unorm", {"dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		shader = [[
			void main() {}
		]],
		on_draw = function(self, cmd)
			voxel_gi.Draw(cmd)
		end,
	},
}
