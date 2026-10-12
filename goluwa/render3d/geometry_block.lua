local render3d = import("goluwa/render3d/render3d.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local geometry_block = {}

-- the per frame uniform block of a pass that draws geometry into the gbuffer: the camera, the
-- previous frame's camera and the weather, plus the pass's own fields. write_extra fills those
function geometry_block.New(name, fields, write_extra)
	return {
		name = name,
		binding_index = 3,
		block = {
			render3d.camera_block,
			render3d.prev_camera_block,
			fields,
			surface_weather.block,
		},
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			render3d.WritePreviousCameraBlock(self, block)
			surface_weather.WriteBlock(self, block)
			write_extra(self, block)
			return block
		end,
		upload_scope = "frame",
	}
end

return geometry_block
