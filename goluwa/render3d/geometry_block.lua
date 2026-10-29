local render3d = import("goluwa/render3d/render3d.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local surface_effects = import("goluwa/render3d/surface_effects.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local geometry_block = {}

function geometry_block.New(name, fields, write_extra)
	return {
		name = name,
		binding_index = 3,
		block = {
			render3d.camera_block,
			render3d.prev_camera_block,
			fields,
			surface_weather.block,
			surface_effects.block,
			surface_overlays.block,
		},
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			render3d.WritePreviousCameraBlock(self, block)
			surface_weather.WriteBlock(self, block)
			surface_effects.WriteBlock(self, block)
			surface_overlays.WriteBlock(self, block)
			write_extra(self, block)
			return block
		end,
		upload_scope = "frame",
	}
end

return geometry_block
