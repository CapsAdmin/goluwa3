local system = require("system")
local Ang3 = require("structs.Ang3")
local event = require("event")
local file_formats = require("file_formats")
local Transform = require("transform")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local build_cube = require("game.build_cube")
require("game.camera_movement")
local cube_vertices, cube_indices = build_cube(1.0)
local vertex_buffer = render.CreateBuffer(
	{
		buffer_usage = "vertex_buffer",
		data_type = "float",
		data = cube_vertices,
	}
)
local index_buffer = render.CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = cube_indices,
	}
)
local img = file_formats.LoadPNG("assets/images/capsadmin.png")
local texture_image = render.CreateImage(
	img.width,
	img.height,
	"R8G8B8A8_UNORM",
	{"sampled", "transfer_dst", "transfer_src"},
	"device_local"
)
render.UploadToImage(
	texture_image,
	img.buffer:GetBuffer(),
	texture_image:GetWidth(),
	texture_image:GetHeight()
)
local texture_view = texture_image:CreateView()
local texture_sampler = render.CreateSampler(
	{
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	}
)
local transform = Transform.New()
render3d.UpdateDescriptorSet("combined_image_sampler", 1, 0, texture_view, texture_sampler)

event.AddListener("Draw3D", "draw_cube", function(cmd, dt)
	transform:SetAngles(Ang3(system.GetTime(), system.GetTime(), system.GetTime()))
	render3d.SetWorldMatrix(transform:GetMatrix())
	cmd:BindVertexBuffer(vertex_buffer, 0)
	cmd:BindIndexBuffer(index_buffer, 0)
	cmd:DrawIndexed(36, 1, 0, 0, 0)
end)

event.AddListener("KeyInput", "escape_shutdown", function(key, press)
	if key == "escape" and press then system.ShutDown() end
end)
