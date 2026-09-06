local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local voxel_debug = import("goluwa/render3d/voxels/debug.lua")

event.AddListener("Draw3DForwardOverlay", "debug_voxel_visualizer", function()
	voxel_debug.DrawForwardOverlay()
end)

event.AddListener("Draw2D", "debug_voxel_targets", function(cmd, dt)
	voxel_debug.DrawHUD()
end)

event.AddListener("KeyInput", "debug_voxel_targets_toggle", function(key, press)
	voxel_debug.HandleKeyInput(key, press)
end)

commands.Add("voxel_dump_state=number[1]", function(index)
	voxel_debug.DumpState(index)
end)

commands.Add("voxel_dump_camera=number[1]", function(index)
	voxel_debug.DumpCameraMapping(index)
end)

commands.Add("voxel_dump_watch", function()
	voxel_debug.ToggleDumpWatch()
end)
